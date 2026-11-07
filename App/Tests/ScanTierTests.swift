import Foundation
import RiftboundRecognizer
import Testing
@testable import RiftboundScannerApp

/// The five tiers a pending scan can land in and the printing chips behind
/// "Pick printing" (ADR-002 §6, decisions 13 and 16).
@Suite("Scan tiers")
struct ScanTierTests {
    private let sealedBox = Fixtures.makeBatch(ScanBatch.Setup(label: "box", purpose: .collection, product: .sealedBox(set: SetCode(rawValue: "OGN")!), defaultFinish: .normal))
    private let loosePile = Fixtures.makeBatch(ScanBatch.Setup(label: "pile", purpose: .collection, product: .loose, defaultFinish: .normal))
    private let calibration = Fixtures.makeBatch(ScanBatch.Setup(label: "test", purpose: .calibration, product: .loose))

    private func tier(_ record: ScanRecord, in batch: ScanBatch) -> ScanTier? {
        record.tier(under: .default, in: batch, vault: Fixtures.vault, directory: Fixtures.directory)
    }

    @Test func aLiterallyReadCodeWithASettledPrintingIsConfident() {
        let record = Fixtures.record(id: Fixtures.uuid(firstByte: Fixtures.unsampledByte), batch: sealedBox.id)
        #expect(tier(record, in: sealedBox) == .confident)
        #expect(record.isAcceptable(under: .default, in: sealedBox, vault: Fixtures.vault, directory: Fixtures.directory))
        #expect(record.isHeldForAudit(under: .default, in: sealedBox, vault: Fixtures.vault, directory: Fixtures.directory) == false)
        let held = Fixtures.record(id: Fixtures.uuid(firstByte: 0), batch: sealedBox.id)
        #expect(tier(held, in: sealedBox) == .confident)
        #expect(held.isHeldForAudit(under: .default, in: sealedBox, vault: Fixtures.vault, directory: Fixtures.directory))
        #expect(held.reviewKind(under: .default, in: sealedBox, vault: Fixtures.vault, directory: Fixtures.directory) == .audit)
    }

    @Test func anUncertainScanNeedsALook() {
        #expect(tier(Fixtures.record(batch: sealedBox.id, codeRead: false), in: sealedBox) == .needsALook)
        #expect(tier(Fixtures.record(batch: sealedBox.id, score: 0.8), in: sealedBox) == .needsALook)
        #expect(tier(Fixtures.record(batch: sealedBox.id, codeOrigin: .alternative), in: sealedBox) == .needsALook)
    }

    @Test func anUnsettledVariantAsksForThePrinting() throws {
        let record = Fixtures.record(batch: sealedBox.id, codeAgreement: .variantDiffers)
        #expect(tier(record, in: sealedBox) == .pickPrinting)
        let options = try #require(record.printingOptions(in: sealedBox, vault: Fixtures.vault, directory: Fixtures.directory))
        #expect(options.shown.map(\.code) == ["OGN-001", "OGN-001a"], "both printings of the art are in the index; the code decides")
        #expect(options.needsChoice == false, "the index can see both, so a confident code would have settled it")
    }

    /// Jinx comes as OGN-002 and the promo OGN-002-P, which the recogniser
    /// cannot tell apart. A sealed box holds no promos, so the box batch stays
    /// confident with the promo folded away; a loose pile must ask.
    @Test func anInvisibleSiblingAsksForThePrintingOutsideASealedBox() throws {
        let jinx = Fixtures.record(batch: loosePile.id, candidates: [Fixtures.jinx, Fixtures.vi])
        #expect(tier(jinx, in: loosePile) == .pickPrinting)
        let loose = try #require(jinx.printingOptions(in: loosePile, vault: Fixtures.vault, directory: Fixtures.directory))
        #expect(loose.shown.map(\.code) == ["OGN-002", "OGN-002-P"])
        #expect(loose.hidden.isEmpty)
        #expect(loose.needsChoice)
        #expect(loose.recognized == PrintingKey(rawValue: "OGN-002"))

        #expect(tier(jinx, in: sealedBox) == .confident)
        let boxed = try #require(jinx.printingOptions(in: sealedBox, vault: Fixtures.vault, directory: Fixtures.directory))
        #expect(boxed.shown.map(\.code) == ["OGN-002"])
        #expect(boxed.hidden.map(\.code) == ["OGN-002-P"], "promo siblings sit behind Other printings… for a sealed box")
        #expect(boxed.needsChoice == false)
        #expect(boxed.hasAlternatives, "the disclosure still offers the promo")

        #expect(tier(jinx, in: calibration) == .confident, "a calibration batch ledgers nothing, so there is no printing to pick")
        #expect(jinx.isAcceptable(under: .default, in: loosePile, vault: Fixtures.vault, directory: Fixtures.directory) == false)
    }

