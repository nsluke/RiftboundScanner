import Foundation
import RiftboundRecognizer
import Testing
@testable import RiftboundScannerApp

/// The builder is pure: decisions in, ledger items out, with the server's
/// acknowledgements deciding whether an undo is owed (ADR-002, decision 2).
@Suite("Ledger delta builder")
struct LedgerDeltaBuilderTests {
    private let scanID = UUID(uuidString: "8D59A1B2-0000-4000-8000-000000000001")!
    private let collection = Fixtures.batch(purpose: .collection, defaultFinish: .foil)
    private let promo = PrintingKey(rawValue: "OGN-002-P")

    private func record(_ decisions: [Decision]) -> ScanRecord {
        Fixtures.record(id: scanID, batch: collection.id, decisions: decisions)
    }

    private func items(_ decisions: [Decision], state: ScanSyncState = ScanSyncState(), batch: ScanBatch? = nil) -> [LedgerSyncItem] {
        let batch = batch ?? collection
        return LedgerDeltaBuilder.items(record: Fixtures.record(id: scanID, batch: batch.id, decisions: decisions), previousState: state, batch: batch, vault: Fixtures.vault)
    }

    private func applied(_ seq: Int) -> ScanSyncState {
        var state = ScanSyncState()
        state[.plusOne(ScanRecord.ID(rawValue: scanID), seq: seq)] = .applied(ledgerID: seq, cardID: "OGN-001", finish: .foil)
        return state
    }

    private func delta(_ item: LedgerSyncItem) -> LedgerSyncItem.Delta? {
        if case .delta(let delta) = item { return delta }
        return nil
    }

    private func undo(_ item: LedgerSyncItem) -> LedgerSyncItem.Undo? {
        if case .undo(let undo) = item { return undo }
        return nil
    }

    @Test func aFoilOnlyPrintingCoercesTheFinish() throws {
        let decided = items([Fixtures.decision(.corrected(Fixtures.viAlt.id), cardID: Fixtures.viAlt.id, finish: .set(.normal))])
        let first = try #require(decided.first)
        let delta = try #require(delta(first))
        #expect(decided.count == 1)
        #expect(delta.cardKey == "OGN-001a")
        #expect(delta.finish == .foil, "OGN-001a exists only in foil; the override cannot make it normal")
        #expect(delta.defaultFinish == .foil)
        #expect(delta.quantityDelta == 1)
        #expect(delta.clientRef == "scan:\(scanID.uuidString):1")
        #expect(delta.scanID == scanID)
        #expect(delta.occurredAt == Fixtures.epoch)
    }

    @Test func aNormalOnlyPrintingIsForcedNormal() throws {
        let decided = items([Fixtures.decision(.corrected(Fixtures.radRune.id), cardID: Fixtures.radRune.id, finish: .set(.foil))])
        let first = try #require(decided.first)
        #expect(delta(first)?.finish == .normal, "RAD-R01 exists only in normal; the override cannot make it foil")
        #expect(delta(first)?.cardKey == "RAD-R01")
    }

    @Test func aBothFinishPrintingUsesTheBatchDefaultUnlessOverridden() throws {
        let inherited = items([Fixtures.decision(.correct, cardID: Fixtures.vi.id)])
        #expect(delta(try #require(inherited.first))?.finish == .foil, "the batch default")
        #expect(delta(try #require(inherited.first))?.cardKey == "OGN-001")

        let overridden = items([Fixtures.decision(.correct, cardID: Fixtures.vi.id, finish: .set(.normal))])
        #expect(delta(try #require(overridden.first))?.finish == .normal)

        let normalBatch = Fixtures.batch(purpose: .collection, defaultFinish: .normal)
        let normalDefault = items([Fixtures.decision(.correct, cardID: Fixtures.vi.id)], batch: normalBatch)
        #expect(delta(try #require(normalDefault.first))?.finish == .normal)
        #expect(delta(try #require(normalDefault.first))?.defaultFinish == .normal)
    }

    @Test func anUnknownPrintingSendsTheOverrideAndLetsTheServerDerive() throws {
        let unknown = Card.ID(rawValue: "gone-999")
        let decided = items([Fixtures.decision(.corrected(unknown), cardID: unknown)])
        let first = try #require(decided.first)
        let delta = try #require(delta(first))
        #expect(delta.cardKey == "gone-999", "an id the key parser cannot read goes through as written; the server answers unknown_card")
        #expect(delta.finish == nil)
        #expect(delta.defaultFinish == .foil)
    }

