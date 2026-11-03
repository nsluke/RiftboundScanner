import Foundation

/// Persists batches and their records. The live store is a folder per batch
/// under Documents, which iTunes/Finder file sharing and `devicectl` can read.
nonisolated protocol ScanStoring: Sendable {
    func batches() async throws -> [ScanBatch]
    func records(in batch: ScanBatch.ID) async throws -> [ScanRecord]
    func save(_ batch: ScanBatch) async throws
    /// Stores the images, then appends the record to the batch.
    func append(_ record: ScanRecord, photo: Data, rectified: Data?) async throws
    func update(_ record: ScanRecord) async throws
    func deleteBatch(_ id: ScanBatch.ID) async throws
    func batchDirectory(for id: ScanBatch.ID) -> URL
    func photoURL(for record: ScanRecord) -> URL
    func rectifiedURL(for record: ScanRecord) -> URL?
}

nonisolated enum ScanStoreError: Error {
    case batchMissing(ScanBatch.ID)
    case recordMissing(ScanRecord.ID)
}

/// ```
/// Documents/Scans/<batch id>/batch.json
///                           /scans.json
///                           /photos/<scan id>.jpg
///                           /rectified/<scan id>.jpg
/// ```
actor FileScanStore: ScanStoring {
    private let root: URL
    private let fileManager = FileManager()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(root: URL) {
        self.root = root
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
        var records = try records(in: record.batchID)
        guard let position = records.firstIndex(where: { $0.id == record.id }) else { throw ScanStoreError.recordMissing(record.id) }
        records[position] = record
        try write(records, to: record.batchID)
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
