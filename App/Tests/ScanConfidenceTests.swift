import Foundation
import RiftboundRecognizer
import Testing
@testable import RiftboundScannerApp

@Suite("Scan confidence")
struct ScanConfidenceTests {
    private let batch = ScanBatch.ID(rawValue: UUID())

    @Test func exactCodeAndStrongScoreIsConfident() {
        let record = Fixtures.record(batch: batch, score: 1.2, codeAgreement: .exact)
        #expect(record.confidence == .confident)
        #expect(record.isAutoConfirmable)
        #expect(record.needsReview == false)
    }

    @Test func scoreExactlyAtTheBarIsConfident() {
        #expect(Fixtures.record(batch: batch, score: 1.0).confidence == .confident)
    }

    @Test func noCodeReadIsUncertain() {
        let record = Fixtures.record(batch: batch, codeRead: false, score: 1.3, codeAgreement: nil)
        #expect(record.confidence == .uncertain(.noCodeRead))
        #expect(record.needsReview)
    }

    @Test func exactCodeWithWeakScoreIsUncertain() {
        #expect(Fixtures.record(batch: batch, score: 0.9, descriptorScore: 0.4).confidence == .uncertain(.weakArtMatch))
    }

    @Test(arguments: [CodeAgreement.numberDiffers, .setDiffers, .unrelated])
    func disagreeingCodeIsUncertain(agreement: CodeAgreement) {
        #expect(Fixtures.record(batch: batch, score: 1.2, codeAgreement: agreement).confidence == .uncertain(.codeDisagrees))
    }

    @Test func variantMismatchIsItsOwnReason() {
        #expect(Fixtures.record(batch: batch, score: 1.2, codeAgreement: .variantDiffers).confidence == .uncertain(.variantOnly))
    }

    @Test func noCandidatesIsUncertain() {
        #expect(Fixtures.record(batch: batch, candidates: [], codeRead: false).confidence == .uncertain(.noCodeRead))
        #expect(Fixtures.record(batch: batch, candidates: []).confidence == .uncertain(.codeDisagrees))
    }

    @Test func decidedScansNeverNeedReview() {
        let record = Fixtures.record(batch: batch, verdict: .correct, codeRead: false)
        #expect(record.needsReview == false)
        #expect(record.isAutoConfirmable == false)
    }

    @Test func reasonTextMentionsWeakArtOnlyWhenItIsWeak() {
        let weak = Fixtures.record(batch: batch, codeRead: false, descriptorScore: 0.3)
        let strong = Fixtures.record(batch: batch, codeRead: false, descriptorScore: 0.9)
        #expect(UncertaintyReason.noCodeRead.message(isArtWeak: weak.hasWeakArtMatch).contains("weak"))
        #expect(!UncertaintyReason.noCodeRead.message(isArtWeak: strong.hasWeakArtMatch).contains("weak"))
    }
}