    @Test func anAuditThatAgreesEmitsNothing() {
        let human = Fixtures.decision(.correct, cardID: Fixtures.jinx.id, seq: 1, finish: .set(.foil), ledgerPrintingCode: .set(promo))
        let audit = Fixtures.decision(.correct, cardID: Fixtures.jinx.id, source: .audit, seq: 2)
        #expect(items([human, audit], state: applied(1)).isEmpty, "inherit keeps the foil promo; nothing changes")

        let owed = items([human, audit])
        #expect(owed.map(\.clientRef) == ["scan:\(scanID.uuidString):1"], "with nothing acknowledged the first +1 is still owed, once")
        #expect(delta(owed[0])?.cardKey == "OGN-002-P")
        #expect(delta(owed[0])?.finish == .foil)
    }

    @Test func anAuditThatChangesTheFinishEmitsAnUndoByReferenceAndAPlusOne() throws {
        let human = Fixtures.decision(.correct, cardID: Fixtures.vi.id, seq: 1)
        let audit = Fixtures.decision(.correct, cardID: Fixtures.vi.id, source: .audit, seq: 2, finish: .set(.normal))
        let decided = items([human, audit], state: applied(1))
        #expect(decided.count == 2)
        let undo = try #require(undo(decided[0]))
        #expect(undo.clientRef == "scan:\(scanID.uuidString):2:undo")
        #expect(undo.undoOf == "scan:\(scanID.uuidString):1")
        #expect(undo.scanID == scanID)
        let plus = try #require(delta(decided[1]))
        #expect(plus.clientRef == "scan:\(scanID.uuidString):2")
        #expect(plus.finish == .normal)
    }

    @Test func aCorrectionBeforeTheFirstPlusOneWasAppliedEmitsOnlyThePlusOne() throws {
        let first = Fixtures.decision(.correct, cardID: Fixtures.vi.id, source: .autoAccepted, seq: 1)
        let corrected = Fixtures.decision(.corrected(Fixtures.jinx.id), cardID: Fixtures.jinx.id, seq: 2)
        for state in [ScanSyncState(), { var s = ScanSyncState(); s[.plusOne(ScanRecord.ID(rawValue: scanID), seq: 1)] = .queued; return s }()] {
            let decided = items([first, corrected], state: state)
            #expect(decided.map(\.clientRef) == ["scan:\(scanID.uuidString):2"])
            #expect(delta(try #require(decided.first))?.cardKey == "OGN-002")
        }
    }

    @Test func aRejectionAfterLedgeringEmitsOnlyTheUndo() throws {
        let first = Fixtures.decision(.correct, cardID: Fixtures.vi.id, source: .autoAccepted, seq: 1)
        let rejected = Fixtures.decision(.rejected(.notACard), cardID: nil, seq: 2)
        let decided = items([first, rejected], state: applied(1))
        #expect(decided.count == 1)
        let undo = try #require(undo(decided[0]))
        #expect(undo.undoOf == "scan:\(scanID.uuidString):1")
        #expect(undo.clientRef == "scan:\(scanID.uuidString):2:undo")
    }

    @Test func voidingAfterLedgeringEmitsOnlyTheUndo() throws {
        let first = Fixtures.decision(.correct, cardID: Fixtures.vi.id, seq: 1)
        let voided = Fixtures.decision(.voided, cardID: nil, seq: 2)
        let decided = items([first, voided], state: applied(1))
        #expect(decided.map(\.clientRef) == ["scan:\(scanID.uuidString):2:undo"])
        #expect(items([first, voided]).isEmpty, "a +1 that never reached the server is withdrawn, not reversed")
    }

    @Test func calibrationAndLegacyEmitNothing() {
        let calibration = Fixtures.batch(purpose: .calibration, defaultFinish: .normal)
        #expect(items([Fixtures.decision(.correct, cardID: Fixtures.vi.id)], batch: calibration).isEmpty)
        #expect(items([Fixtures.decision(.correct, cardID: Fixtures.vi.id, source: .legacy)]).isEmpty)
        #expect(items([Fixtures.decision(.rejected(.unreadable), cardID: nil)]).isEmpty)
        #expect(items([]).isEmpty)
    }

    @Test func acknowledgedItemsAreNeverEmittedAgain() {
        let first = Fixtures.decision(.correct, cardID: Fixtures.vi.id, seq: 1)
        let rejected = Fixtures.decision(.rejected(.notACard), cardID: nil, seq: 2)
        var state = applied(1)
        state[.undo(ScanRecord.ID(rawValue: scanID), seq: 2)] = .terminal(.nothingToUndo)
        #expect(items([first, rejected], state: state).isEmpty)

        let again = Fixtures.decision(.correct, cardID: Fixtures.vi.id, seq: 3)
        #expect(items([first, rejected, again], state: state).map(\.clientRef) == ["scan:\(scanID.uuidString):3"], "a fresh +1 after an acknowledged undo, with nothing to reverse")
    }

