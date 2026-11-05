import Foundation
import Testing
@testable import RiftboundScannerApp

@Suite("Auto-scan loop")
struct AutoScanTests {
    private func makeModel(
        feeder: StubFeeder,
        identifier: any CardIdentifying = StubIdentifier(outcome: .success(Fixtures.result(cards: [Fixtures.vi, Fixtures.jinx]))),
        store: InMemoryScanStore = InMemoryScanStore()
    ) -> ScannerModel {
        ScannerModel(
            camera: StubCamera(),
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
            makeID: { UUID() },
            settleDelay: .zero
        )
    }

    @Test func runsUntilTheHopperIsEmptyAndSavesEveryCardPending() async throws {
        let feeder = StubFeeder(script: [.fed, .fed, .fed])
        let store = InMemoryScanStore()
        let model = makeModel(feeder: feeder, store: store)
        await model.start()
        model.connectFeeder()
        #expect(model.canStartAutoScan)

        model.startAutoScan()
        #expect(model.autoScan == .running(fed: 0))
        await model.autoScanTask?.value

        #expect(model.autoScan == .ended(fed: 3, reason: .hopperEmpty))
        #expect(feeder.feedCount == 4, "a fourth feed is what detects the empty hopper")
        #expect(feeder.stopCount == 1)
        #expect(model.records.count == 3)
        #expect(model.records.allSatisfy { $0.verdict == .pending })
        let batch = try #require(model.batch)
        #expect(await store.records(in: batch.id).count == 3)
        #expect(model.pendingScan == nil)
        #expect(model.isBusy == false)

        model.dismissAutoScanResult()
        #expect(model.autoScan == .off)
    }

    @Test func stoppingEndsTheLoopAfterTheCurrentCard() async throws {
        let feeder = StubFeeder(script: [.fed, .hangs])
        let model = makeModel(feeder: feeder)
        await model.start()
        model.connectFeeder()
        model.startAutoScan()

        // Let the first card go through and the second feed start hanging.
        while feeder.feedCount < 2 {
            await Task.yield()
        }
        model.stopAutoScan()
        await model.autoScanTask?.value

        #expect(model.autoScan == .ended(fed: 1, reason: .stoppedByUser))
        #expect(model.records.count == 1)
        #expect(feeder.stopCount == 1)
        #expect(feeder.state.isReady)
    }

    @Test func feederFailureEndsTheLoopWithItsReason() async {
        let feeder = StubFeeder(script: [.fed, .failed(.disconnected)])
        let model = makeModel(feeder: feeder)
        await model.start()
        model.connectFeeder()
        model.startAutoScan()
        await model.autoScanTask?.value

        #expect(model.autoScan == .ended(fed: 1, reason: .feederFailed(.disconnected)))
        #expect(model.records.count == 1)
    }

    @Test func recognitionFailureEndsTheLoopWithoutAnAlert() async {
        let feeder = StubFeeder(script: [.fed, .fed])
        let model = makeModel(feeder: feeder, identifier: StubIdentifier(outcome: .failure(StubFailure())))
        await model.start()
        model.connectFeeder()
        model.startAutoScan()
        await model.autoScanTask?.value

        guard case .ended(let fed, .scanFailed) = model.autoScan else {
            Issue.record("expected a scan failure, got \(model.autoScan)")
            return
        }
        #expect(fed == 1)
        #expect(model.problem == nil)
        #expect(model.records.isEmpty)
        #expect(feeder.stopCount == 1)
    }

    @Test func cannotStartWithoutAReadyFeeder() async {
        let model = makeModel(feeder: StubFeeder())
        await model.start()
        #expect(model.canStartAutoScan == false)
        model.startAutoScan()
        #expect(model.autoScan == .off)
        #expect(model.autoScanTask == nil)
    }

    @Test func manualCaptureIsBlockedWhileTheLoopRuns() async {
        let feeder = StubFeeder(script: [.hangs])
        let model = makeModel(feeder: feeder)
        await model.start()
        model.connectFeeder()
        model.startAutoScan()
        while feeder.feedCount < 1 {
            await Task.yield()
        }
        await model.capture()
        #expect(model.pendingScan == nil)
        model.stopAutoScan()
        await model.autoScanTask?.value
    }

    @Test func leavingTheScreenStopsTheLoop() async {
        let feeder = StubFeeder(script: [.hangs])
        let model = makeModel(feeder: feeder)
        await model.start()
        model.connectFeeder()
        model.startAutoScan()
        while feeder.feedCount < 1 {
            await Task.yield()
        }
        model.stopCamera()
        await model.autoScanTask?.value
        #expect(model.autoScan == .ended(fed: 0, reason: .stoppedByUser))
    }

    @Test func modelDeallocatesAfterALoop() async {
        weak var weakModel: ScannerModel?
        do {
            let model = makeModel(feeder: StubFeeder(script: [.fed]))
            weakModel = model
            await model.start()
            model.connectFeeder()
            model.startAutoScan()
            await model.autoScanTask?.value
        }
        #expect(weakModel == nil, "ScannerModel leaked; check the auto-scan task's captures")
    }
}
