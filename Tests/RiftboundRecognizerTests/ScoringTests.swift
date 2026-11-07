import Foundation
import Testing
import RiftboundRecognizer

@Suite("Scoring policy")
struct ScoringTests {
    @Test("classifies OCR agreement", arguments: [
        ("OGN-001/298", "OGN-001/298", CodeAgreement.exact),
        ("OGN-299/298", "OGN-299*/298", CodeAgreement.variantDiffers),
        ("OGN-007a/298", "OGN-007/298", CodeAgreement.variantDiffers),
        ("OGN-001/298", "OGN-002/298", CodeAgreement.numberDiffers),
        ("OGN-001/298", "RAD-001/167", CodeAgreement.setDiffers),
        ("OGN-001/298", "RAD-002/167", CodeAgreement.unrelated),
        ("RAD-R01", "RAD-R01", CodeAgreement.exact),
    ])
    func agreement(reading: String, candidate: String, expected: CodeAgreement) {
        #expect(CodeAgreement(reading: TestRig.code(reading), candidate: TestRig.code(candidate)) == expected)
    }

    @Test func descriptorWeightsSumToOne() {
        let policy = ScoringPolicy.default
        let perfect = ScoreComponents(featurePrint: 1, wholeDifferenceHash: 1, wholePerceptualHash: 1, artDifferenceHash: 1)
        #expect(abs(policy.descriptorScore(perfect) - 1) < 1e-9)
        #expect(policy.descriptorScore(ScoreComponents(featurePrint: 0, wholeDifferenceHash: 0, wholePerceptualHash: 0, artDifferenceHash: 0)) == 0)
    }

    @Test func codeAdjustmentsAreOrderedAndScaledByConfidence() {
        let policy = ScoringPolicy.default
        let exact = policy.codeAdjustment(for: .exact, confidence: 1)
        let variant = policy.codeAdjustment(for: .variantDiffers, confidence: 1)
        let set = policy.codeAdjustment(for: .setDiffers, confidence: 1)
        let number = policy.codeAdjustment(for: .numberDiffers, confidence: 1)
        #expect(exact > variant && variant > 0 && 0 > set && set > number)
        #expect(policy.codeAdjustment(for: .exact, confidence: 0.5) == exact / 2)
        #expect(policy.codeAdjustment(for: .exact, confidence: 7) == exact, "confidence is clamped")
        #expect(policy.codeAdjustment(for: .unrelated, confidence: 1) == number)
    }

    @Test func scoringPolicyRoundTripsThroughJSON() throws {
        var policy = ScoringPolicy()
        policy.featurePrintWeight = 0.6
        policy.codeExactBonus = 0.45
        policy.rerankedCandidateCount = 7
        policy.ocrHypothesisCount = 1
        policy.wholeImageMinimumScore = 0.75
        let encoded = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(ScoringPolicy.self, from: encoded)
        #expect(decoded == policy)
        #expect(decoded != .default)
        let json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["codeExactBonus"] as? Double == 0.45)
        #expect(json.count == 14, "every weight and threshold is a named key")
    }

    @Test func scoringPolicyFillsMissingKeysWithDefaults() throws {
        let partial = try JSONDecoder().decode(ScoringPolicy.self, from: Data(#"{"codeExactBonus": 0.7}"#.utf8))
        var expected = ScoringPolicy.default
        expected.codeExactBonus = 0.7
        #expect(partial == expected)
        #expect(try JSONDecoder().decode(ScoringPolicy.self, from: Data("{}".utf8)) == .default)
    }

    @Test func scoreComponentsRoundTripThroughJSON() throws {
        let components = ScoreComponents(featurePrint: 0.91, wholeDifferenceHash: 0.8, wholePerceptualHash: 0.75, artDifferenceHash: 0.5)
        let encoded = try JSONEncoder().encode(components)
        #expect(try JSONDecoder().decode(ScoreComponents.self, from: encoded) == components)
        let json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Double])
        #expect(json == ["featurePrint": 0.91, "wholeDifferenceHash": 0.8, "wholePerceptualHash": 0.75, "artDifferenceHash": 0.5])
    }

    @Test func matcherRanksByBestOrientation() {
        func descriptor(bits: UInt64, print: [Float]) -> CardDescriptor {
            CardDescriptor(wholeDifferenceHash: ImageHash(bits: bits), wholePerceptualHash: ImageHash(bits: bits), artDifferenceHash: ImageHash(bits: bits), featurePrint: FeaturePrint(elements: print))
        }
        let a = descriptor(bits: 0x0F0F_0F0F_0F0F_0F0F, print: [1, 0, 0])
        let b = descriptor(bits: 0xF0F0_F0F0_F0F0_F0F0, print: [0, 1, 0])
        let c = descriptor(bits: 0xFFFF_0000_FFFF_0000, print: [0, 0, 1])
        let index = CardIndex(canvas: .standard, builtAt: Date(timeIntervalSince1970: 0), entries: [
            CardIndex.Entry(card: TestRig.card("a", code: "OGN-001/298"), descriptor: a),
            CardIndex.Entry(card: TestRig.card("b", code: "OGN-002/298"), descriptor: b),
            CardIndex.Entry(card: TestRig.card("c", code: "OGN-003/298"), descriptor: c),
        ])
        let matcher = DescriptorMatcher(policy: .default)

        let upright = matcher.rank([OrientedDescriptor(descriptor: b, orientation: .upright)], in: index, limit: 2)
        #expect(upright.map(\.entry.id.rawValue) == ["b", "a"] || upright.map(\.entry.id.rawValue) == ["b", "c"])
        #expect(upright.first?.referenceScore == 1)
        #expect(upright.first?.fusedScore == 1 && upright.first?.exemplarSimilarity == nil, "no overlay: the fused score is the reference score")
        #expect(upright.count == 2)

        let flipped = matcher.rank([
            OrientedDescriptor(descriptor: a, orientation: .upright),
            OrientedDescriptor(descriptor: c, orientation: .upsideDown),
        ], in: index, limit: 3)
        #expect(flipped.first?.entry.id.rawValue == "a" || flipped.first?.entry.id.rawValue == "c")
        #expect(flipped.first { $0.entry.id.rawValue == "c" }?.orientation == .upsideDown)
        #expect(flipped.first { $0.entry.id.rawValue == "a" }?.orientation == .upright)
    }
}
