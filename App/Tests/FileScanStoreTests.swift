import Foundation
import Testing
@testable import RiftboundScannerApp

@Suite("File scan store")
struct FileScanStoreTests {
    let root = URL.temporaryDirectory.appending(path: "FileScanStoreTests-\(UUID().uuidString)")

    @Test func batchesAndRecordsRoundTripThroughDisk() async throws {
        let store = FileScanStore(root: root, now: { Fixtures.epoch }, makeID: { UUID() })
        let batch = Fixtures.batch()
        try await store.save(batch)
        let record = Fixtures.record(batch: batch.id)
        try await store.append(record, photo: Fixtures.jpeg(), rectified: Fixtures.jpeg())

        #expect(try await store.batches() == [batch])
        #expect(try await store.records(in: batch.id) == [record])
        #expect(FileManager.default.fileExists(atPath: store.photoURL(for: record).path(percentEncoded: false)))
        let rectifiedURL = try #require(store.rectifiedURL(for: record))
        #expect(FileManager.default.fileExists(atPath: rectifiedURL.path(percentEncoded: false)))

        let decided = try await store.decide(record.id, in: batch.id, DecisionInput(.correct, source: .human))
        #expect(decided.verdict == .correct)
        #expect(decided.verdictAt == Fixtures.epoch)
        #expect(decided.decisions.map(\.seq) == [1])
        #expect(decided.confirmedCardID == Fixtures.vi.id)
        #expect(try await store.records(in: batch.id) == [decided])

        // An update that extends the log is accepted; a copy from before the decision is stale.
        try await store.update(decided)
        await #expect(throws: ScanStoreError.staleRecord(record.id)) {
            try await store.update(record)
        }
        #expect(try await store.records(in: batch.id) == [decided])

        try await store.deleteBatch(batch.id)
        #expect(try await store.batches().isEmpty)
    }

    @Test func appendingToAnUnknownBatchFails() async {
        let store = FileScanStore(root: root, now: { Fixtures.epoch }, makeID: { UUID() })
        await #expect(throws: ScanStoreError.self) {
            try await store.append(Fixtures.record(batch: ScanBatch.ID(rawValue: UUID())), photo: Data(), rectified: nil)
        }
    }

    @Test func emptyStoreHasNoBatches() async throws {
        let store = FileScanStore(root: root, now: { Fixtures.epoch }, makeID: { UUID() })
        #expect(try await store.batches().isEmpty)
    }
}
