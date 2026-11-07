import Foundation
import RiftboundRecognizer
import Testing
@testable import RiftboundScannerApp

@Suite("Scan confidence")
struct ScanConfidenceTests {
    private let batch = ScanBatch.ID(rawValue: UUID())

    // MARK: - The nine original cases, under the default rule

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

    // MARK: - ADR-002 decision 9: the literal-code requirement and the exemplar veto

    /// The two confident misreads that motivated the veto: OCR read `024` for
    /// `014`, the render of 024 scored 0.575 and an exemplar of the true card
    /// scored 0.911 against the photo. Different art groups, so the veto fires.
    @Test func anExemplarOfAnotherArtGroupVetoesTheConfidentTier() {
        let record = Fixtures.record(
            batch: batch,
            candidates: [Fixtures.sfd024, Fixtures.sfd014],
            score: 1.075,
            descriptorScore: 0.575,
            analysis: Fixtures.analysis(shortlist: [
                Fixtures.shortlistEntry(Fixtures.sfd024, referenceScore: 0.575, codeAgreement: .exact),
                Fixtures.shortlistEntry(Fixtures.sfd014, referenceScore: 0.591, exemplarSimilarity: 0.911),
            ])
        )
        #expect(record.confidence == .uncertain(.exemplarDisagrees))
        #expect(record.needsReview)
        #expect(record.reviewKind(under: .default) == .uncertain(.exemplarDisagrees))
        #expect(UncertaintyReason.exemplarDisagrees.label == "Looks like another card")
        #expect(UncertaintyReason.exemplarDisagrees.message(isArtWeak: false).contains("confirmed before"))
    }

    /// `sfd-014` and `sfd-014a` share an illustration and an art group; the
    /// alternate's exemplar agrees with the top, it does not contradict it.
    @Test func aSameArtSiblingExemplarNeverVetoes() {
        let record = Fixtures.record(
            batch: batch,
            candidates: [Fixtures.sfd014, Fixtures.sfd014a],
            score: 1.09,
            descriptorScore: 0.59,
            analysis: Fixtures.analysis(shortlist: [
                Fixtures.shortlistEntry(Fixtures.sfd014, referenceScore: 0.59, codeAgreement: .exact),
                Fixtures.shortlistEntry(Fixtures.sfd014a, referenceScore: 0.58, exemplarSimilarity: 0.93),
            ])
        )
        #expect(Fixtures.sfd014.artGroup == Fixtures.sfd014a.artGroup)
        #expect(record.confidence == .confident)
        #expect(record.isAutoConfirmable)
    }

    @Test func aTopMatchedThroughAParserAlternativeIsCodeRepaired() {
        let repaired = Fixtures.record(batch: batch, score: 1.2, codeAgreement: .exact, codeOrigin: .alternative)
        #expect(repaired.confidence == .uncertain(.codeRepaired))
        #expect(repaired.needsReview)
        #expect(UncertaintyReason.codeRepaired.label == "Code repaired")
        #expect(UncertaintyReason.codeRepaired.message(isArtWeak: false).contains("repaired"))

        // The requirement is a policy value: a rule without it trusts the repair.
        var policy = LearningPolicy.ConfidencePolicy()
        policy.requireLiteralCode = false
        #expect(repaired.confidence(under: ConfidenceRule(policy: policy)) == .confident)
    }

    @Test func codeRepairedOutranksWeakArtAndTheVeto() {
        let record = Fixtures.record(
            batch: batch,
            candidates: [Fixtures.sfd024, Fixtures.sfd014],
            score: 0.9,
            descriptorScore: 0.4,
            codeOrigin: .alternative,
            analysis: Fixtures.analysis(shortlist: [
                Fixtures.shortlistEntry(Fixtures.sfd024, referenceScore: 0.4, codeAgreement: .exact),
                Fixtures.shortlistEntry(Fixtures.sfd014, referenceScore: 0.5, exemplarSimilarity: 0.95),
            ])
        )
        #expect(record.confidence == .uncertain(.codeRepaired))
    }

