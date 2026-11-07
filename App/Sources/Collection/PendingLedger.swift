import Foundation

/// A ledger change the phone owes the server and the server has not yet
/// acknowledged: a scan's `+1`, the reversal of an applied row (as `-1` of
/// the card that row holds), or a manual add. The Collection shows these as
/// "+N pending" on top of the server's counts (ADR-002, principle 1).
nonisolated struct PendingDelta: Hashable, Sendable, Identifiable {
    let clientRef: String
    /// A `PrintingKey` spelling (`OGN-001`, `SFD-227*`) or a vault code
    /// (`SFD-227-STAR`); `PrintingKey(vaultCode:)` reads both.
    let cardKey: String
    let finish: Finish?
    let quantity: Int

    init(clientRef: String, cardKey: String, finish: Finish? = nil, quantity: Int) {
        self.clientRef = clientRef
        self.cardKey = cardKey
        self.finish = finish
        self.quantity = quantity
    }

    var id: String { clientRef }

    var key: PrintingKey { PrintingKey(vaultCode: cardKey) }
}

/// Where the unacknowledged deltas come from. The live provider reads the
/// sync engine's outbox; tests inject a list.
nonisolated protocol PendingLedgerProviding: Sendable {
    func pendingDeltas() async -> [PendingDelta]
}

/// The outbox (every ledger item owed, scan and manual alike) with each undo
/// resolved to the applied row it reverses through the batch's `sync.json`,
/// or to the `+1` queued beside it when that row is only being replayed. An
/// undo whose target is unknown counts for nothing: the phone never guesses
/// a previous effect (decision 2).
nonisolated struct OutboxPendingLedger: PendingLedgerProviding {
    let outbox: Outbox
    let store: SyncingScanStore

    init(outbox: Outbox, store: SyncingScanStore) {
        self.outbox = outbox
        self.store = store
    }

    func pendingDeltas() async -> [PendingDelta] {
        let entries = await outbox.allEntries()
        var states: [ScanBatch.ID: BatchSyncState] = [:]
        var deltas: [PendingDelta] = []
        for entry in entries {
            switch entry.item {
            case .delta(let delta):
                deltas.append(PendingDelta(clientRef: delta.clientRef, cardKey: delta.cardKey, finish: delta.finish, quantity: delta.quantityDelta))
            case .undo(let undo):
                // Only a scan's decision can be undone; a manual add is always a
                // `+N` delta, so a manual-origin undo has no applied row to read.
                if case .scan(let batchID, let scanID) = entry.origin {
                    if states[batchID] == nil {
                        states[batchID] = await store.syncState(for: batchID)
                    }
                    if case .applied(_, let cardID, let finish)? = states[batchID]?[scanID].items[undo.undoOf] {
                        deltas.append(PendingDelta(clientRef: undo.clientRef, cardKey: cardID, finish: finish, quantity: -1))
                        continue
                    }
                }
                if let replayed = entries.first(where: { $0.item.clientRef == undo.undoOf }), case .delta(let delta) = replayed.item {
                    deltas.append(PendingDelta(clientRef: undo.clientRef, cardKey: delta.cardKey, finish: delta.finish, quantity: -delta.quantityDelta))
                }
            }
        }
        return deltas
    }
}

nonisolated extension Sequence where Element == PendingDelta {
    /// Net pending quantity per printing.
    var byPrinting: [PrintingKey: Int] {
        var totals: [PrintingKey: Int] = [:]
        for delta in self {
            totals[delta.key, default: 0] += delta.quantity
        }
        return totals.filter { $0.value != 0 }
    }
}
