import Foundation
import Testing
import RiftboundRecognizer

@Suite("Confidence rule")
struct ConfidenceRuleTests {
    let policy = LearningPolicy.ConfidencePolicy()
    let components = ScoreComponents(featurePrint: 0.6, wholeDifferenceHash: 0.6, wholePerceptualHash: 0.6, artDifferenceHash: 0.6)
    let reading = CodeReading(code: TestRig.code("SFD-024/221"), confidence: 1, orientation: .upright, layout: .portrait, text: "SFD • 024/221", source: .edgeBand)

    func match(_ id: String, code: String, score: Double, reference: Double, exemplar: Double? = nil, agreement: CodeAgreement? = .exact) -> Match {
        Match(card: TestRig.card(id, code: code), score: score, descriptorScore: max(reference, 0.95 * (exemplar ?? 0)), referenceScore: reference, exemplarSimilarity: exemplar, components: components, orientation: .upright, codeAgreement: agreement)
    }

    @Test func theConfirmedTwoWrongConfidentScansAreVetoedByAnExemplarOfAnotherGroup() {
        // The 014/024 case: the OCR read 024, the descriptor agreed weakly, and an
        // exemplar of the true card (another art group) scored 0.911.
        let top = match("sfd-024-221", code: "SFD-024/221", score: 1.075, reference: 0.575)
        let truth = match("sfd-014-221", code: "SFD-014/221", score: 0.465, reference: 0.591, exemplar: 0.911, agreement: .numberDiffers)
        #expect(policy.verdict(for: [top, truth], codeReading: reading, codeOrigin: .literal) == .uncertain(.exemplarDisagrees))
        #expect(policy.verdict(for: [top], codeReading: reading, codeOrigin: .literal) == .confident, "with no contradiction a 0.575 descriptor is still confident: no descriptor floor")
    }

    @Test func siblingsOfTheSameArtNeverVeto() {
        let top = match("sfd-014-221", code: "SFD-014/221", score: 1.09, reference: 0.59)
        let sibling = match("sfd-014a-221", code: "SFD-014a/221", score: 0.78, reference: 0.58, exemplar: 0.93, agreement: .variantDiffers)
        #expect(policy.verdict(for: [top, sibling], codeReading: reading, codeOrigin: .literal) == .confident)
    }

    @Test func requiresALiteralExactCodeAndTheMinimumScore() {
        let top = match("sfd-024-221", code: "SFD-024/221", score: 1.075, reference: 0.575)
        #expect(policy.verdict(for: [top], codeReading: reading, codeOrigin: .alternative) == .uncertain(.codeRepaired))
        #expect(policy.verdict(for: [top], codeReading: nil, codeOrigin: .literal) == .uncertain(.noCode))
        #expect(policy.verdict(for: [], codeReading: reading, codeOrigin: .literal) == .uncertain(.noMatch))
        let low = match("sfd-024-221", code: "SFD-024/221", score: 0.99, reference: 0.575)
        #expect(policy.verdict(for: [low], codeReading: reading, codeOrigin: .literal) == .uncertain(.belowMinimumScore))
        let disagreeing = match("sfd-024-221", code: "SFD-024/221", score: 1.2, reference: 0.9, agreement: .variantDiffers)
        #expect(policy.verdict(for: [disagreeing], codeReading: reading, codeOrigin: .literal) == .uncertain(.codeDisagrees))
        var lenient = policy
        lenient.requireLiteralCode = false
        #expect(lenient.verdict(for: [top], codeReading: reading, codeOrigin: .alternative) == .confident)
    }

    @Test func theVetoNeedsBothTheThresholdAndTheMargin() {
        let top = match("sfd-024-221", code: "SFD-024/221", score: 1.3, reference: 0.80)
        let nearMiss = match("sfd-014-221", code: "SFD-014/221", score: 0.4, reference: 0.5, exemplar: 0.89, agreement: .numberDiffers)
        #expect(policy.verdict(for: [top, nearMiss], codeReading: reading, codeOrigin: .literal) == .confident, "0.89 - 0.80 is under the 0.10 margin")
        let weak = match("sfd-014-221", code: "SFD-014/221", score: 0.4, reference: 0.5, exemplar: 0.87, agreement: .numberDiffers)
        #expect(policy.verdict(for: [top, weak], codeReading: reading, codeOrigin: .literal) == .confident, "0.87 is under the 0.88 threshold")
        let strong = match("sfd-014-221", code: "SFD-014/221", score: 0.4, reference: 0.5, exemplar: 0.90, agreement: .numberDiffers)
        #expect(policy.verdict(for: [top, strong], codeReading: reading, codeOrigin: .literal) == .uncertain(.exemplarDisagrees))
        let topWithExemplar = match("sfd-024-221", code: "SFD-024/221", score: 1.3, reference: 0.60, exemplar: 0.85)
        #expect(policy.verdict(for: [topWithExemplar, strong], codeReading: reading, codeOrigin: .literal) == .confident, "the top's own exemplar evidence counts")
    }
}
