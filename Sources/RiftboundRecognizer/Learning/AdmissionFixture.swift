import Foundation

/// One gate call as data: what `POST /api/learning/admit/dry-run` takes and
/// what each case of `Tests/Fixtures/admission-cases.json` holds beside its
/// expected outcome. `riftscan gate-diff` posts these and compares the answers
/// with the Swift gate's.
public struct AdmissionRequest: Hashable, Sendable, Codable {
    public let gateVersion: Int
    public let calibrationHash: FeaturePrint.Digest
    public let policy: LearningPolicy.AdmissionPolicy
    public let candidate: AdmissionInput
    public let witnesses: [AdmissionInput]
    public let existing: [ExistingExemplar]

    public init(calibrationHash: FeaturePrint.Digest, policy: LearningPolicy.AdmissionPolicy, candidate: AdmissionInput, witnesses: [AdmissionInput] = [], existing: [ExistingExemplar] = []) {
        self.gateVersion = ExemplarAdmission.gateVersion
        self.calibrationHash = calibrationHash
        self.policy = policy
        self.candidate = candidate
        self.witnesses = witnesses
        self.existing = existing
    }

    /// The Swift gate's answer.
    public func decide() -> AdmissionOutcome {
        ExemplarAdmission(policy: policy, calibrationHash: calibrationHash).decide(candidate, witnesses: witnesses, existing: existing)
    }
}

/// The shared gate fixture: the policy and calibration hash every case runs
/// under, the cases (inputs plus the outcome both implementations must
/// produce) and the similarity vectors that pin the ``SimilarityContract``
/// (pairs of prints with the rounded similarity they must yield, including
/// pairs at each threshold ± 0.00005).
public struct AdmissionFixture: Sendable, Codable {
    public struct Case: Hashable, Sendable, Codable {
        public let name: String
        public let candidate: AdmissionInput
        public let witnesses: [AdmissionInput]
        public let existing: [ExistingExemplar]
        public let expected: AdmissionOutcome

        public init(name: String, candidate: AdmissionInput, witnesses: [AdmissionInput] = [], existing: [ExistingExemplar] = [], expected: AdmissionOutcome) {
            self.name = name
            self.candidate = candidate
            self.witnesses = witnesses
            self.existing = existing
            self.expected = expected
        }

        private enum CodingKeys: String, CodingKey {
            case name, candidate, witnesses, existing, expected
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                name: try container.decode(String.self, forKey: .name),
                candidate: try container.decode(AdmissionInput.self, forKey: .candidate),
                witnesses: try container.decodeIfPresent([AdmissionInput].self, forKey: .witnesses) ?? [],
                existing: try container.decodeIfPresent([ExistingExemplar].self, forKey: .existing) ?? [],
                expected: try container.decode(AdmissionOutcome.self, forKey: .expected)
            )
        }
    }

    public struct SimilarityVector: Hashable, Sendable, Codable {
        public let name: String
        public let a: FeaturePrint
        public let b: FeaturePrint
        /// ``SimilarityContract/similarity(_:_:)`` of `a` and `b`.
        public let expected: Double
    }

    public struct Contract: Hashable, Sendable, Codable {
        public let decimals: Int
        public let rounding: String
    }

    public let gateVersion: Int
    public let contract: Contract
    public let calibrationHash: FeaturePrint.Digest
    public let policy: LearningPolicy.AdmissionPolicy
    public let cases: [Case]
    public let similarityVectors: [SimilarityVector]

    public static func read(from url: URL) throws -> AdmissionFixture {
        try JSONDecoder().decode(AdmissionFixture.self, from: try Data(contentsOf: url))
    }

    /// The request a case stands for.
    public func request(for fixtureCase: Case) -> AdmissionRequest {
        AdmissionRequest(calibrationHash: calibrationHash, policy: policy, candidate: fixtureCase.candidate, witnesses: fixtureCase.witnesses, existing: fixtureCase.existing)
    }
}
