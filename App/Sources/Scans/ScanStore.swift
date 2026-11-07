import Foundation

/// Persists batches and their records. The live store is a folder per batch
/// under Documents, which iTunes/Finder file sharing and `devicectl` can read.
nonisolated protocol ScanStoring: Sendable {
    func batches() async throws -> [ScanBatch]
    func records(in batch: ScanBatch.ID) async throws -> [ScanRecord]
    func save(_ batch: ScanBatch) async throws
    /// Stores the images, then appends the record to the batch.
    func append(_ record: ScanRecord, photo: Data, rectified: Data?) async throws
    /// Replaces a record. Throws `staleRecord` unless the incoming decision
    /// log extends the stored one: an update can add decisions, never drop one.
    func update(_ record: ScanRecord) async throws
    /// Replaces several of one batch's records in a single write, with the
    /// same staleness rule per record.
    func update(_ records: [ScanRecord]) async throws
    /// Appends a decision to the stored record and returns the result. The
    /// only way a verdict changes: the store numbers the decision after
    /// whatever is on disk, so two screens holding copies cannot overwrite
    /// each other (ADR-002, decision 2).
    func decide(_ id: ScanRecord.ID, in batch: ScanBatch.ID, _ input: DecisionInput) async throws -> ScanRecord
    func deleteBatch(_ id: ScanBatch.ID) async throws
    /// Appends a `voided` decision to every scan in the batch that is not
    /// already voided, so each one's ledger effect is undone (ADR-002,
    /// decision 2). Returns how many scans were voided.
    @discardableResult
    func voidBatch(_ id: ScanBatch.ID) async throws -> Int
    func batchDirectory(for id: ScanBatch.ID) -> URL
    func photoURL(for record: ScanRecord) -> URL
    func rectifiedURL(for record: ScanRecord) -> URL?
}

nonisolated extension ScanStoring {
    /// Voiding is decisions like any other: one `human` `voided` per scan,
    /// through `decide`.
    @discardableResult
    func voidBatch(_ id: ScanBatch.ID) async throws -> Int {
        var voided = 0
        for record in try await records(in: id) where record.verdict != .voided {
            _ = try await decide(record.id, in: id, DecisionInput(.voided, source: .human))
            voided += 1
        }
        return voided
    }
}

/// A store that can say cheaply whether a batch's records changed since it
/// was last asked, so the sync engine can skip decoding a settled batch's
/// `scans.json` (megabytes of analysis per batch) on every flush.
nonisolated protocol ScanRecordStamping: Sendable {
    /// A value that differs whenever `records(in:)` would answer differently
    /// from the last time this stamp was taken; `nil` when the store cannot
    /// tell, which makes every reader decode the records.
    func recordsStamp(for batch: ScanBatch.ID) async -> String?
}

nonisolated enum ScanStoreError: Error, Hashable {
    case batchMissing(ScanBatch.ID)
    case recordMissing(ScanRecord.ID)
    /// The update's decisions are not what is on disk plus zero or more new ones.
    case staleRecord(ScanRecord.ID)
    /// `.pending` is the absence of a decision, not one.
    case invalidDecision(ScanRecord.ID)
    /// A batch's purpose cannot change once any of its scans has a decision.
    case purposeImmutable(ScanBatch.ID)
}

