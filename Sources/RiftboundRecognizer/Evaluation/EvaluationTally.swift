import Foundation

/// One labelled photo in an evaluation set.
///
/// Synthetic sets carry `parameters`; sets imported from the phone's scan
/// batches (`riftscan import-scans`) carry the scan's provenance and a
/// `samplingWeight`: audit cases stand for the confident scans the policy did
/// not hold back, so each counts `1 / auditRate` in the weighted tallies
/// (ADR-002, section 7). Every field added after the synthetic format is
/// optional on decode.
public struct EvaluationCase: Hashable, Sendable, Codable {
    /// Path relative to the manifest's folder.
    public let file: String
    public let expected: Card.ID
    /// Grouping key for the report (a synthetic severity, `samples`, or a batch label).
    public let group: String
    public let parameters: SyntheticPhotoParameters?
    /// How many scans of the population this case stands for; 1 unless the
    /// case was sampled (an audit of the confident tier).
    public let samplingWeight: Double
    public let scanID: UUID?
    public let batchID: UUID?
    public let decisionSource: AdmissionInput.DecisionSource?
    /// The record's capture quality as the app decodes it (`legacy` when the
    /// record states none).
    public let captureQuality: AdmissionInput.CaptureQuality?
    /// The quality the record's crop and the photo's size would derive under
    /// the app's rule; what `build-overlay --derive-capture-quality` assumes.
    public let derivedCaptureQuality: AdmissionInput.CaptureQuality?
    /// The photo's pixel size as the importer loaded it.
    public let imageSize: PixelSize?

    public init(
        file: String,
        expected: Card.ID,
        group: String,
        parameters: SyntheticPhotoParameters? = nil,
        samplingWeight: Double = 1,
        scanID: UUID? = nil,
        batchID: UUID? = nil,
        decisionSource: AdmissionInput.DecisionSource? = nil,
        captureQuality: AdmissionInput.CaptureQuality? = nil,
        derivedCaptureQuality: AdmissionInput.CaptureQuality? = nil,
        imageSize: PixelSize? = nil
    ) {
        self.file = file
        self.expected = expected
        self.group = group
        self.parameters = parameters
        self.samplingWeight = samplingWeight
        self.scanID = scanID
        self.batchID = batchID
        self.decisionSource = decisionSource
        self.captureQuality = captureQuality
        self.derivedCaptureQuality = derivedCaptureQuality
        self.imageSize = imageSize
    }

    private enum CodingKeys: String, CodingKey {
        case file, expected, group, parameters, samplingWeight, scanID, batchID, decisionSource, captureQuality, derivedCaptureQuality, imageSize
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            file: try container.decode(String.self, forKey: .file),
            expected: try container.decode(Card.ID.self, forKey: .expected),
            group: try container.decode(String.self, forKey: .group),
            parameters: try container.decodeIfPresent(SyntheticPhotoParameters.self, forKey: .parameters),
            samplingWeight: try container.decodeIfPresent(Double.self, forKey: .samplingWeight) ?? 1,
            scanID: try container.decodeIfPresent(UUID.self, forKey: .scanID),
            batchID: try container.decodeIfPresent(UUID.self, forKey: .batchID),
            decisionSource: try container.decodeIfPresent(AdmissionInput.DecisionSource.self, forKey: .decisionSource),
            captureQuality: try container.decodeIfPresent(AdmissionInput.CaptureQuality.self, forKey: .captureQuality),
            derivedCaptureQuality: try container.decodeIfPresent(AdmissionInput.CaptureQuality.self, forKey: .derivedCaptureQuality),
            imageSize: try container.decodeIfPresent(PixelSize.self, forKey: .imageSize)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(file, forKey: .file)
        try container.encode(expected, forKey: .expected)
        try container.encode(group, forKey: .group)
        try container.encodeIfPresent(parameters, forKey: .parameters)
        if samplingWeight != 1 {
            try container.encode(samplingWeight, forKey: .samplingWeight)
        }
        try container.encodeIfPresent(scanID, forKey: .scanID)
        try container.encodeIfPresent(batchID, forKey: .batchID)
        try container.encodeIfPresent(decisionSource, forKey: .decisionSource)
        try container.encodeIfPresent(captureQuality, forKey: .captureQuality)
        try container.encodeIfPresent(derivedCaptureQuality, forKey: .derivedCaptureQuality)
        try container.encodeIfPresent(imageSize, forKey: .imageSize)
    }
}

