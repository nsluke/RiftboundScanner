import CoreGraphics
import Foundation
import RiftboundRecognizer
@testable import RiftboundScannerApp

nonisolated struct StubCamera: CameraOperating {
    var access = true
    var photo = Fixtures.jpeg()
    var startFailure: CameraError?

    func requestAccess() async -> Bool { access }

    func start() async throws {
        if let startFailure { throw startFailure }
    }

    func stop() async {}

    func setTorch(_ isOn: Bool) async throws {}

    func capturePhoto() async throws -> Data { photo }
}

nonisolated struct StubFailure: Error {}

nonisolated struct StubIdentifier: CardIdentifying {
    let outcome: Result<RecognitionResult, StubFailure>

    func identify(_ photo: CGImage) async throws -> RecognitionResult {
        try outcome.get()
    }
}

/// A behaviourally real store with no disk.
actor InMemoryScanStore: ScanStoring {
    private var batchesByID: [ScanBatch.ID: ScanBatch] = [:]
    private var recordsByBatch: [ScanBatch.ID: [ScanRecord]] = [:]
    private(set) var photos: [ScanRecord.ID: Data] = [:]

    func batches() -> [ScanBatch] {
        batchesByID.values.sorted { $0.startedAt > $1.startedAt }
    }

    func records(in batch: ScanBatch.ID) -> [ScanRecord] {
        recordsByBatch[batch] ?? []
    }

    func save(_ batch: ScanBatch) {
        batchesByID[batch.id] = batch
    }

    func append(_ record: ScanRecord, photo: Data, rectified: Data?) throws {
        guard batchesByID[record.batchID] != nil else { throw ScanStoreError.batchMissing(record.batchID) }
        photos[record.id] = photo
        recordsByBatch[record.batchID, default: []].append(record)
    }

    func update(_ record: ScanRecord) throws {
        guard var list = recordsByBatch[record.batchID], let position = list.firstIndex(where: { $0.id == record.id }) else {
            throw ScanStoreError.recordMissing(record.id)
        }
        list[position] = record
        recordsByBatch[record.batchID] = list
    }

    func deleteBatch(_ id: ScanBatch.ID) {
        batchesByID[id] = nil
        recordsByBatch[id] = nil
    }

    nonisolated func batchDirectory(for id: ScanBatch.ID) -> URL {
        URL.temporaryDirectory.appending(path: id.rawValue.uuidString)
    }

    nonisolated func photoURL(for record: ScanRecord) -> URL {
        batchDirectory(for: record.batchID).appending(path: record.photoFileName)
    }

    nonisolated func rectifiedURL(for record: ScanRecord) -> URL? { nil }
}

/// An identifier that answers only when released, one answer per release, so
/// a test can hold identification back while feeding carries on.
actor GatedIdentifier: CardIdentifying {
    private let result: RecognitionResult
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var releases = 0
    private(set) var started = 0

    init(result: RecognitionResult = Fixtures.result(cards: [Fixtures.vi, Fixtures.jinx])) {
        self.result = result
    }

    var waitingCount: Int { waiting.count }

    func identify(_ photo: CGImage) async throws -> RecognitionResult {
        started += 1
        if releases > 0 {
            releases -= 1
        } else {
            await withCheckedContinuation { waiting.append($0) }
        }
        return result
    }

    func release() {
        if waiting.isEmpty {
            releases += 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}
