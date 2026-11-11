import Foundation
import RiftboundRecognizer

/// The confident tier's thresholds, as data (ADR-002, decision 9). Built from
/// the installed `LearningPolicy.confidence` and what the server reports about
/// audits so far; every number here is a policy value, none is hard-coded in
/// the rule that applies it.
nonisolated struct ConfidenceRule: Hashable, Sendable {
    /// The fused score plus code adjustment a top match needs.
    let minimumScore: Double
    /// Whether the code must have been read literally, not via a parser alternative.
    let requiresLiteralCode: Bool
    /// A candidate in a different art group with at least this exemplar
    /// similarity can veto the tier...
    let exemplarDisagreementThreshold: Double
    /// ...when it exceeds the top match's best descriptor evidence by this much.
    let exemplarDisagreementMargin: Double
    /// The share of confident scans held back for a human audit, in tenths.
    let auditRate: Double

    /// - Parameters:
    ///   - policy: the installed policy's confidence section.
    ///   - randomAudits: how many random audits the server has recorded; the
    ///     rate drops once `policy.auditRateSwitchCount` exist.
    init(policy: LearningPolicy.ConfidencePolicy = LearningPolicy.ConfidencePolicy(), randomAudits: Int = 0) {
        minimumScore = policy.minimumFusedScore
        requiresLiteralCode = policy.requireLiteralCode
        exemplarDisagreementThreshold = policy.exemplarDisagreementThreshold
        exemplarDisagreementMargin = policy.exemplarDisagreementMargin
        auditRate = policy.auditRate(afterRandomAudits: randomAudits)
    }

    /// The built-in policy before anything has been downloaded.
    static let `default` = ConfidenceRule()

    /// Audit sampling resolution: a rate of 0.3 holds three of every ten buckets.
    static let auditBuckets = 10

    /// Whether a scan is one the policy holds back for audit. Deterministic in
    /// the scan id (its UUID's first byte modulo ten against `rate` in tenths),
    /// so the same scan is sampled on every screen and every device.
    static func isAuditSample(_ id: ScanRecord.ID, rate: Double) -> Bool {
        let bucket = Int(id.rawValue.uuid.0) % auditBuckets
        let held = Int((rate * Double(auditBuckets)).rounded())
        return bucket < held
    }
}

/// Whether a scan can be trusted without a human look. The bar is deliberately
/// high: a code was read literally, it names the top candidate exactly, the
/// fused score clears the policy's minimum, and no card of another art that
/// has been learned from real photos looks clearly more like this one.
nonisolated enum ScanConfidence: Hashable, Sendable {
    case confident
    case uncertain(UncertaintyReason)

    init(_ record: ScanRecord, rule: ConfidenceRule = .default) {
        guard let top = record.topCandidate else {
            self = .uncertain(record.codeReading == nil ? .noCodeRead : .codeDisagrees)
            return
        }
        guard record.codeReading != nil else {
            self = .uncertain(.noCodeRead)
            return
        }
        switch top.codeAgreement {
        case .exact:
            if rule.requiresLiteralCode, top.codeOrigin == .alternative {
                self = .uncertain(.codeRepaired)
            } else if top.score < rule.minimumScore {
                self = .uncertain(.weakArtMatch)
            } else if Self.exemplarDisagrees(with: top, in: record, rule: rule) {
                self = .uncertain(.exemplarDisagrees)
            } else {
                self = .confident
            }
        case .variantDiffers:
            self = .uncertain(.variantOnly)
        case .numberDiffers, .setDiffers, .unrelated, nil:
            self = .uncertain(.codeDisagrees)
        }
    }

    /// The exemplar-contradiction veto: a shortlisted card of a *different*
    /// art group whose learned exemplar is at least `threshold` similar to the
    /// photo and beats the top's own best evidence by `margin`. Same-art twins
    /// (`sfd-014` and `sfd-014a`) share a group and never veto each other.
    private static func exemplarDisagrees(with top: Candidate, in record: ScanRecord, rule: ConfidenceRule) -> Bool {
        let shortlist = record.analysis?.shortlist ?? []
        let topGroup = top.card.artGroup
        let topEvidence = shortlist.first { $0.cardID == top.card.id }
            .map { max($0.referenceScore, $0.exemplarSimilarity ?? 0) } ?? top.descriptorScore
        return shortlist.contains { entry in
            guard ArtGroup(entry.cardID) != topGroup, let similarity = entry.exemplarSimilarity else { return false }
            return similarity >= rule.exemplarDisagreementThreshold && similarity - topEvidence >= rule.exemplarDisagreementMargin
        }
    }

    var isConfident: Bool {
        if case .confident = self { return true }
        return false
    }

    var reason: UncertaintyReason? {
        if case .uncertain(let reason) = self { return reason }
        return nil
    }
}

