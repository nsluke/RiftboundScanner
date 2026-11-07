import Foundation
import RiftboundRecognizer

/// Turns a scan's decision log and what the server has acknowledged into the
/// ledger items still owed (ADR-002, decision 2). Pure: the same inputs
/// always give the same items, which is what lets the outbox be a cache.
///
/// A decision's *effect* is the +1 it asks for: a printing key and a finish,
/// or nothing (rejected, voided, pending, `legacy`, or a batch that is not a
/// collection). Walking the log:
///
/// - an unchanged effect emits nothing (an audit that agrees costs no item);
/// - a changed effect emits `+1 scan:<id>:<seq>` for the new effect and, when
///   the previous effect's +1 was **applied**, an undo `scan:<id>:<seq>:undo`
///   naming that applied reference. A previous +1 the server never saw is
///   simply dropped from the outbox: nothing to reverse, nothing to send. A
///   previous +1 that was **sent** without an answer may have landed, so it
///   is replayed (the server answers `duplicate` or `applied`) and then
///   reversed by reference, which nets to zero either way;
/// - items the server has already acknowledged are never emitted again.
nonisolated enum LedgerDeltaBuilder {
    /// What a decision asks the ledger to hold for this scan.
    struct Effect: Hashable, Sendable {
        let cardKey: String
        /// `nil` lets the server derive it from the printing and `defaultFinish`.
        let finish: Finish?
    }

    static func items(record: ScanRecord, previousState: ScanSyncState, batch: ScanBatch, vault: CardVault) -> [LedgerSyncItem] {
        guard batch.purpose == .collection else { return [] }
        var output: [LedgerSyncItem] = []
        /// The effect currently standing (applied or owed) and the decision that caused it.
        var standing: (seq: Int, effect: Effect)?
        var finishOverride: Finish?
        var printingOverride: PrintingKey?

        for decision in record.decisions {
            finishOverride = decision.finish.value ?? finishOverride
            printingOverride = decision.ledgerPrintingCode.value ?? printingOverride
            let effect = effect(of: decision, finishOverride: finishOverride, printingOverride: printingOverride, batch: batch, vault: vault)
            guard effect != standing?.effect else { continue }

            if let previous = standing {
                let previousRef = ClientRef.plusOne(record.id, seq: previous.seq)
                switch previousState[previousRef] {
                case .applied, .sent:
                    output.append(.undo(LedgerSyncItem.Undo(
                        clientRef: ClientRef.undo(record.id, seq: decision.seq).description,
                        undoOf: previousRef.description,
                        occurredAt: decision.decidedAt,
                        scanID: record.id.rawValue
                    )))
                case .queued, nil:
                    // Never reached the server: withdraw it instead of reversing it.
                    output.removeAll { $0.clientRef == previousRef.description }
                case .terminal:
                    break
                }
            }
            if let effect {
                output.append(.delta(LedgerSyncItem.Delta(
                    clientRef: ClientRef.plusOne(record.id, seq: decision.seq).description,
                    cardKey: effect.cardKey,
                    quantityDelta: 1,
                    finish: effect.finish,
                    // The same default `effect(of:)` resolved prompt finishes with,
                    // so phone and server derive alike for a batch without one.
                    defaultFinish: batch.defaultFinish ?? .normal,
                    occurredAt: decision.decidedAt,
                    scanID: record.id.rawValue
                )))
            }
            standing = effect.map { (decision.seq, $0) }
        }

        return output.filter { item in
            switch previousState.items[item.clientRef] {
            case nil, .queued, .sent: true
            case .applied, .terminal: false
            }
        }
    }

    /// The +1 a decision asks for, with the finish settled the way the review
    /// UI would settle it: a single-finish printing is forced, a both-finish
    /// printing takes the override or the batch default, an unknown printing
    /// sends the override alone and lets the server derive the rest.
    static func effect(of decision: Decision, finishOverride: Finish?, printingOverride: PrintingKey?, batch: ScanBatch, vault: CardVault) -> Effect? {
        guard decision.source != .legacy, let cardID = decision.cardID else { return nil }
        switch decision.verdict {
        case .correct, .corrected: break
        case .pending, .rejected, .voided: return nil
        }
        let key = printingOverride ?? PrintingKey(cardID: cardID)
        let cardKey = key?.rawValue ?? cardID.rawValue
        let finish: Finish?
        switch FinishPolicy.resolve(card: key.flatMap { vault[$0] }, batchDefault: batch.defaultFinish ?? .normal) {
        case .forced(let forced): finish = forced
        case .prompt(let fallback): finish = finishOverride ?? fallback
        case .unknown: finish = finishOverride
        }
        return Effect(cardKey: cardKey, finish: finish)
    }
}
