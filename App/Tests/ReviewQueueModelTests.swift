import Foundation
import RiftboundRecognizer
import Testing
@testable import RiftboundScannerApp

@Suite("Review queue")
struct ReviewQueueModelTests {
    private let batch = Fixtures.batch()
    private let store = InMemoryScanStore()

    private func makeModel(
        records: [ScanRecord],
        rule: ConfidenceRule = .default,
        mode: ReviewQueueModel.Mode = .pending,
        sample: @escaping ReviewQueueModel.Sampler = { Array($0.prefix($1)) }
    ) async throws -> ReviewQueueModel {
        await store.save(batch)
        for record in records {
            try await store.append(record, photo: Data(), rectified: nil)
        }
        let model = ReviewQueueModel(batch: batch, store: store, directory: Fixtures.directory, rule: rule, mode: mode, sample: sample)
        await model.load()
        return model
    }

    /// A confident scan whose id the audit sample never picks.
    private func unsampledConfident(at offset: TimeInterval = 0) -> ScanRecord {
        Fixtures.record(id: Fixtures.uuid(firstByte: Fixtures.unsampledByte), batch: batch.id, capturedAt: Fixtures.epoch.addingTimeInterval(offset))
    }

    @Test func queuesOnlyUncertainPendingScansInCaptureOrder() async throws {
        let later = Fixtures.record(batch: batch.id, capturedAt: Fixtures.epoch.addingTimeInterval(20), codeRead: false)
        let earlier = Fixtures.record(batch: batch.id, capturedAt: Fixtures.epoch.addingTimeInterval(10), score: 0.8)
        let confident = unsampledConfident()
        let decided = Fixtures.record(batch: batch.id, verdict: .correct, codeRead: false)
        let model = try await makeModel(records: [later, confident, decided, earlier])

        #expect(model.queue.value?.map(\.id) == [earlier.id, later.id])
        #expect(model.progress == .reviewing(position: 1, of: 2))
        #expect(model.current?.id == earlier.id)
        #expect(model.currentKind == .uncertain(.weakArtMatch))
    }

    /// Audit rows follow the uncertain ones (ADR-002 §6) and their verdicts
    /// are `audit` decisions, so the server can bound precision from them.
    @Test func auditRowsFollowTheUncertainOnesAndWriteAuditDecisions() async throws {
        let uncertain = Fixtures.record(batch: batch.id, capturedAt: Fixtures.epoch.addingTimeInterval(30), codeRead: false)
        let heldEarly = Fixtures.record(id: Fixtures.uuid(firstByte: 0), batch: batch.id, capturedAt: Fixtures.epoch.addingTimeInterval(10))
        let heldLate = Fixtures.record(id: Fixtures.uuid(firstByte: 12), batch: batch.id, capturedAt: Fixtures.epoch.addingTimeInterval(20))
        let accepted = unsampledConfident(at: 15)
        let model = try await makeModel(records: [heldLate, accepted, uncertain, heldEarly])

        #expect(model.queue.value?.map(\.id) == [uncertain.id, heldEarly.id, heldLate.id])
        #expect(model.progress == .reviewing(position: 1, of: 3))
        #expect(model.currentKind == .uncertain(.noCodeRead))

        await model.confirm()
        #expect(model.current?.id == heldEarly.id)
        #expect(model.currentKind == .audit)
        await model.confirm()
        #expect(model.currentKind == .audit)
        await model.correct(to: Fixtures.jinx.id)
        #expect(model.progress == .done(.init(confirmed: 2, corrected: 1, rejected: 0, skipped: 0)))

        let stored = await store.records(in: batch.id)
        #expect(stored.first { $0.id == uncertain.id }?.decisions.map(\.source) == [.human])
        #expect(stored.first { $0.id == heldEarly.id }?.decisions.map(\.source) == [.audit])
        #expect(stored.first { $0.id == heldEarly.id }?.verdict == .correct)
        #expect(stored.first { $0.id == heldLate.id }?.decisions.map(\.source) == [.audit])
        #expect(stored.first { $0.id == heldLate.id }?.verdict == .corrected(Fixtures.jinx.id))
        #expect(stored.first { $0.id == accepted.id }?.verdict == .pending, "not sampled, not in the queue; the strip accepts it")
    }

    @Test func theAuditRateComesFromTheRuleTheQueueWasOpenedWith() async throws {
        let bucketTwo = Fixtures.record(id: Fixtures.uuid(firstByte: 2), batch: batch.id)
        let bucketZero = Fixtures.record(id: Fixtures.uuid(firstByte: 10), batch: batch.id, capturedAt: Fixtures.epoch.addingTimeInterval(1))
        let model = try await makeModel(records: [bucketTwo, bucketZero], rule: ConfidenceRule(randomAudits: 300))
        #expect(model.queue.value?.map(\.id) == [bucketZero.id], "at 0.1 only bucket zero is sampled")
    }