/// `manifest.json` next to a synthetic test set, or written by `import-scans`
/// beside the pulled scan batches.
public struct EvaluationManifest: Sendable, Codable {
    public static let fileName = "manifest.json"

    public let generatedAt: Date
    /// The synthetic generator's seed; `nil` for a set imported from real scans.
    public let seed: UInt64?
    public let cases: [EvaluationCase]
    /// The platform the manifest was produced on (`macOS` for `import-scans`),
    /// so a report can say which Vision model loaded the photos.
    public let platform: String?
    /// The audit rate the sampling weights were computed with, when any were.
    public let auditRate: Double?

    public init(generatedAt: Date, seed: UInt64?, cases: [EvaluationCase], platform: String? = nil, auditRate: Double? = nil) {
        self.generatedAt = generatedAt
        self.seed = seed
        self.cases = cases
        self.platform = platform
        self.auditRate = auditRate
    }

    /// The batches the cases came from, in first-seen order.
    public var batchIDs: [UUID] {
        var seen: Set<UUID> = []
        return cases.compactMap(\.batchID).filter { seen.insert($0).inserted }
    }

    public static func read(from folder: URL) throws -> EvaluationManifest {
        try read(file: folder.appendingPathComponent(fileName))
    }

    /// Reads a manifest by its own path (any file name).
    public static func read(file url: URL) throws -> EvaluationManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(EvaluationManifest.self, from: try Data(contentsOf: url))
    }

    public func write(to folder: URL) throws {
        try write(file: folder.appendingPathComponent(Self.fileName))
    }

    public func write(file url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Accumulates top-1 / top-3 accuracy per group, raw (one case, one count) and
/// weighted by each case's `samplingWeight`, plus the confident tier's
/// precision and coverage and how often an exemplar lifted the winner. Pure,
/// so it is unit-tested without running the recogniser.
public struct EvaluationTally: Hashable, Sendable {
    public struct GroupStatistics: Hashable, Sendable {
        public private(set) var total = 0
        public private(set) var top1 = 0
        public private(set) var top3 = 0
        public private(set) var totalDuration: Duration = .zero
        /// The sum of sampling weights (the population the cases stand for).
        public private(set) var weight = 0.0
        public private(set) var weightedTop1 = 0.0
        public private(set) var weightedTop3 = 0.0
        /// Cases the confidence rule would have auto-accepted.
        public private(set) var confident = 0
        public private(set) var confidentCorrect = 0
        public private(set) var confidentWeight = 0.0
        public private(set) var confidentCorrectWeight = 0.0
        /// Cases whose winning match carried exemplar evidence.
        public private(set) var exemplarHits = 0

        public var top1Rate: Double { total == 0 ? 0 : Double(top1) / Double(total) }
        public var top3Rate: Double { total == 0 ? 0 : Double(top3) / Double(total) }
        public var weightedTop1Rate: Double { weight == 0 ? 0 : weightedTop1 / weight }
        public var weightedTop3Rate: Double { weight == 0 ? 0 : weightedTop3 / weight }
        public var meanDuration: Duration { total == 0 ? .zero : totalDuration / total }
        /// Of the cases the rule accepted, the share that were right.
        public var confidentPrecision: Double { confident == 0 ? 0 : Double(confidentCorrect) / Double(confident) }
        public var weightedConfidentPrecision: Double { confidentWeight == 0 ? 0 : confidentCorrectWeight / confidentWeight }
        /// The share of cases the rule accepted.
        public var confidentCoverage: Double { total == 0 ? 0 : Double(confident) / Double(total) }
        public var weightedConfidentCoverage: Double { weight == 0 ? 0 : confidentWeight / weight }
        public var exemplarHitRate: Double { total == 0 ? 0 : Double(exemplarHits) / Double(total) }
        /// The 95 % Wilson lower bound of the raw confident precision (decision 9).
        public var confidentPrecisionLowerBound: Double { Statistics.wilsonLowerBound(successes: confidentCorrect, trials: confident) }

        fileprivate mutating func record(rank: Int?, duration: Duration, weight: Double, confident isConfident: Bool, exemplarHit: Bool) {
            total += 1
            self.weight += weight
            if let rank {
                if rank == 0 {
                    top1 += 1
                    weightedTop1 += weight
                }
                if rank < 3 {
                    top3 += 1
                    weightedTop3 += weight
                }
            }
            if isConfident {
                confident += 1
                confidentWeight += weight
                if rank == 0 {
                    confidentCorrect += 1
                    confidentCorrectWeight += weight
                }
            }
            if exemplarHit {
                exemplarHits += 1
            }
            totalDuration += duration
        }
    }

    public struct Failure: Hashable, Sendable {
        public let file: String
        public let group: String
        public let expected: Card.ID
        public let ranked: [Card.ID]
        public let rank: Int?
        /// The rule accepted a wrong answer: the failure that costs precision.
        public let confident: Bool
    }

    public private(set) var groups: [String: GroupStatistics] = [:]
    public private(set) var overall = GroupStatistics()
    public private(set) var failures: [Failure] = []

    public init() {}

    /// Records one case. `ranked` lists the recogniser's candidates, best first.
    public mutating func record(_ evaluationCase: EvaluationCase, ranked: [Card.ID], duration: Duration) {
        record(evaluationCase, ranked: ranked, duration: duration, confident: false, exemplarHit: false)
    }

    /// Records one case with the confidence rule's verdict and whether an
    /// exemplar contributed to the winner. The weight is the case's own.
    public mutating func record(_ evaluationCase: EvaluationCase, ranked: [Card.ID], duration: Duration, confident: Bool, exemplarHit: Bool) {
        let rank = ranked.firstIndex(of: evaluationCase.expected)
        let weight = evaluationCase.samplingWeight
        groups[evaluationCase.group, default: GroupStatistics()].record(rank: rank, duration: duration, weight: weight, confident: confident, exemplarHit: exemplarHit)
        overall.record(rank: rank, duration: duration, weight: weight, confident: confident, exemplarHit: exemplarHit)
        if rank != 0 {
            failures.append(Failure(file: evaluationCase.file, group: evaluationCase.group, expected: evaluationCase.expected, ranked: Array(ranked.prefix(3)), rank: rank, confident: confident))
        }
    }

    public var groupNames: [String] { groups.keys.sorted() }
}

public enum Statistics {
    /// The lower end of the Wilson score interval for a binomial proportion:
    /// what "precision >= 98.1 % (95 %)" means in `/api/learning/stats` and
    /// the Settings card. 0 when there are no trials. `z` is 1.96 for 95 %.
    public static func wilsonLowerBound(successes: Int, trials: Int, z: Double = 1.959964) -> Double {
        guard trials > 0 else { return 0 }
        let n = Double(trials)
        let p = Double(successes) / n
        let z2 = z * z
        let centre = p + z2 / (2 * n)
        let spread = z * ((p * (1 - p) + z2 / (4 * n)) / n).squareRoot()
        return max(0, (centre - spread) / (1 + z2 / n))
    }

    /// The `quantile` (0...1) of `values` by nearest rank; 0 for no values.
    public static func percentile(_ values: [Double], _ quantile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((Double(sorted.count) * quantile).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}