/// ```
/// Documents/Scans/<batch id>/batch.json
///                           /scans.json
///                           /photos/<scan id>.jpg
///                           /rectified/<scan id>.jpg
/// ```
actor FileScanStore: ScanStoring, ScanRecordStamping {
    private let root: URL
    private let fileManager = FileManager()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID

    init(root: URL, now: @escaping @Sendable () -> Date, makeID: @escaping @Sendable () -> UUID) {
        self.root = root
        self.now = now
        self.makeID = makeID
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    nonisolated func batchDirectory(for id: ScanBatch.ID) -> URL {
        root.appending(path: id.rawValue.uuidString, directoryHint: .isDirectory)
    }

    nonisolated func photoURL(for record: ScanRecord) -> URL {
        batchDirectory(for: record.batchID).appending(path: record.photoFileName)
    }

    nonisolated func rectifiedURL(for record: ScanRecord) -> URL? {
        record.rectifiedFileName.map { batchDirectory(for: record.batchID).appending(path: $0) }
    }

    func batches() throws -> [ScanBatch] {
        guard fileManager.fileExists(atPath: root.path(percentEncoded: false)) else { return [] }
        let folders = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        var batches: [ScanBatch] = []
        for folder in folders {
            let file = folder.appending(path: "batch.json")
            guard fileManager.fileExists(atPath: file.path(percentEncoded: false)) else { continue }
            batches.append(try decoder.decode(ScanBatch.self, from: try Data(contentsOf: file)))
        }
        return batches.sorted { $0.startedAt > $1.startedAt }
    }

    func records(in batch: ScanBatch.ID) throws -> [ScanRecord] {
        let file = batchDirectory(for: batch).appending(path: "scans.json")
        guard fileManager.fileExists(atPath: file.path(percentEncoded: false)) else { return [] }
        return try decoder.decode([ScanRecord].self, from: try Data(contentsOf: file))
    }

    /// The modification time and size of `scans.json`: every write replaces
    /// the file atomically, so both move together with its content.
    func recordsStamp(for batch: ScanBatch.ID) -> String? {
        let file = batchDirectory(for: batch).appending(path: "scans.json")
        guard let attributes = try? fileManager.attributesOfItem(atPath: file.path(percentEncoded: false)),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber else { return nil }
        return "\(modified.timeIntervalSinceReferenceDate):\(size.intValue)"
    }

    func save(_ batch: ScanBatch) throws {
        let directory = batchDirectory(for: batch.id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(batch).write(to: directory.appending(path: "batch.json"), options: .atomic)
    }

    func append(_ record: ScanRecord, photo: Data, rectified: Data?) throws {
        let directory = batchDirectory(for: record.batchID)
        guard fileManager.fileExists(atPath: directory.path(percentEncoded: false)) else { throw ScanStoreError.batchMissing(record.batchID) }
        let photoURL = photoURL(for: record)
        try fileManager.createDirectory(at: photoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try photo.write(to: photoURL, options: .atomic)
        if let rectified, let rectifiedURL = rectifiedURL(for: record) {
            try fileManager.createDirectory(at: rectifiedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try rectified.write(to: rectifiedURL, options: .atomic)
        }
        var records = try records(in: record.batchID)
        records.removeAll { $0.id == record.id }
        records.append(record)
        try write(records, to: record.batchID)
    }

    func update(_ record: ScanRecord) throws {
        try update([record])
    }

    func update(_ changes: [ScanRecord]) throws {
        guard let batchID = changes.first?.batchID else { return }
        var records = try records(in: batchID)
        for change in changes where change.batchID == batchID {
            guard let position = records.firstIndex(where: { $0.id == change.id }) else { throw ScanStoreError.recordMissing(change.id) }
            guard records[position].isExtended(by: change) else { throw ScanStoreError.staleRecord(change.id) }
            records[position] = change
        }
        try write(records, to: batchID)
    }

    func decide(_ id: ScanRecord.ID, in batch: ScanBatch.ID, _ input: DecisionInput) throws -> ScanRecord {
        guard input.verdict != .pending else { throw ScanStoreError.invalidDecision(id) }
        var records = try records(in: batch)
        guard let position = records.firstIndex(where: { $0.id == id }) else { throw ScanStoreError.recordMissing(id) }
        let decided = records[position].deciding(input, id: Decision.ID(rawValue: makeID()), at: now())
        records[position] = decided
        try write(records, to: batch)
        return decided
    }

    func deleteBatch(_ id: ScanBatch.ID) throws {
        let directory = batchDirectory(for: id)
        guard fileManager.fileExists(atPath: directory.path(percentEncoded: false)) else { return }
        try fileManager.removeItem(at: directory)
    }

    private func write(_ records: [ScanRecord], to batch: ScanBatch.ID) throws {
        try encoder.encode(records).write(to: batchDirectory(for: batch).appending(path: "scans.json"), options: .atomic)
    }
}