    /// Spot-check 10: a sample of the run's accepted scans, re-judged as
    /// `spotCheck` decisions appended after the machine's.
    @Test func aSpotCheckReJudgesAcceptedScansWithSpotCheckDecisions() async throws {
        let accepted = (0..<4).map { offset in
            Fixtures.record(id: Fixtures.uuid(firstByte: Fixtures.unsampledByte), batch: batch.id, verdict: .correct, source: .autoAccepted, capturedAt: Fixtures.epoch.addingTimeInterval(Double(offset)))
        }
        let human = Fixtures.record(batch: batch.id, verdict: .correct, source: .human)
        let pending = unsampledConfident(at: 9)
        let candidates = accepted.map(\.id) + [human.id, pending.id]
        // Picks the last `limit` offered, to show the sampler decides.
        let model = try await makeModel(records: accepted + [human, pending], mode: .spotCheck(candidates: candidates, limit: 2)) { Array($0.suffix($1)) }

        #expect(model.queue.value?.map(\.id) == [accepted[2].id, accepted[3].id], "only accepted scans qualify; rows run in capture order")
        #expect(model.currentKind == .spotCheck)
        #expect(model.progress == .reviewing(position: 1, of: 2))

        await model.confirm()
        await model.correct(to: Fixtures.jinx.id)
        #expect(model.progress == .done(.init(confirmed: 1, corrected: 1, rejected: 0, skipped: 0)))

        let stored = await store.records(in: batch.id)
        let confirmed = try #require(stored.first { $0.id == accepted[2].id })
        #expect(confirmed.decisions.map(\.source) == [.autoAccepted, .spotCheck])
        #expect(confirmed.decisions.map(\.seq) == [1, 2])
        #expect(confirmed.verdict == .correct)
        let corrected = try #require(stored.first { $0.id == accepted[3].id })
        #expect(corrected.decisions.map(\.source) == [.autoAccepted, .spotCheck])
        #expect(corrected.confirmedCardID == Fixtures.jinx.id)
        #expect(stored.first { $0.id == accepted[0].id }?.decisions.count == 1, "unsampled scans are untouched")
        #expect(stored.first { $0.id == human.id }?.decisions.count == 1)
    }

    @Test func aSpotCheckWithNothingAcceptedSaysSo() async throws {
        let pending = unsampledConfident()
        let model = try await makeModel(records: [pending], mode: .spotCheck(candidates: [pending.id], limit: 10))
        #expect(model.progress == .nothingToReview)
        #expect(model.mode.isSpotCheck)
    }

    @Test func confirmingWritesCorrectAndAdvances() async throws {
        let first = Fixtures.record(batch: batch.id, capturedAt: Fixtures.epoch, codeRead: false)
        let second = Fixtures.record(batch: batch.id, capturedAt: Fixtures.epoch.addingTimeInterval(1), codeRead: false)
        let model = try await makeModel(records: [first, second])

        await model.confirm()
        #expect(model.current?.id == second.id)
        #expect(model.progress == .reviewing(position: 2, of: 2))
        let stored = await store.records(in: batch.id)
        let decided = try #require(stored.first { $0.id == first.id })
        #expect(decided.verdict == .correct)
        #expect(decided.verdictAt == Fixtures.epoch)
        #expect(decided.decisions.map(\.source) == [.human], "a reviewed verdict is a human label")
        #expect(decided.decisions.first?.cardID == Fixtures.vi.id)
        #expect(model.tally.confirmed == 1)
    }

    @Test func correctingToAnotherCardWritesCorrectedButToTheTopCandidateWritesCorrect() async throws {
        let first = Fixtures.record(batch: batch.id, capturedAt: Fixtures.epoch, codeRead: false)
        let second = Fixtures.record(batch: batch.id, capturedAt: Fixtures.epoch.addingTimeInterval(1), codeRead: false)
        let model = try await makeModel(records: [first, second])

        await model.correct(to: Fixtures.jinx.id)
        await model.correct(to: Fixtures.vi.id)
        let stored = await store.records(in: batch.id)
        #expect(stored.first { $0.id == first.id }?.verdict == .corrected(Fixtures.jinx.id))
        #expect(stored.first { $0.id == first.id }?.confirmedCardID == Fixtures.jinx.id)
        #expect(stored.first { $0.id == second.id }?.verdict == .correct)
        #expect(stored.allSatisfy { $0.decisions.allSatisfy { $0.source == .human } })
        #expect(model.tally == .init(confirmed: 1, corrected: 1, rejected: 0, skipped: 0))
    }

    @Test func rejectingAndSkippingAdvanceAndFinishWithADoneState() async throws {
        let first = Fixtures.record(batch: batch.id, capturedAt: Fixtures.epoch, codeRead: false)
        let second = Fixtures.record(batch: batch.id, capturedAt: Fixtures.epoch.addingTimeInterval(1), codeRead: false)
        let model = try await makeModel(records: [first, second])

        await model.reject(.notACard)
        model.skip()
        #expect(model.progress == .done(.init(confirmed: 0, corrected: 0, rejected: 1, skipped: 1)))
        #expect(model.current == nil)
        let stored = await store.records(in: batch.id)
        #expect(stored.first { $0.id == first.id }?.verdict == .rejected(.notACard))
        #expect(stored.first { $0.id == second.id }?.verdict == .pending, "skipping leaves the scan pending")

        // Verdicts after the end are ignored rather than crashing.
        await model.confirm()
        model.skip()
        #expect(model.progress == .done(.init(confirmed: 0, corrected: 0, rejected: 1, skipped: 1)))
    }

    @Test func aBatchWithNothingUncertainSaysSo() async throws {
        let model = try await makeModel(records: [unsampledConfident()])
        #expect(model.progress == .nothingToReview)
    }

    @Test func dominantSetFollowsTheMostCommonTopCandidate() async throws {
        let rune = Fixtures.record(batch: batch.id, candidates: [Fixtures.radRune])
        let model = try await makeModel(records: [rune, Fixtures.record(batch: batch.id), Fixtures.record(batch: batch.id)])
        #expect(model.dominantSet?.rawValue == "OGN")
    }

    @Test func storageFailureIsSurfacedAndDoesNotAdvance() async throws {
        let record = Fixtures.record(batch: batch.id, codeRead: false)
        let model = try await makeModel(records: [record])
        await store.deleteBatch(batch.id)
        await model.confirm()
        #expect(model.storageProblem != nil)
        #expect(model.current?.id == record.id)
        model.dismissStorageProblem()
        #expect(model.storageProblem == nil)
    }
}
