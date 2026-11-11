import Foundation
import RiftboundRecognizer
import Testing
@testable import RiftboundScannerApp

@Suite("Review triage grid")
struct ReviewTriageModelTests {
    private let store = InMemoryScanStore()

    private func makeModel(batch: ScanBatch = Fixtures.batch(), records: [ScanRecord]) async throws -> ReviewTriageModel {
        await store.save(batch)
        for record in records {
            try await store.append(record, photo: Data(), rectified: nil)
        }
        let model = ReviewTriageModel(batch: batch, store: store, directory: Fixtures.directory, vault: Fixtures.vault)
        await model.load()
        return model
    }

    private func uncertain(_ batch: ScanBatch, at offset: TimeInterval, candidates: [Card] = [Fixtures.vi, Fixtures.jinx]) -> ScanRecord {
        Fixtures.record(batch: batch.id, candidates: candidates, capturedAt: Fixtures.epoch.addingTimeInterval(offset), codeRead: false)
    }

    /// Only the recogniser's doubt makes a tile. An audit stays a deliberate
    /// look (ADR-002, decision 6) and an unknown card has nothing to confirm.
    @Test func tilesAreTheUncertainScansWithAMatchInCaptureOrder() async throws {
        let batch = Fixtures.batch()
        let later = uncertain(batch, at: 20)
        let earlier = uncertain(batch, at: 10)
        let accepted = Fixtures.record(id: Fixtures.uuid(firstByte: Fixtures.unsampledByte), batch: batch.id)
        let audit = Fixtures.record(id: Fixtures.uuid(firstByte: 0), batch: batch.id, capturedAt: Fixtures.epoch.addingTimeInterval(5))
        let unknown = Fixtures.record(batch: batch.id, candidates: [], codeRead: false)
        let decided = Fixtures.record(batch: batch.id, verdict: .correct, codeRead: false)
        let model = try await makeModel(batch: batch, records: [later, accepted, audit, unknown, decided, earlier])

        #expect(model.tiles.value?.map(\.id) == [earlier.id, later.id])
        #expect(model.leftForQueue == 2, "the audit and the unknown card go to the queue")
        #expect(model.focusedID == earlier.id)
        #expect(model.unflaggedCount == 2)
    }

    @Test func confirmingWritesACorrectHumanDecisionForEachUnflaggedTile() async throws {
        let batch = Fixtures.batch()
        let first = uncertain(batch, at: 1)
        let wrong = uncertain(batch, at: 2)
        let third = uncertain(batch, at: 3)
        let model = try await makeModel(batch: batch, records: [first, wrong, third])

        model.toggleFlag(wrong.id)
        #expect(model.flagged == [wrong.id])
        #expect(model.unflaggedCount == 2)
        await model.confirmUnflagged()

        #expect(model.phase == .confirmed(2))
        let stored = await store.records(in: batch.id)
        for id in [first.id, third.id] {
            let record = try #require(stored.first { $0.id == id })
            #expect(record.decisions.map(\.verdict) == [.correct])
            #expect(record.decisions.map(\.source) == [.human])
        }
        #expect(stored.first { $0.id == wrong.id }?.decisions.isEmpty == true, "a flagged tile is left for the fix panel")
    }

    @Test func deletingATileVoidsItAndMovesTheFocusOn() async throws {
        let batch = Fixtures.batch()
        let first = uncertain(batch, at: 1)
        let second = uncertain(batch, at: 2)
        let third = uncertain(batch, at: 3)
        let model = try await makeModel(batch: batch, records: [first, second, third])
        model.toggleFlag(second.id)
        model.focusedID = second.id

        await model.delete(second.id)

        #expect(model.tiles.value?.map(\.id) == [first.id, third.id])
        #expect(model.focusedID == third.id, "the tile that takes its place")
        #expect(model.flagged.isEmpty)
        #expect(model.deletedCount == 1)
        let stored = try #require(await store.records(in: batch.id).first { $0.id == second.id })
        #expect(stored.decisions.map(\.verdict) == [.voided])
        #expect(stored.decisions.map(\.source) == [.human])

        await model.delete(third.id)
        #expect(model.focusedID == first.id, "the last tile hands the focus back")
        await model.confirmUnflagged()
        #expect(model.phase == .confirmed(1), "deleted tiles are not confirmed")
    }

    @Test func flaggingTwiceUnflags() async throws {
        let batch = Fixtures.batch()
        let record = uncertain(batch, at: 1)
        let model = try await makeModel(batch: batch, records: [record])
        model.toggleFlag(record.id)
        model.toggleFlag(record.id)
        #expect(model.flagged.isEmpty)
    }

    /// Vi comes in both finishes, the rune in one: only Vi can be marked foil,
    /// and only a change from the inherited finish is written.
    @Test func aFoilMarkIsWrittenOnlyForAPrintingThatAsks() async throws {
        let batch = Fixtures.batch(purpose: .collection, defaultFinish: .normal)
        let plain = uncertain(batch, at: 1)
        let foil = uncertain(batch, at: 2)
        let rune = uncertain(batch, at: 3, candidates: [Fixtures.radRune])
        let model = try await makeModel(batch: batch, records: [plain, foil, rune])

        let tiles = try #require(model.tiles.value)
        #expect(tiles.map(model.asksForFinish) == [true, true, false])
        model.toggleFoil(foil.id)
        model.toggleFoil(rune.id)
        #expect(model.finish(of: tiles[1]) == .foil)
        #expect(model.finish(of: tiles[2]) == .normal, "a single-finish printing is left alone")
        await model.confirmUnflagged()

        let stored = await store.records(in: batch.id)
        #expect(stored.first { $0.id == plain.id }?.decisions.map(\.finish) == [.inherit])
        #expect(stored.first { $0.id == foil.id }?.decisions.map(\.finish) == [.set(.foil)])
        #expect(stored.first { $0.id == rune.id }?.decisions.map(\.finish) == [.inherit])
    }