    /// A correct scan whose descriptor is middling stays confident: there is
    /// no descriptor floor, only the contradiction veto (decision 9).
    @Test func aCorrectScanWithNoContradictionStaysConfident() {
        let bare = Fixtures.record(batch: batch, candidates: [Fixtures.sfd014, Fixtures.sfd024], score: 1.078, descriptorScore: 0.578)
        #expect(bare.confidence == .confident, "no analysis at all: nothing to contradict")

        let belowThreshold = Fixtures.record(
            batch: batch,
            candidates: [Fixtures.sfd014, Fixtures.sfd024],
            score: 1.078,
            descriptorScore: 0.578,
            analysis: Fixtures.analysis(shortlist: [
                Fixtures.shortlistEntry(Fixtures.sfd014, referenceScore: 0.578, codeAgreement: .exact),
                Fixtures.shortlistEntry(Fixtures.sfd024, referenceScore: 0.55, exemplarSimilarity: 0.87),
            ])
        )
        #expect(belowThreshold.confidence == .confident, "0.87 is under the 0.88 threshold")

        let withinMargin = Fixtures.record(
            batch: batch,
            candidates: [Fixtures.sfd014, Fixtures.sfd024],
            score: 1.078,
            descriptorScore: 0.578,
            analysis: Fixtures.analysis(shortlist: [
                Fixtures.shortlistEntry(Fixtures.sfd014, referenceScore: 0.578, exemplarSimilarity: 0.85, codeAgreement: .exact),
                Fixtures.shortlistEntry(Fixtures.sfd024, referenceScore: 0.55, exemplarSimilarity: 0.90),
            ])
        )
        #expect(withinMargin.confidence == .confident, "the top's own exemplar at 0.85 leaves only 0.05 of margin")
    }

    @Test func theVetoThresholdsComeFromThePolicy() {
        let record = Fixtures.record(
            batch: batch,
            candidates: [Fixtures.sfd024, Fixtures.sfd014],
            score: 1.075,
            descriptorScore: 0.575,
            analysis: Fixtures.analysis(shortlist: [
                Fixtures.shortlistEntry(Fixtures.sfd024, referenceScore: 0.575, codeAgreement: .exact),
                Fixtures.shortlistEntry(Fixtures.sfd014, referenceScore: 0.591, exemplarSimilarity: 0.911),
            ])
        )
        var policy = LearningPolicy.ConfidencePolicy()
        policy.exemplarDisagreementThreshold = 0.92
        #expect(record.confidence(under: ConfidenceRule(policy: policy)) == .confident)
        policy.exemplarDisagreementThreshold = 0.88
        policy.exemplarDisagreementMargin = 0.4
        #expect(record.confidence(under: ConfidenceRule(policy: policy)) == .confident)
        policy.exemplarDisagreementMargin = 0.1
        policy.minimumFusedScore = 1.1
        #expect(record.confidence(under: ConfidenceRule(policy: policy)) == .uncertain(.weakArtMatch))
    }

    // MARK: - The audit sample

    /// First bytes 0...19 cover every bucket twice: three buckets in ten at
    /// 0.3 gives six audits, one in ten at 0.1 gives two.
    @Test func twentyCraftedIDsYieldSixAuditsAtThirtyPercentAndTwoAtTen() {
        let ids = (0..<20).map { ScanRecord.ID(rawValue: Fixtures.uuid(firstByte: UInt8($0))) }
        #expect(ids.filter { ConfidenceRule.isAuditSample($0, rate: 0.3) }.count == 6)
        #expect(ids.filter { ConfidenceRule.isAuditSample($0, rate: 0.1) }.count == 2)
        #expect(ids.filter { ConfidenceRule.isAuditSample($0, rate: 0) }.isEmpty)
        #expect(ids.filter { ConfidenceRule.isAuditSample($0, rate: 1) }.count == 20)
        let sampled = ids.filter { ConfidenceRule.isAuditSample($0, rate: 0.3) }.map { Int($0.rawValue.uuid.0) }
        #expect(sampled == [0, 1, 2, 10, 11, 12], "the sample is the UUID's first byte modulo ten, nothing else")
    }

    @Test func theAuditRateFollowsThePolicyAndTheServersAuditCount() {
        #expect(ConfidenceRule.default.auditRate == 0.3)
        #expect(ConfidenceRule(randomAudits: 299).auditRate == 0.3)
        #expect(ConfidenceRule(randomAudits: 300).auditRate == 0.1)
        var policy = LearningPolicy.ConfidencePolicy()
        policy.auditRate = 0.5
        policy.auditRateAfter = 0.2
        policy.auditRateSwitchCount = 10
        #expect(ConfidenceRule(policy: policy, randomAudits: 9).auditRate == 0.5)
        #expect(ConfidenceRule(policy: policy, randomAudits: 10).auditRate == 0.2)
    }

