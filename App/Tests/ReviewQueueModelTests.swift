import Foundation
import RiftboundRecognizer
import Testing
@testable import RiftboundScannerApp

@Suite("Review queue")
struct ReviewQueueModelTests {
    private let batch = Fixtures.batch()
    private let store = InMemoryScanStore()

    private func makeModel(records: [ScanRecord]) async throws -> ReviewQueueModel {
        await store.save(batch)
        for record in records {
            try await store.append(record, photo: Data(), rectified: nil)
        }
        let model = ReviewQueueModel(batch: batch, store: store, directory: Fixtures.directory)
        await model.load()
        return model
    }

    @Test func queuesOnlyUncertainPendingScansInCaptureOrder() async throws {
        let later = Fixtures.record(batch: batch.id, capturedAt: Fixtures.epoch.addingTimeInterval(20), codeRead: false)
        let earlier = Fixtures.record(batch: batch.id, capturedAt: Fixtures.epoch.addingTimeInterval(10), score: 0.8)
        let confident = Fixtures.record(batch: batch.id, capturedAt: Fixtures.epoch)
        let decided = Fixtures.record(batch: batch.id, verdict: .correct, codeRead: false)
        let model = try await makeModel(records: [later, confident, decided, earlier])

        #expect(model.queue.value?.map(\.id) == [earlier.id, later.id])
        #expect(model.progress == .reviewing(position: 1, of: 2))
        #expect(model.current?.id == earlier.id)
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
        let model = try await makeModel(records: [Fixtures.record(batch: batch.id)])
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