    @Test func aTerminalPlusOneIsNotUndoneWhenTheEffectChanges() {
        let first = Fixtures.decision(.correct, cardID: Fixtures.vi.id, seq: 1)
        let corrected = Fixtures.decision(.corrected(Fixtures.jinx.id), cardID: Fixtures.jinx.id, seq: 2)
        var state = ScanSyncState()
        state[.plusOne(ScanRecord.ID(rawValue: scanID), seq: 1)] = .terminal(.unknownCard(catalogVersion: "cat-1"))
        #expect(items([first, corrected], state: state).map(\.clientRef) == ["scan:\(scanID.uuidString):2"], "nothing landed, so there is nothing to undo")
    }

    @Test func aDuplicateAcknowledgedPlusOneIsUndoneWhenTheEffectChanges() throws {
        let first = Fixtures.decision(.correct, cardID: Fixtures.vi.id, source: .autoAccepted, seq: 1)
        let rejected = Fixtures.decision(.rejected(.notACard), cardID: nil, seq: 2)
        var state = ScanSyncState()
        state[.plusOne(ScanRecord.ID(rawValue: scanID), seq: 1)] = .terminal(.duplicate)
        let decided = items([first, rejected], state: state)
        #expect(decided.map(\.clientRef) == ["scan:\(scanID.uuidString):2:undo"], "duplicate means the server holds the row: it is live and must be reversed")
        #expect(undo(try #require(decided.first))?.undoOf == "scan:\(scanID.uuidString):1")

        let corrected = Fixtures.decision(.corrected(Fixtures.jinx.id), cardID: Fixtures.jinx.id, seq: 2)
        #expect(items([first, corrected], state: state).map(\.clientRef) == ["scan:\(scanID.uuidString):2:undo", "scan:\(scanID.uuidString):2"])
    }

    @Test func aSentButUnansweredPlusOneIsResentAndUndoneWhenTheEffectChanges() throws {
        let first = Fixtures.decision(.correct, cardID: Fixtures.vi.id, source: .autoAccepted, seq: 1)
        let rejected = Fixtures.decision(.rejected(.notACard), cardID: nil, seq: 2)
        var state = ScanSyncState()
        state[.plusOne(ScanRecord.ID(rawValue: scanID), seq: 1)] = .sent
        let decided = items([first, rejected], state: state)
        #expect(decided.map(\.clientRef) == ["scan:\(scanID.uuidString):1", "scan:\(scanID.uuidString):2:undo"], "the server may hold the +1: replay it (duplicate or applied), then reverse it by reference")
        #expect(undo(decided[1])?.undoOf == "scan:\(scanID.uuidString):1")

        #expect(items([first], state: state).map(\.clientRef) == ["scan:\(scanID.uuidString):1"], "an unanswered +1 that still stands goes again")
    }

    @Test func theSameInputsAlwaysGiveTheSameItems() {
        let log = [
            Fixtures.decision(.correct, cardID: Fixtures.vi.id, source: .autoAccepted, seq: 1),
            Fixtures.decision(.corrected(Fixtures.jinx.id), cardID: Fixtures.jinx.id, seq: 2, finish: .set(.normal)),
            Fixtures.decision(.correct, cardID: Fixtures.jinx.id, source: .spotCheck, seq: 3),
        ]
        #expect(items(log, state: applied(1)) == items(log, state: applied(1)))
        #expect(items(log, state: applied(1)).map(\.clientRef) == ["scan:\(scanID.uuidString):2:undo", "scan:\(scanID.uuidString):2"])
    }

    @Test func clientRefsRoundTrip() throws {
        let id = ScanRecord.ID(rawValue: scanID)
        let plus = ClientRef.plusOne(id, seq: 3)
        let undo = ClientRef.undo(id, seq: 4)
        #expect(plus.description == "scan:\(scanID.uuidString):3")
        #expect(undo.description == "scan:\(scanID.uuidString):4:undo")
        #expect(ClientRef(plus.description) == plus)
        #expect(ClientRef(undo.description) == undo)
        #expect(ClientRef("manual:3F2A") == nil)
        #expect(ClientRef("scan:\(scanID.uuidString):0") == nil)
        #expect(ClientRef("scan:\(scanID.uuidString):2:redo") == nil)
    }
}
