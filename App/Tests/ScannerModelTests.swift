import Foundation
import Testing
@testable import RiftboundScannerApp

@Suite("Scanner model")
struct ScannerModelTests {
    private let recordID = UUID()

    private func makeModel(
        camera: StubCamera = StubCamera(),
        feeder: StubFeeder = StubFeeder(),
        identifier: any CardIdentifying = StubIdentifier(outcome: .success(Fixtures.result(cards: [Fixtures.vi, Fixtures.jinx]))),
        store: InMemoryScanStore = InMemoryScanStore()
    ) -> ScannerModel {
        ScannerModel(
            camera: camera,
            feeder: feeder,
            identifier: identifier,
            store: store,
            makeBatch: { label in
                ScanBatch(
                    id: ScanBatch.ID(rawValue: UUID()),
                    startedAt: Fixtures.epoch,
                    label: label,
                    device: ScanBatch.Device(model: "iPhone17,1", systemVersion: "26.1", appVersion: "0.1.0"),
                    index: IndexSummary(builtAt: Fixtures.epoch, entryCount: 2, formatVersion: 1)
                )
            },
            now: { Fixtures.epoch },
            makeID: { recordID }
        )
    }

    @Test func startCreatesABatchAndReadiesTheCamera() async {
        let model = makeModel()
        await model.start()
        #expect(model.batch != nil)
        #expect(model.cameraState == .ready)
        #expect(model.records.isEmpty)
    }

    @Test func deniedCameraIsAState() async {
        let model = makeModel(camera: StubCamera(access: false))
        await model.start()
        #expect(model.cameraState == .denied)
    }

    @Test func captureProducesAPendingScanWithRankedCandidates() async throws {
        let model = makeModel()
        await model.start()
        await model.capture()
        let pending = try #require(model.pendingScan)
        #expect(pending.record.candidates.map(\.card.id) == [Fixtures.vi.id, Fixtures.jinx.id])
        #expect(pending.record.verdict == .pending)
        #expect(pending.record.id == ScanRecord.ID(rawValue: recordID))
        #expect(pending.record.placement == .detected(confidence: 0.95))
        #expect(model.isBusy == false)
    }

    @Test func resolvingPersistsTheRecordWithItsVerdict() async throws {
        let store = InMemoryScanStore()
        let model = makeModel(store: store)
        await model.start()
        await model.capture()
        await model.resolve(.corrected(Fixtures.jinx.id))

        let batch = try #require(model.batch)
        let stored = await store.records(in: batch.id)
        #expect(stored.count == 1)
        #expect(stored.first?.verdict == .corrected(Fixtures.jinx.id))
        #expect(stored.first?.verdictAt == Fixtures.epoch)
        #expect(await store.photos[ScanRecord.ID(rawValue: recordID)] != nil)
        #expect(model.pendingScan == nil)
        #expect(model.records.count == 1)
        #expect(model.savedVerdictCount == 1)
    }

    @Test func retakeDropsThePendingScan() async throws {
        let store = InMemoryScanStore()
        let model = makeModel(store: store)
        await model.start()
        await model.capture()
        model.retake()
        #expect(model.pendingScan == nil)
        let batchID = try #require(model.batch?.id)
        #expect(await store.records(in: batchID).isEmpty)
    }

    @Test func recognitionFailureIsReportedAndRecoverable() async {
        let model = makeModel(identifier: StubIdentifier(outcome: .failure(StubFailure())))
        await model.start()
        await model.capture()
        #expect(model.problem != nil)
        model.dismissProblem()
        #expect(model.problem == nil)
        #expect(model.pendingScan == nil)
    }

    @Test func newBatchReplacesTheCurrentOne() async {
        let model = makeModel()
        await model.start()
        let first = model.batch?.id
        await model.beginNewBatch(label: "lamp")
        #expect(model.batch?.id != first)
        #expect(model.batch?.label == "lamp")
    }

    @Test func modelDeallocates() async {
        weak var weakModel: ScannerModel?
        do {
            let model = makeModel()
            weakModel = model
            await model.start()
            await model.capture()
        }
        #expect(weakModel == nil, "ScannerModel leaked; check task and closure captures")
    }
}