nonisolated enum UncertaintyReason: Hashable, Sendable, CaseIterable {
    case noCodeRead
    case codeDisagrees
    case weakArtMatch
    case variantOnly
    /// The top candidate matched a code the parser repaired, not what was read.
    case codeRepaired
    /// A learned exemplar of another card's art looks more like the photo.
    case exemplarDisagrees

    /// A short label for badges and grids.
    var label: String {
        switch self {
        case .noCodeRead: String(localized: "No code read")
        case .codeDisagrees: String(localized: "Code disagrees")
        case .weakArtMatch: String(localized: "Weak art match")
        case .variantOnly: String(localized: "Variant unclear")
        case .codeRepaired: String(localized: "Code repaired")
        case .exemplarDisagrees: String(localized: "Looks like another card")
        }
    }

    /// One or two sentences for the review screen.
    func message(isArtWeak: Bool) -> String {
        switch self {
        case .noCodeRead:
            isArtWeak
                ? String(localized: "No code was read, and the art match is weak. Compare the two cards.")
                : String(localized: "No code was read, but the art matches well. Check the code in the corner.")
        case .codeDisagrees:
            String(localized: "The code that was read doesn't name this card. Check the code in the corner.")
        case .weakArtMatch:
            String(localized: "The code matches, but the art match is weak. Compare the two cards.")
        case .variantOnly:
            String(localized: "The code matches except for the variant. Check for a signature or alternate-art mark.")
        case .codeRepaired:
            String(localized: "The code was read as a near miss and repaired to name this card. Check the digits in the corner.")
        case .exemplarDisagrees:
            String(localized: "The code names this card, but the photo looks more like a card you've confirmed before. Compare the two cards.")
        }
    }
}

/// Why a pending scan is in the review queue; decides which `DecisionSource`
/// the verdict is written with.
nonisolated enum ReviewKind: Hashable, Sendable {
    /// The recogniser was not sure; the verdict is a `human` label.
    case uncertain(UncertaintyReason)
    /// Confident, but held back by the policy's random sample; an `audit` label.
    case audit
    /// Already accepted, re-checked on request; a `spotCheck` label.
    case spotCheck
    /// The card is known but the printing is not settled (`ScanTier.pickPrinting`); a `human` label.
    case pickPrinting
    /// Looks like the card fed just before it (`ScanTier.possibleDuplicate`); a `human` label.
    case possibleDuplicate
    /// Nothing in the index resembled the photo (`ScanTier.unknown`); a `human` label.
    case unknown
    /// Opened from the batch's screen without needing a look: a confident
    /// scan, or one with a verdict already. A `human` label, which
    /// supersedes any verdict it had.
    case opened

    var source: DecisionSource {
        switch self {
        case .uncertain, .pickPrinting, .possibleDuplicate, .unknown, .opened: .human
        case .audit: .audit
        case .spotCheck: .spotCheck
        }
    }
}

nonisolated extension ScanRecord {
    func confidence(under rule: ConfidenceRule) -> ScanConfidence {
        ScanConfidence(self, rule: rule)
    }

    /// Confidence under the built-in rule; screens that know the installed
    /// rule pass it to `confidence(under:)` instead.
    var confidence: ScanConfidence { confidence(under: .default) }

    /// Still pending and not trusted on its own.
    func needsReview(under rule: ConfidenceRule) -> Bool {
        verdict == .pending && !confidence(under: rule).isConfident
    }

    var needsReview: Bool { needsReview(under: .default) }

    /// Still pending but trusted; can be accepted without a look unless the
    /// audit sample holds it (`isHeldForAudit(under:)`).
    func isAutoConfirmable(under rule: ConfidenceRule) -> Bool {
        verdict == .pending && confidence(under: rule).isConfident
    }

    var isAutoConfirmable: Bool { isAutoConfirmable(under: .default) }

    /// Whether the policy's random sample picks this scan for a human audit
    /// at `rate`; meaningful only for confident scans.
    func isAuditSample(rate: Double) -> Bool {
        ConfidenceRule.isAuditSample(id, rate: rate)
    }

    /// Confident and pending, but sampled for audit: bulk acceptance skips it
    /// and the review queue shows it with an Audit badge.
    func isHeldForAudit(under rule: ConfidenceRule) -> Bool {
        isAutoConfirmable(under: rule) && isAuditSample(rate: rule.auditRate)
    }

    /// Confident, pending and not sampled: what "Accept the confident" accepts.
    func isAcceptable(under rule: ConfidenceRule) -> Bool {
        isAutoConfirmable(under: rule) && !isAuditSample(rate: rule.auditRate)
    }

    /// Why this pending scan needs a person, or `nil` when it does not.
    func reviewKind(under rule: ConfidenceRule) -> ReviewKind? {
        guard verdict == .pending else { return nil }
        if let reason = confidence(under: rule).reason { return .uncertain(reason) }
        return isAuditSample(rate: rule.auditRate) ? .audit : nil
    }

    /// The art match is weak even where a code exists; informs the reason text.
    var hasWeakArtMatch: Bool {
        (topCandidate?.descriptorScore ?? 0) < 0.5
    }
}
