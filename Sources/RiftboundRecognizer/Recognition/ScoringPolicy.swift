/// How the physical card sits in the rectified canvas relative to the index's canonical view.
public enum CardOrientation: String, Hashable, Sendable, Codable {
    case upright
    case upsideDown
}

/// Per-descriptor similarities between a query and a reference, each in 0...1.
public struct ScoreComponents: Hashable, Sendable {
    public let featurePrint: Double
    public let wholeDifferenceHash: Double
    public let wholePerceptualHash: Double
    public let artDifferenceHash: Double

    public init(featurePrint: Double, wholeDifferenceHash: Double, wholePerceptualHash: Double, artDifferenceHash: Double) {
        self.featurePrint = featurePrint
        self.wholeDifferenceHash = wholeDifferenceHash
        self.wholePerceptualHash = wholePerceptualHash
        self.artDifferenceHash = artDifferenceHash
    }

    public init(query: CardDescriptor, reference: CardDescriptor) {
        self.init(
            featurePrint: query.featurePrint.similarity(to: reference.featurePrint),
            wholeDifferenceHash: query.wholeDifferenceHash.similarity(to: reference.wholeDifferenceHash),
            wholePerceptualHash: query.wholePerceptualHash.similarity(to: reference.wholePerceptualHash),
            artDifferenceHash: query.artDifferenceHash.similarity(to: reference.artDifferenceHash)
        )
    }
}

/// How an OCR reading of the printed code relates to a candidate's code.
public enum CodeAgreement: String, Hashable, Sendable, Codable {
    /// Set, number and variant all match (the denominator is ignored; it is constant per set).
    case exact
    /// Same set and number, different suffix: `299` read where the candidate is `299*`.
    case variantDiffers
    /// Same set, different number: strong evidence against the candidate.
    case numberDiffers
    /// Same number, different set: the set letters are the likelier OCR error.
    case setDiffers
    case unrelated

    public init(reading: PrintedCode, candidate: PrintedCode) {
        let sameSet = reading.set == candidate.set
        let sameNumber = reading.number == candidate.number
        switch (sameSet, sameNumber) {
        case (true, true): self = reading.variant == candidate.variant ? .exact : .variantDiffers
        case (true, false): self = .numberDiffers
        case (false, true): self = .setDiffers
        case (false, false): self = .unrelated
        }
    }
}

/// Weights that fuse descriptor similarities and OCR evidence into one score.
///
/// Descriptor similarities are each in 0...1 and the weights sum to 1, so the
/// descriptor score is in 0...1. OCR evidence then shifts the score by a bonus
/// or penalty scaled by the OCR confidence; the defaults let a confident code
/// reading outrank a stronger descriptor match, which is what disambiguates
/// alternate printings that share an illustration.
public struct ScoringPolicy: Hashable, Sendable {
    public var featurePrintWeight = 0.5
    public var wholeDifferenceHashWeight = 0.2
    public var wholePerceptualHashWeight = 0.15
    public var artDifferenceHashWeight = 0.15

    public var codeExactBonus = 0.5
    public var codeVariantMismatchBonus = 0.2
    public var codeSetMismatchPenalty = 0.15
    public var codeMismatchPenalty = 0.4

    /// How many descriptor candidates are re-ranked with OCR evidence.
    public var rerankedCandidateCount = 12

    /// How many card-location hypotheses (detections and their frame-expanded
    /// variants) are rectified and scored on descriptors; the whole image is
    /// always tried as well.
    public var maximumLocationHypotheses = 6

    /// How many of those hypotheses, best descriptor score first, also get OCR
    /// before the best-scoring one is kept. OCR is the expensive step.
    public var ocrHypothesisCount = 2

    /// The whole-image hypothesis competes with located cards only when its best
    /// descriptor score reaches this value (a cropped card scores near 1.0).
    /// Below it, a photo's background routinely produces a coincidental 0.6–0.7
    /// against some unrelated printing, which must not outrank a located card.
    public var wholeImageMinimumScore = 0.8

    public init() {}

    public static let `default` = ScoringPolicy()

    public func descriptorScore(_ components: ScoreComponents) -> Double {
        featurePrintWeight * components.featurePrint
            + wholeDifferenceHashWeight * components.wholeDifferenceHash
            + wholePerceptualHashWeight * components.wholePerceptualHash
            + artDifferenceHashWeight * components.artDifferenceHash
    }

    public func codeAdjustment(for agreement: CodeAgreement, confidence: Double) -> Double {
        let weight = min(max(confidence, 0), 1)
        return switch agreement {
        case .exact: codeExactBonus * weight
        case .variantDiffers: codeVariantMismatchBonus * weight
        case .setDiffers: -codeSetMismatchPenalty * weight
        case .numberDiffers, .unrelated: -codeMismatchPenalty * weight
        }
    }
}
