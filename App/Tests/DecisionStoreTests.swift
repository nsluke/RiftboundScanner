import Foundation
import RiftboundRecognizer
import Testing
@testable import RiftboundScannerApp

/// The store is the only writer of verdicts: it numbers decisions after what
/// is on disk and refuses updates that would drop one (ADR-002, decision 2).
@Suite("Decisions through the store")
struct DecisionStoreTests {
    private let batch = Fixtures.batch(purpose: .collection, defaultFinish: .normal)

    private func makeScannerModel(store: InMemoryScanStore, feeder: StubFeeder) -> ScannerModel {
        ScannerModel(
            camera: StubCamera(),
            feeder: feeder,
            identifier: StubIdentifier(outcome: .success(Fixtures.result(cards: [Fixtures.vi, Fixtures.jinx], codeReading: Fixtures.viCodeReading))),
            store: store,
            makeBatch: { _ in batch },
            now: { Fixtures.epoch },
            makeID: { UUID() },
            settleDelay: .zero
        )
    }

    @Test func decideAppendsNumberedDecisionsWithSnapshots() async throws {
        let clock = TickingClock()
        let store = InMemoryScanStore(now: { clock.now() })
        await store.save(batch)
        let record = Fixtures.record(batch: batch.id)
        try await store.append(record, photo: Data(), rectified: nil)

        let first = try await store.decide(record.id, in: batch.id, DecisionInput(.correct, source: .autoAccepted))
        #expect(first.decisions.map(\.seq) == [1])
        #expect(first.decisions.first?.source == .autoAccepted)
        #expect(first.decisions.first?.cardID == Fixtures.vi.id)
        #expect(first.decisions.first?.decidedAt == Fixtures.epoch.addingTimeInterval(1))

        let second = try await store.decide(record.id, in: batch.id, DecisionInput(.corrected(Fixtures.jinx.id), source: .audit, finish: .set(.foil)))
        #expect(second.decisions.map(\.seq) == [1, 2])
        #expect(second.verdict == .corrected(Fixtures.jinx.id))
        #expect(second.confirmedCardID == Fixtures.jinx.id)
        #expect(second.effectiveFinish == .foil)
        #expect(second.decisions.last?.decidedAt == Fixtures.epoch.addingTimeInterval(2))
        #expect(await store.records(in: batch.id) == [second])
    }