    @Test func aConfidentScanInTheSampleIsHeldForAuditNotAccepted() {
        let held = Fixtures.record(id: Fixtures.uuid(firstByte: 2), batch: batch, score: 1.2)
        let accepted = Fixtures.record(id: Fixtures.uuid(firstByte: 3), batch: batch, score: 1.2)
        let uncertain = Fixtures.record(id: Fixtures.uuid(firstByte: 2), batch: batch, codeRead: false)
        let rule = ConfidenceRule.default

        #expect(held.isAutoConfirmable(under: rule))
        #expect(held.isHeldForAudit(under: rule))
        #expect(!held.isAcceptable(under: rule))
        #expect(!held.needsReview(under: rule), "an audit row is not uncertain; the queue adds it after the uncertain ones")
        #expect(held.reviewKind(under: rule) == .audit)

        #expect(accepted.isAcceptable(under: rule))
        #expect(!accepted.isHeldForAudit(under: rule))
        #expect(accepted.reviewKind(under: rule) == nil)

        #expect(uncertain.reviewKind(under: rule) == .uncertain(.noCodeRead), "sampling applies to confident scans only")
        #expect(!uncertain.isHeldForAudit(under: rule))

        let judged = Fixtures.record(id: Fixtures.uuid(firstByte: 2), batch: batch, verdict: .correct, source: .autoAccepted, score: 1.2)
        #expect(judged.reviewKind(under: rule) == nil)
        #expect(!judged.isHeldForAudit(under: rule))

        // At 0.1 only bucket 0 is sampled.
        #expect(!held.isHeldForAudit(under: ConfidenceRule(randomAudits: 300)))
        #expect(Fixtures.record(id: Fixtures.uuid(firstByte: 10), batch: batch, score: 1.2).isHeldForAudit(under: ConfidenceRule(randomAudits: 300)))
    }

    @Test func reviewKindsNameTheirDecisionSource() throws {
        #expect(ReviewKind.uncertain(.noCodeRead).source == .human)
        #expect(ReviewKind.audit.source == .audit)
        #expect(ReviewKind.spotCheck.source == .spotCheck)

        // The sources reach scans.json as their names, where the server and
        // the Python readers tell machine labels from human ones.
        for (kind, name) in [(ReviewKind.audit, "audit"), (.spotCheck, "spotCheck")] {
            let decision = Fixtures.decision(.correct, cardID: Fixtures.vi.id, source: kind.source)
            let json = String(decoding: try JSONEncoder().encode(decision), as: UTF8.self)
            #expect(json.contains(#""source":"\#(name)""#), "got \(json)")
            #expect(try JSONDecoder().decode(Decision.self, from: Data(json.utf8)).source == kind.source)
        }
    }

    // MARK: - Candidate.codeOrigin on the wire

    @Test func candidateCodeOriginIsLiteralWhenAbsentAndNilWithoutAgreement() throws {
        let withAgreement = try JSONDecoder().decode(Candidate.self, from: Data(#"{"card":\#(cardJSON),"score":1.2,"descriptorScore":0.7,"orientation":"upright","codeAgreement":"exact"}"#.utf8))
        #expect(withAgreement.codeOrigin == .literal, "v1 and A1 records only ever matched the literal reading")
        let withoutAgreement = try JSONDecoder().decode(Candidate.self, from: Data(#"{"card":\#(cardJSON),"score":0.7,"descriptorScore":0.7,"orientation":"upright"}"#.utf8))
        #expect(withoutAgreement.codeOrigin == nil)
        #expect(withoutAgreement.codeAgreement == nil)

        let repaired = Candidate(card: Fixtures.vi, score: 1.2, descriptorScore: 0.7, orientation: .upright, codeAgreement: .exact, codeOrigin: .alternative)
        let encoded = try JSONEncoder().encode(repaired)
        #expect(String(decoding: encoded, as: UTF8.self).contains(#""codeOrigin":"alternative""#))
        #expect(try JSONDecoder().decode(Candidate.self, from: encoded) == repaired)
        let bare = try JSONEncoder().encode(withoutAgreement)
        #expect(!String(decoding: bare, as: UTF8.self).contains("codeOrigin"), "nothing to say without an agreement")
        let literal = try JSONEncoder().encode(withAgreement)
        #expect(!String(decoding: literal, as: UTF8.self).contains("codeOrigin"), "absent means literal, so v1 files re-encode unchanged")
        #expect(try JSONDecoder().decode(Candidate.self, from: literal) == withAgreement)
        #expect(Candidate(Fixtures.result(cards: [Fixtures.vi]).matches[0]).codeOrigin == .literal)
    }

    private var cardJSON: String {
        String(decoding: try! JSONEncoder().encode(Fixtures.vi), as: UTF8.self)
    }
}
