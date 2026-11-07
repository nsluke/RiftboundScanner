import Foundation
import Testing
@testable import RiftboundScannerApp

@Suite("Auto-scan loop")
struct AutoScanTests {
    private func makeModel(
        feeder: StubFeeder,
        identifier: any CardIdentifying = StubIdentifier(outcome: .success(Fixtures.result(cards: [Fixtures.vi, Fixtures.jinx]))),
        store: InMemoryScanStore = InMemoryScanStore(),
        makeID: @escaping @Sendable () -> UUID = Fixtures.unsampledIDs,
        confidenceRule: @escaping @Sendable () -> ConfidenceRule = { .default }
    ) -> ScannerModel {
        ScannerModel(
            camera: StubCamera(),
            feeder: feeder,
            identifier: identifier,
            store: store,
            makeBatch: Fixtures.makeBatch,
            now: { Fixtures.epoch },
            makeID: makeID,
            confidenceRule: confidenceRule,
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
        #expect(model.autoScan == .running(.init()))
        await model.autoScanTask?.value

        #expect(model.autoScan == .ended(.init(fed: 3, identified: 3), reason: .hopperEmpty))
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

    @Test func acceptingConfidentScansMarksOnlyThemCorrect() async throws {
        let feeder = StubFeeder(script: [.fed, .fed])
        let store = InMemoryScanStore()
        let confidentResult = Fixtures.result(cards: [Fixtures.vi, Fixtures.jinx], codeReading: Fixtures.viCodeReading)
        let model = makeModel(feeder: feeder, identifier: StubIdentifier(outcome: .success(confidentResult)), store: store)
        await model.start()
        model.connectFeeder()
        model.startAutoScan()
        await model.autoScanTask?.value
        #expect(model.runRecords.count == 2)
        #expect(model.runRecords.allSatisfy { $0.isAutoConfirmable }, "an exact code at score 1.0 is confident")

        await model.acceptConfidentScans()
        let batch = try #require(model.batch)
        let stored = await store.records(in: batch.id)
        #expect(stored.allSatisfy { $0.verdict == .correct && $0.verdictAt == Fixtures.epoch })
        #expect(stored.allSatisfy { $0.decisions.map(\.source) == [.autoAccepted] && $0.decisions.first?.seq == 1 }, "bulk acceptance is a machine label")
        #expect(stored.allSatisfy { $0.confirmedCardID == Fixtures.vi.id })
        #expect(model.records.allSatisfy { $0.verdict == .correct })
        #expect(model.runRecords.allSatisfy { $0.verdict == .correct })
        #expect(model.acceptedCount == 2)

        // A second accept has nothing left to do.
        await model.acceptConfidentScans()
        #expect(model.acceptedCount == 2)
    }

    /// Three of five scans fall in the audit sample at 0.3 (first bytes 0, 1
    /// and 12 are buckets 0, 1 and 2; 0x95 and 0x45 are bucket 9); accepting
    /// takes the other two and leaves the sample pending for the review queue
    /// (ADR-002, decision 9).
    @Test func acceptingLeavesTheAuditSamplePending() async throws {
        let feeder = StubFeeder(script: [.fed, .fed, .fed, .fed, .fed])
        let store = InMemoryScanStore()
        let confidentResult = Fixtures.result(cards: [Fixtures.vi, Fixtures.jinx], codeReading: Fixtures.viCodeReading)
        let model = makeModel(
            feeder: feeder,
            identifier: StubIdentifier(outcome: .success(confidentResult)),
            store: store,
            makeID: Fixtures.idSequence(firstBytes: [0, 0x95, 1, 0x45, 12])
        )
        await model.start()
        model.connectFeeder()
        model.startAutoScan()
        await model.autoScanTask?.value
        #expect(model.autoScan == .ended(.init(fed: 5, identified: 5), reason: .hopperEmpty))
        #expect(model.runRecords.allSatisfy { $0.isAutoConfirmable })
        #expect(model.runRecords.filter { $0.isHeldForAudit(under: model.rule) }.count == 3)
        #expect(model.runRecords.filter { $0.isAcceptable(under: model.rule) }.count == 2)
        #expect(model.spotCheckCandidates.isEmpty, "nothing has been accepted yet")

        await model.acceptConfidentScans()
        #expect(model.acceptedCount == 2)
        let batch = try #require(model.batch)
        let stored = await store.records(in: batch.id)
        let held = stored.filter { $0.verdict == .pending }
        #expect(held.count == 3)
        #expect(held.map { Int($0.id.rawValue.uuid.0) }.sorted() == [0, 1, 12])
        #expect(held.allSatisfy { $0.isHeldForAudit(under: .default) })
        #expect(stored.filter { $0.decisions.map(\.source) == [.autoAccepted] }.count == 2)
        #expect(model.spotCheckCandidates.count == 2)
        #expect(Set(model.spotCheckCandidates) == Set(stored.filter { $0.verdict == .correct }.map(\.id)))

        // Accepting again changes nothing: the sample is never taken by the machine.
        await model.acceptConfidentScans()
        #expect(model.acceptedCount == 2)
    }

    @Test func theAcceptRuleIsReadFromTheInstalledPolicy() async throws {
        let feeder = StubFeeder(script: [.fed, .fed])
        let store = InMemoryScanStore()
        let confidentResult = Fixtures.result(cards: [Fixtures.vi, Fixtures.jinx], codeReading: Fixtures.viCodeReading)
        let model = makeModel(
            feeder: feeder,
            identifier: StubIdentifier(outcome: .success(confidentResult)),
            store: store,
            makeID: Fixtures.idSequence(firstBytes: [2, 10]),
            confidenceRule: { ConfidenceRule(randomAudits: 300) }
        )
        await model.start()
        model.connectFeeder()
        model.startAutoScan()
        await model.autoScanTask?.value
        #expect(model.rule.auditRate == 0.1)

        await model.acceptConfidentScans()
        #expect(model.acceptedCount == 1, "at 0.1 only bucket zero is held")
        let batch = try #require(model.batch)
        let stored = await store.records(in: batch.id)
        #expect(stored.first { Int($0.id.rawValue.uuid.0) == 2 }?.verdict == .correct)
        #expect(stored.first { Int($0.id.rawValue.uuid.0) == 10 }?.verdict == .pending)
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

        #expect(model.autoScan == .ended(.init(fed: 1, identified: 1), reason: .stoppedByUser))
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

        #expect(model.autoScan == .ended(.init(fed: 1, identified: 1), reason: .feederFailed(.disconnected)))
        #expect(model.records.count == 1)
    }

    @Test func recognitionFailureStopsFeedingAndDiscardsTheQueue() async {
        let feeder = StubFeeder(script: [.fed, .fed, .fed, .fed, .fed])
        let model = makeModel(feeder: feeder, identifier: StubIdentifier(outcome: .failure(StubFailure())))
        await model.start()
        model.connectFeeder()
        model.startAutoScan()
        await model.autoScanTask?.value

        guard case .ended(let progress, .scanFailed) = model.autoScan else {
            Issue.record("expected a scan failure, got \(model.autoScan)")
            return
        }
        #expect(progress.identified == 0)
        #expect(progress.fed < 5, "feeding should stop once identification fails")
        #expect(model.problem == nil)
        #expect(model.records.isEmpty)
        #expect(feeder.stopCount == 1)
        #expect(model.autoScanTask == nil)
    }

    @Test func aSlowIdentifierDoesNotHoldUpTheFeeder() async throws {
        let feeder = StubFeeder(script: [.fed, .fed, .fed])
        let identifier = GatedIdentifier()
        let model = makeModel(feeder: feeder, identifier: identifier)
        await model.start()
        model.connectFeeder()
        model.startAutoScan()

        // Every card is fed and photographed while the first identification is still held.
        while feeder.feedCount < 4 || model.autoScan.progress?.fed != 3 {
            await Task.yield()
        }
        while case .running = model.autoScan {
            await Task.yield()
        }
        #expect(model.autoScan == .draining(.init(fed: 3, identified: 0), reason: .hopperEmpty))
        #expect(model.records.isEmpty)
        #expect(feeder.stopCount == 1, "the motor stops as soon as feeding ends, not when the queue drains")

        for _ in 0..<3 {
            await identifier.release()
        }
        await model.autoScanTask?.value
        #expect(model.autoScan == .ended(.init(fed: 3, identified: 3), reason: .hopperEmpty))
        #expect(model.records.count == 3)
        #expect(await identifier.started == 3)
    }

    @Test func stoppingStillIdentifiesWhatWasAlreadyCaptured() async {
        let feeder = StubFeeder(script: [.fed, .fed, .hangs])
        let identifier = GatedIdentifier()
        let model = makeModel(feeder: feeder, identifier: identifier)
        await model.start()
        model.connectFeeder()
        model.startAutoScan()
        while feeder.feedCount < 3 {
            await Task.yield()
        }
        model.stopAutoScan()
        while case .running = model.autoScan {
            await Task.yield()
        }
        #expect(model.autoScan == .draining(.init(fed: 2, identified: 0), reason: .stoppedByUser))

        await identifier.release()
        await identifier.release()
        await model.autoScanTask?.value
        #expect(model.autoScan == .ended(.init(fed: 2, identified: 2), reason: .stoppedByUser))
        #expect(model.records.count == 2)
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
        #expect(model.autoScan == .ended(.init(), reason: .stoppedByUser))
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