    @Test func aScanMarkedAsRepeatingAnotherIsAPossibleDuplicate() {
        let earlier = ScanRecord.ID(rawValue: UUID())
        let analysis = Fixtures.analysis(for: Fixtures.result(cards: [Fixtures.vi, Fixtures.jinx])).markingDuplicate(of: earlier)
        let record = Fixtures.record(batch: sealedBox.id, analysis: analysis)
        #expect(tier(record, in: sealedBox) == .possibleDuplicate)
        #expect(record.analysis?.duplicateOf == earlier)
        #expect(record.isAcceptable(under: .default, in: sealedBox, vault: Fixtures.vault, directory: Fixtures.directory) == false, "a duplicate is never accepted in bulk however confident it looks")
        #expect(record.reviewKind(under: .default, in: sealedBox, vault: Fixtures.vault, directory: Fixtures.directory) == .possibleDuplicate)
    }

    @Test func noCandidateAtAllIsUnknown() {
        let record = Fixtures.record(batch: sealedBox.id, candidates: [])
        #expect(tier(record, in: sealedBox) == .unknown)
        #expect(record.reviewKind(under: .default, in: sealedBox, vault: Fixtures.vault, directory: Fixtures.directory) == .unknown)
        #expect(ReviewKind.unknown.source == .human)
        #expect(ReviewKind.pickPrinting.source == .human)
        #expect(ReviewKind.possibleDuplicate.source == .human)
    }

    @Test func aDecidedScanHasNoTier() {
        #expect(tier(Fixtures.record(batch: sealedBox.id, verdict: .correct), in: sealedBox) == nil)
        #expect(tier(Fixtures.record(batch: sealedBox.id, verdict: .rejected(.duplicateCapture)), in: sealedBox) == nil)
    }

    @Test func everyTierHasALabel() {
        #expect(ScanTier.allCases.count == 5)
        #expect(Set(ScanTier.allCases.map(\.label)).count == 5)
        #expect(ScanTier.allCases.filter(\.needsAPerson) == [.needsALook, .pickPrinting, .possibleDuplicate, .unknown])
    }

    @Test func tierCountsSplitARunAndHoldTheAuditSample() {
        let confidentHeld = Fixtures.record(id: Fixtures.uuid(firstByte: 0), batch: sealedBox.id)
        let confidentFree = Fixtures.record(id: Fixtures.uuid(firstByte: Fixtures.unsampledByte), batch: sealedBox.id)
        let needsLook = Fixtures.record(batch: sealedBox.id, codeRead: false)
        let unknown = Fixtures.record(batch: sealedBox.id, candidates: [])
        let decided = Fixtures.record(batch: sealedBox.id, verdict: .correct)
        let counts = TierCounts(records: [confidentHeld, confidentFree, needsLook, unknown, decided], rule: .default, batch: sealedBox, vault: Fixtures.vault, directory: Fixtures.directory)
        #expect(counts[.confident] == 2)
        #expect(counts.heldForAudit == 1)
        #expect(counts.acceptable == 1)
        #expect(counts[.needsALook] == 1)
        #expect(counts[.unknown] == 1)
        #expect(counts[.pickPrinting] == 0)
        #expect(counts[.possibleDuplicate] == 0)
        #expect(counts.decided == 1)
        #expect(counts.toReview == 3, "two that need a person plus the audit hold")
        #expect(TierCounts(records: [confidentFree], rule: .default, batch: nil, vault: Fixtures.vault, directory: Fixtures.directory).toReview == 0)
    }

    @Test func aSealedBoxHidesPromosAndNothingElseDoes() {
        #expect(BatchProduct.sealedBox(set: SetCode(rawValue: "OGN")!).hidesPromoPrintings)
        #expect(BatchProduct.loose.hidesPromoPrintings == false)
        #expect(BatchProduct.other("binder").hidesPromoPrintings == false)
    }
}