    @Test func pendingIsNotADecision() async throws {
        let store = InMemoryScanStore()
        await store.save(batch)
        let record = Fixtures.record(batch: batch.id)
        try await store.append(record, photo: Data(), rectified: nil)
        await #expect(throws: ScanStoreError.invalidDecision(record.id)) {
            try await store.decide(record.id, in: batch.id, DecisionInput(.pending, source: .human))
        }
        await #expect(throws: ScanStoreError.recordMissing(record.id)) {
            try await store.decide(record.id, in: ScanBatch.ID(rawValue: UUID()), DecisionInput(.correct, source: .human))
        }
    }

    @Test func updateRefusesACopyThatWouldDropADecision() async throws {
        let store = InMemoryScanStore()
        await store.save(batch)
        let record = Fixtures.record(batch: batch.id)
        try await store.append(record, photo: Data(), rectified: nil)
        let decided = try await store.decide(record.id, in: batch.id, DecisionInput(.correct, source: .human))

        await #expect(throws: ScanStoreError.staleRecord(record.id)) {
            try await store.update(record)
        }
        await #expect(throws: ScanStoreError.staleRecord(record.id)) {
            try await store.update([record])
        }
        // The same log, or a longer one, is fine.
        try await store.update(decided)
        let extended = decided.deciding(DecisionInput(.voided, source: .human), id: Decision.ID(rawValue: UUID()), at: Fixtures.epoch)
        try await store.update([extended])
        #expect(await store.records(in: batch.id).first?.decisions.count == 2)
    }

    /// A spot-check on the History screen corrects a confident scan while the
    /// Scan tab still holds the run's pending copy. Accepting afterwards must
    /// not overwrite the correction, and the stale copy cannot be written back.
    @Test func aSpotCheckCorrectionSurvivesALaterBulkAccept() async throws {
        let store = InMemoryScanStore()
        let feeder = StubFeeder(script: [.fed])
        let scanner = makeScannerModel(store: store, feeder: feeder)
        await scanner.start()
        scanner.connectFeeder()
        scanner.startAutoScan()
        await scanner.autoScanTask?.value
        let staleCopy = try #require(scanner.runRecords.first)
        #expect(staleCopy.isAutoConfirmable)

        let history = BatchDetailModel(batch: batch, store: store, directory: Fixtures.directory)
        await history.load()
        let shown = try #require(history.records.value?.first)
        await history.update(shown, verdict: .corrected(Fixtures.jinx.id))
        #expect(history.records.value?.first?.decisions.map(\.source) == [.human])

        await scanner.acceptConfidentScans()
        #expect(scanner.acceptedCount == 0, "the corrected scan was no longer pending on disk")
        #expect(scanner.storageProblem == nil)

        let stored = try #require(await store.records(in: batch.id).first)
        #expect(stored.decisions.count == 1)
        #expect(stored.decisions.first?.seq == 1)
        #expect(stored.decisions.first?.source == .human)
        #expect(stored.verdict == .corrected(Fixtures.jinx.id))
        #expect(stored.confirmedCardID == Fixtures.jinx.id)

        await #expect(throws: ScanStoreError.staleRecord(staleCopy.id)) {
            try await store.update(staleCopy)
        }
    }

    @Test func bulkAcceptLeavesUncertainAndAlreadyJudgedScansAlone() async throws {
        let store = InMemoryScanStore()
        await store.save(batch)
        let confident = Fixtures.record(batch: batch.id)
        let uncertain = Fixtures.record(batch: batch.id, codeRead: false)
        let judged = Fixtures.record(batch: batch.id, verdict: .rejected(.notACard))
        for record in [confident, uncertain, judged] {
            try await store.append(record, photo: Data(), rectified: nil)
        }
        let scanner = makeScannerModel(store: store, feeder: StubFeeder(script: [.fed, .fed, .fed]))
        await scanner.start()
        scanner.connectFeeder()
        scanner.startAutoScan()
        await scanner.autoScanTask?.value
        #expect(scanner.runRecords.count == 3)

        await scanner.acceptConfidentScans()
        #expect(scanner.acceptedCount == 3, "the run's own confident scans are accepted")
        let stored = await store.records(in: batch.id)
        #expect(stored.first { $0.id == confident.id }?.verdict == .pending, "a confident scan from another run is not this run's to accept")
        #expect(stored.first { $0.id == uncertain.id }?.verdict == .pending)
        #expect(stored.first { $0.id == judged.id }?.decisions.count == 1)
        #expect(stored.filter { $0.decisions.first?.source == .autoAccepted }.count == 3)
    }

    @Test func historyReJudgementAppendsAHumanDecision() async throws {
        let store = InMemoryScanStore()
        await store.save(batch)
        let record = Fixtures.record(batch: batch.id, verdict: .correct, source: .autoAccepted)
        try await store.append(record, photo: Data(), rectified: nil)
        let history = BatchDetailModel(batch: batch, store: store, directory: Fixtures.directory)
        await history.load()
        await history.update(record, verdict: .correct)
        let stored = try #require(await store.records(in: batch.id).first)
        #expect(stored.decisions.map(\.source) == [.autoAccepted, .human])
        #expect(stored.decisions.map(\.seq) == [1, 2])
        #expect(stored.confirmedCardID == Fixtures.vi.id)
        #expect(history.records.value?.first == stored)
    }
}

/// A clock that advances one second per reading.
nonisolated final class TickingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var ticks = 0

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        ticks += 1
        return Fixtures.epoch.addingTimeInterval(TimeInterval(ticks))
    }
}
