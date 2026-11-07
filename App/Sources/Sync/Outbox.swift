import Foundation

/// A ledger item waiting to be sent, with the scan and batch it came from so
/// the answer can be routed back without parsing the reference.
nonisolated struct OutboxEntry: Hashable, Sendable, Codable, Identifiable {
    let batchID: ScanBatch.ID
    let scanID: ScanRecord.ID
    let item: LedgerSyncItem

    var id: String { item.clientRef }
}

/// The ledger items owed to the server, in the order they should go
/// (ADR-002, principle 7). A cache: `SyncEngine.reconcile()` rebuilds it
/// from `scans.json` and `sync.json`, so `outbox.json` can be deleted at any
/// time and nothing is lost. Persisted so a launch that never reaches
/// reconcile still shows the right pending count.
actor Outbox {
    private let fileURL: URL
    private var entries: [OutboxEntry]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL) {
        self.fileURL = fileURL
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([OutboxEntry].self, from: Data(contentsOf: fileURL))) ?? []
    }

    var count: Int { entries.count }

    var isEmpty: Bool { entries.isEmpty }

    func allEntries() -> [OutboxEntry] { entries }

    func entries(in batch: ScanBatch.ID) -> [OutboxEntry] {
        entries.filter { $0.batchID == batch }
    }

    func count(in batch: ScanBatch.ID) -> Int {
        entries.count { $0.batchID == batch }
    }

    /// The oldest `limit` entries, one request's worth.
    func nextPage(limit: Int) -> [OutboxEntry] {
        Array(entries.prefix(limit))
    }

    /// Makes the scan's entries exactly `items`, keeping the position of any
    /// that were already queued so the drain stays first-in, first-out.
    func replace(itemsFor scan: ScanRecord.ID, in batch: ScanBatch.ID, with items: [LedgerSyncItem]) throws {
        let wanted = Dictionary(items.map { ($0.clientRef, $0) }, uniquingKeysWith: { first, _ in first })
        var kept: [OutboxEntry] = []
        var seen: Set<String> = []
        for entry in entries {
            guard entry.scanID == scan else {
                kept.append(entry)
                continue
            }
            if let item = wanted[entry.item.clientRef] {
                kept.append(OutboxEntry(batchID: batch, scanID: scan, item: item))
                seen.insert(item.clientRef)
            }
        }
        for item in items where !seen.contains(item.clientRef) {
            kept.append(OutboxEntry(batchID: batch, scanID: scan, item: item))
        }
        try store(kept)
    }

    func remove(refs: Set<String>) throws {
        try store(entries.filter { !refs.contains($0.item.clientRef) })
    }

    /// Drops entries for scans or batches that no longer exist.
    func removeAll(where shouldRemove: @Sendable (OutboxEntry) -> Bool) throws {
        try store(entries.filter { !shouldRemove($0) })
    }

    private func store(_ updated: [OutboxEntry]) throws {
        guard updated != entries else { return }
        entries = updated
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(updated).write(to: fileURL, options: .atomic)
    }
}
