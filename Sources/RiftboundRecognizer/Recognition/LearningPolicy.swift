import Foundation

/// Every threshold the learning loop uses, as data (ADR-002, principle 4):
/// the server serves it from `GET /api/learning/policy`, `riftscan push-policy`
/// uploads one, and the app applies whatever it downloads. Any key missing on
/// decode takes its default, nested sections included, so a policy written for
/// an older build still loads and a hand-edited file need only name what it
/// changes. `docs/learning-policy.md` documents the file.
public struct LearningPolicy: Hashable, Sendable, Codable {
    /// Monotonic; stamped on every result as `EngineStamp.policyVersion`.
    public var version = 1
    public var scoring = ScoringPolicy.default
    public var confidence = ConfidencePolicy()
    public var admission = AdmissionPolicy()
    /// The least cosine similarity between a device's calibration print and an
    /// artefact's for the two to count as the same embedding space (decision 14).
    /// Provisional until `riftscan check-revision` has been run on both
    /// platforms; identical models print identically (1.0).
    public var calibrationMinimum = 0.95

    public init() {}

    public static let `default` = LearningPolicy()

    /// When a scan is confident enough to enter the ledger unreviewed (decision 9).
    public struct ConfidencePolicy: Hashable, Sendable, Codable {
        /// The fused score (descriptor plus code evidence) a top match needs.
        public var minimumFusedScore = 1.0
        /// Whether the code must have been read literally, not via a parser alternative.
        public var requireLiteralCode = true
        /// A candidate in a different art group with at least this exemplar
        /// similarity can veto the confident tier...
        public var exemplarDisagreementThreshold = 0.88
        /// ...when it exceeds the top match's best descriptor evidence by this much.
        public var exemplarDisagreementMargin = 0.10
        /// The share of confident scans sampled for a human audit.
        public var auditRate = 0.3
        /// The audit rate once ``auditRateSwitchCount`` random audits exist.
        public var auditRateAfter = 0.1
        public var auditRateSwitchCount = 300

        public init() {}

        /// The audit rate in force after `count` random audits have been recorded.
        public func auditRate(afterRandomAudits count: Int) -> Double {
            count >= auditRateSwitchCount ? auditRateAfter : auditRate
        }

        private enum CodingKeys: String, CodingKey {
            case minimumFusedScore, requireLiteralCode, exemplarDisagreementThreshold, exemplarDisagreementMargin
            case auditRate, auditRateAfter, auditRateSwitchCount
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = ConfidencePolicy()
            minimumFusedScore = try container.decodeIfPresent(Double.self, forKey: .minimumFusedScore) ?? defaults.minimumFusedScore
            requireLiteralCode = try container.decodeIfPresent(Bool.self, forKey: .requireLiteralCode) ?? defaults.requireLiteralCode
            exemplarDisagreementThreshold = try container.decodeIfPresent(Double.self, forKey: .exemplarDisagreementThreshold) ?? defaults.exemplarDisagreementThreshold
            exemplarDisagreementMargin = try container.decodeIfPresent(Double.self, forKey: .exemplarDisagreementMargin) ?? defaults.exemplarDisagreementMargin
            auditRate = try container.decodeIfPresent(Double.self, forKey: .auditRate) ?? defaults.auditRate
            auditRateAfter = try container.decodeIfPresent(Double.self, forKey: .auditRateAfter) ?? defaults.auditRateAfter
            auditRateSwitchCount = try container.decodeIfPresent(Int.self, forKey: .auditRateSwitchCount) ?? defaults.auditRateSwitchCount
        }
    }

    /// The exemplar admission gate's thresholds (ADR-002, section 7, rules 5-8).
    public struct AdmissionPolicy: Hashable, Sendable, Codable {
        /// Rule 5, tier `code`: the confirmed card's reference similarity floor.
        public var referenceSimilarityFloor = 0.62
        /// Rule 5: how far the confirmed card's reference similarity must exceed
        /// every code alternative naming another art group.
        public var alternativeMargin = 0.05
        /// Rule 5, tier `artCorroborated`: the mutual similarity two witnesses need.
        public var witnessMutualSimilarity = 0.85
        /// Rule 5, tier `artCorroborated`: each witness's reference similarity floor.
        public var witnessReferenceFloor = 0.60
        /// Rule 6: an existing exemplar of another group at least this similar blocks admission.
        public var impostorSimilarity = 0.90
        /// Rule 7: a candidate at least this similar to an existing exemplar is a duplicate.
        public var duplicateSimilarity = 0.985
        /// Rule 8: exemplars kept per art group.
        public var maximumPerGroup = 6

        public init() {}

        private enum CodingKeys: String, CodingKey {
            case referenceSimilarityFloor, alternativeMargin, witnessMutualSimilarity, witnessReferenceFloor
            case impostorSimilarity, duplicateSimilarity, maximumPerGroup
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = AdmissionPolicy()
            referenceSimilarityFloor = try container.decodeIfPresent(Double.self, forKey: .referenceSimilarityFloor) ?? defaults.referenceSimilarityFloor
            alternativeMargin = try container.decodeIfPresent(Double.self, forKey: .alternativeMargin) ?? defaults.alternativeMargin
            witnessMutualSimilarity = try container.decodeIfPresent(Double.self, forKey: .witnessMutualSimilarity) ?? defaults.witnessMutualSimilarity
            witnessReferenceFloor = try container.decodeIfPresent(Double.self, forKey: .witnessReferenceFloor) ?? defaults.witnessReferenceFloor
            impostorSimilarity = try container.decodeIfPresent(Double.self, forKey: .impostorSimilarity) ?? defaults.impostorSimilarity
            duplicateSimilarity = try container.decodeIfPresent(Double.self, forKey: .duplicateSimilarity) ?? defaults.duplicateSimilarity
            maximumPerGroup = try container.decodeIfPresent(Int.self, forKey: .maximumPerGroup) ?? defaults.maximumPerGroup
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, scoring, confidence, admission, calibrationMinimum
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LearningPolicy()
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? defaults.version
        scoring = try container.decodeIfPresent(ScoringPolicy.self, forKey: .scoring) ?? defaults.scoring
        confidence = try container.decodeIfPresent(ConfidencePolicy.self, forKey: .confidence) ?? defaults.confidence
        admission = try container.decodeIfPresent(AdmissionPolicy.self, forKey: .admission) ?? defaults.admission
        calibrationMinimum = try container.decodeIfPresent(Double.self, forKey: .calibrationMinimum) ?? defaults.calibrationMinimum
    }

    public static func read(from url: URL) throws -> LearningPolicy {
        try JSONDecoder().decode(LearningPolicy.self, from: try Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
