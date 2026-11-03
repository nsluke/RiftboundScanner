import Foundation
import Testing
@testable import RiftboundScannerApp

@Suite("File scan store")
struct FileScanStoreTests {
    let root = URL.temporaryDirectory.appending(path: "FileScanStoreTests-\(UUID().uuidString)")

    @Test func batchesAndRecordsRoundTripThroughDisk() async throws {
        let store = FileScanStore(root: root)
        let batch = Fixtures.batch()
        try await store.save(batch)
        let record = Fixtures.record(batch: batch.id)
        try await store.append(record, photo: Fixtures.jpeg(), rectified: Fixtures.jpeg())

        #expect(try await store.batches() == [batch])
        #expect(try await store.records(in: batch.id) == [record])
        #expect(FileManager.default.fileExists(atPath: store.photoURL(for: record).path(percentEncoded: false)))
        let rectifiedURL = try #require(store.rectifiedURL(for: record))
        #expect(FileManager.default.fileExists(atPath: rectifiedURL.path(percentEncoded: false)))

        var updated = record
        updated.verdict = .correct
        updated.verdictAt = Fixtures.epoch
        try await store.update(updated)
        #expect(try await store.records(in: batch.id) == [updated])

        try await store.deleteBatch(batch.id)
        #expect(try await store.batches().isEmpty)
    }

    @Test func appendingToAnUnknownBatchFails() async {
        let store = FileScanStore(root: root)
        await #expect(throws: ScanStoreError.self) {
            try await store.append(Fixtures.record(batch: ScanBatch.ID(rawValue: UUID())), photo: Data(), rectified: nil)
        }
    }

    @Test func emptyStoreHasNoBatches() async throws {
        let store = FileScanStore(root: root)
        #expect(try await store.batches().isEmpty)
    }
}