    @Test func togglingFoilBackLeavesTheFinishInherited() async throws {
        let batch = Fixtures.batch(purpose: .collection, defaultFinish: .normal)
        let record = uncertain(batch, at: 1)
        let model = try await makeModel(batch: batch, records: [record])
        model.toggleFoil(record.id)
        model.toggleFoil(record.id)
        await model.confirmUnflagged()
        #expect(await store.records(in: batch.id).first?.decisions.map(\.finish) == [.inherit])
    }

    @Test func theFocusMovesByTilesAndRowsAndStopsAtTheEdges() async throws {
        let batch = Fixtures.batch()
        let records = (0..<5).map { uncertain(batch, at: TimeInterval($0)) }
        let model = try await makeModel(batch: batch, records: records)
        let ids = records.map(\.id)

        model.moveFocus(.right, columns: 2)
        #expect(model.focusedID == ids[1])
        model.moveFocus(.down, columns: 2)
        #expect(model.focusedID == ids[3])
        model.moveFocus(.down, columns: 2)
        #expect(model.focusedID == ids[3], "no tile below")
        model.moveFocus(.left, columns: 2)
        #expect(model.focusedID == ids[2])
        model.moveFocus(.up, columns: 2)
        #expect(model.focusedID == ids[0])
        model.moveFocus(.left, columns: 2)
        #expect(model.focusedID == ids[0])
    }

    @Test func aStorageFailureKeepsTheGridAndSaysSo() async throws {
        let batch = Fixtures.batch()
        let records = [uncertain(batch, at: 1), uncertain(batch, at: 2)]
        let model = try await makeModel(batch: batch, records: records)
        await store.deleteBatch(batch.id)

        await model.confirmUnflagged()

        #expect(model.storageProblem != nil)
        #expect(model.phase == .triaging)
        #expect(model.tiles.value?.count == 2)
        model.dismissStorageProblem()
        #expect(model.storageProblem == nil)
    }
}

@Suite("Review queue after triage")
struct ReviewQueueAfterTriageTests {
    private let batch = Fixtures.batch()
    private let store = InMemoryScanStore()

    private func makeModel(records: [ScanRecord], flagged: Set<ScanRecord.ID> = []) async throws -> ReviewQueueModel {
        await store.save(batch)
        for record in records {
            try await store.append(record, photo: Data(), rectified: nil)
        }
        let model = ReviewQueueModel(batch: batch, store: store, directory: Fixtures.directory, vault: Fixtures.vault, flagged: flagged)
        await model.load()
        return model
    }

    private func uncertain(at offset: TimeInterval) -> ScanRecord {
        Fixtures.record(batch: batch.id, capturedAt: Fixtures.epoch.addingTimeInterval(offset), codeRead: false)
    }

    @Test func flaggedScansLeadTheQueueAndOpenInTheFixPanel() async throws {
        let first = uncertain(at: 1)
        let second = uncertain(at: 2)
        let flagged = uncertain(at: 3)
        let model = try await makeModel(records: [first, second, flagged], flagged: [flagged.id])

        #expect(model.queue.value?.map(\.id) == [flagged.id, first.id, second.id])
        #expect(model.currentIsFlagged)
        await model.correct(to: Fixtures.radRune.id)
        #expect(model.current?.id == first.id)
        #expect(!model.currentIsFlagged)
    }

    @Test func theNextFixLooksFirstInTheSetOfTheLastOne() async throws {
        let model = try await makeModel(records: [uncertain(at: 1), uncertain(at: 2)])
        #expect(model.fixSet?.rawValue == "OGN", "the batch's usual set before any fix")
        await model.correct(to: Fixtures.radRune.id)
        #expect(model.fixSet?.rawValue == "RAD")
    }

    /// Decisions are append-only: deciding a scan again after going back adds
    /// a decision that supersedes the first, and the sitting counts it once.
    @Test func goingBackAndDecidingAgainReplacesTheOutcome() async throws {
        let first = uncertain(at: 1)
        let second = uncertain(at: 2)
        let model = try await makeModel(records: [first, second])
        #expect(!model.canGoBack)

        await model.confirm()
        #expect(model.current?.id == second.id)
        model.goBack()
        #expect(model.current?.id == first.id)
        await model.reject(.notACard)

        #expect(model.tally.confirmed == 0)
        #expect(model.tally.rejected == 1)
        #expect(model.current?.id == second.id)
        let stored = await store.records(in: batch.id)
        #expect(stored.first { $0.id == first.id }?.decisions.map(\.verdict) == [.correct, .rejected(.notACard)])
    }

    @Test func skippingAfterDecidingKeepsTheDecision() async throws {
        let first = uncertain(at: 1)
        let model = try await makeModel(records: [first, uncertain(at: 2)])
        await model.confirm()
        model.goBack()
        model.skip()
        #expect(model.tally.confirmed == 1)
        #expect(model.tally.skipped == 0)
    }
}
