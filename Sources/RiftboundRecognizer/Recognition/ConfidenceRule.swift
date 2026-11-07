import Foundation

/// Whether a result may enter the ledger unreviewed (ADR-002, decision 9),
/// as the evaluation tooling measures it; the app's `ScanConfidence` applies
/// the same policy to its records.
public enum ConfidenceVerdict: Hashable, Sendable {
    public enum UncertaintyReason: String, Hashable, Sendable, Codable {
        case noMatch
        case noCode
        /// The top match owes its code agreement to a parser repair.
        case codeRepaired
        case codeDisagrees
        case belowMinimumScore
        /// A candidate of another art group has exemplar evidence the top lacks.
        case exemplarDisagrees
    }

    case confident
    case uncertain(UncertaintyReason)

    public var isConfident: Bool { self == .confident }
}

extension LearningPolicy.ConfidencePolicy {
    /// Judges a ranked result: the top match must agree exactly with a code
    /// that was read literally (when ``requireLiteralCode``), reach
    /// ``minimumFusedScore`` with its fused score plus code bonus, and no
    /// candidate in a *different* art group may hold exemplar similarity of at
    /// least ``exemplarDisagreementThreshold`` that exceeds the top's best
    /// descriptor evidence (its reference score or own exemplar similarity,
    /// whichever is higher) by ``exemplarDisagreementMargin``; the margin is
    /// compared after ``SimilarityContract`` rounding, so 0.90 against 0.80
    /// is exactly the 0.10 margin. Whether the code was read literally is the
    /// reading's own ``CodeReading/origin``.
    public func verdict(for matches: [Match], codeReading: CodeReading?) -> ConfidenceVerdict {
        guard let top = matches.first else { return .uncertain(.noMatch) }
        guard let codeReading else { return .uncertain(.noCode) }
        if requireLiteralCode, codeReading.origin == .alternative {
            return .uncertain(.codeRepaired)
        }
        guard top.codeAgreement == .exact else { return .uncertain(.codeDisagrees) }
        guard top.score >= minimumFusedScore else { return .uncertain(.belowMinimumScore) }
        let evidence = max(top.referenceScore, top.exemplarSimilarity ?? 0)
        let group = top.card.artGroup
        for match in matches.dropFirst() where match.card.artGroup != group {
            guard let similarity = match.exemplarSimilarity, similarity >= exemplarDisagreementThreshold else { continue }
            if SimilarityContract.round(similarity - evidence) >= exemplarDisagreementMargin {
                return .uncertain(.exemplarDisagrees)
            }
        }
        return .confident
    }
}
