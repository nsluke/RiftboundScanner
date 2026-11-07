import Foundation

/// Everything `riftscan evaluate --dump` writes: one entry per case with the
/// ranked candidates and their scores, the code read, the confidence verdict
/// and the engine, overlay and policy in force. `riftscan report` reads dumps
/// back and tallies them, so numbers in `docs/learning-eval.md` can be
/// regenerated from files rather than from a terminal scrollback.
public struct EvaluationDump: Sendable, Codable {
    public struct RankedEntry: Hashable, Sendable, Codable {
        public let id: Card.ID
        public let score: Double
        public let referenceScore: Double
        public let fusedScore: Double
        public let exemplarSimilarity: Double?
        public let codeAgreement: CodeAgreement?

        public init(id: Card.ID, score: Double, referenceScore: Double, fusedScore: Double, exemplarSimilarity: Double?, codeAgreement: CodeAgreement?) {
            self.id = id
            self.score = score
            self.referenceScore = referenceScore
            self.fusedScore = fusedScore
            self.exemplarSimilarity = exemplarSimilarity
            self.codeAgreement = codeAgreement
        }

        public init(_ match: Match) {
            self.init(id: match.card.id, score: match.score, referenceScore: match.referenceScore, fusedScore: match.descriptorScore, exemplarSimilarity: match.exemplarSimilarity, codeAgreement: match.codeAgreement)
        }
    }

    public struct CaseResult: Hashable, Sendable, Codable {
        public let evaluationCase: EvaluationCase
        /// Best first, at most the recogniser's shortlist.
        public let ranked: [RankedEntry]
        public let codeRead: PrintedCode?
        public let codeSource: CodeSource?
        public let codeConfidence: Double?
        public let placement: AdmissionInput.Placement
        public let verdict: ConfidenceVerdict
        public let seconds: Double

        public init(evaluationCase: EvaluationCase, ranked: [RankedEntry], codeRead: PrintedCode?, codeSource: CodeSource?, codeConfidence: Double?, placement: AdmissionInput.Placement, verdict: ConfidenceVerdict, seconds: Double) {
            self.evaluationCase = evaluationCase
            self.ranked = ranked
            self.codeRead = codeRead
            self.codeSource = codeSource
            self.codeConfidence = codeConfidence
            self.placement = placement
            self.verdict = verdict
            self.seconds = seconds
        }

        /// Where the expected card ranked, 0 for top-1; `nil` when absent.
        public var rank: Int? { ranked.firstIndex { $0.id == evaluationCase.expected } }

        public var isCorrect: Bool { rank == 0 }

        /// The winner owed some of its score to a learned exemplar.
        public var exemplarHit: Bool {
            guard let top = ranked.first, let similarity = top.exemplarSimilarity else { return false }
            return top.fusedScore > top.referenceScore && similarity > 0
        }

        private enum CodingKeys: String, CodingKey {
            case evaluationCase = "case", ranked, codeRead, codeSource, codeConfidence, placement, confident, uncertaintyReason, seconds
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let confident = try container.decode(Bool.self, forKey: .confident)
            let reason = try container.decodeIfPresent(ConfidenceVerdict.UncertaintyReason.self, forKey: .uncertaintyReason)
            self.init(
                evaluationCase: try container.decode(EvaluationCase.self, forKey: .evaluationCase),
                ranked: try container.decode([RankedEntry].self, forKey: .ranked),
                codeRead: try container.decodeIfPresent(PrintedCode.self, forKey: .codeRead),
                codeSource: try container.decodeIfPresent(CodeSource.self, forKey: .codeSource),
                codeConfidence: try container.decodeIfPresent(Double.self, forKey: .codeConfidence),
                placement: try container.decode(AdmissionInput.Placement.self, forKey: .placement),
                verdict: confident ? .confident : .uncertain(reason ?? .noMatch),
                seconds: try container.decode(Double.self, forKey: .seconds)
            )
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(evaluationCase, forKey: .evaluationCase)
            try container.encode(ranked, forKey: .ranked)
            try container.encodeIfPresent(codeRead, forKey: .codeRead)
            try container.encodeIfPresent(codeSource, forKey: .codeSource)
            try container.encodeIfPresent(codeConfidence, forKey: .codeConfidence)
            try container.encode(placement, forKey: .placement)
            try container.encode(verdict.isConfident, forKey: .confident)
            if case .uncertain(let reason) = verdict {
                try container.encode(reason, forKey: .uncertaintyReason)
            }
            try container.encode(seconds, forKey: .seconds)
        }
    }

    public let generatedAt: Date
    /// A name for the run (`baseline`, `fold-1CAED0F4`), chosen by the caller.
    public let label: String
    public let engine: EngineFingerprint
    public let indexEntryCount: Int
    public let overlayVersion: Int
    public let overlayExemplars: Int
    /// Batches whose exemplars were left out of the overlay for this run.
    public let excludedBatches: [UUID]
    public let policyVersion: Int
    public let cases: [CaseResult]

    public init(generatedAt: Date, label: String, engine: EngineFingerprint, indexEntryCount: Int, overlayVersion: Int, overlayExemplars: Int, excludedBatches: [UUID], policyVersion: Int, cases: [CaseResult]) {
        self.generatedAt = generatedAt
        self.label = label
        self.engine = engine
        self.indexEntryCount = indexEntryCount
        self.overlayVersion = overlayVersion
        self.overlayExemplars = overlayExemplars
        self.excludedBatches = excludedBatches
        self.policyVersion = policyVersion
        self.cases = cases
    }

    /// The raw and weighted tallies over every case.
    public func tally() -> EvaluationTally {
        var tally = EvaluationTally()
        for result in cases {
            tally.record(result.evaluationCase, ranked: result.ranked.map(\.id), duration: .seconds(result.seconds), confident: result.verdict.isConfident, exemplarHit: result.exemplarHit)
        }
        return tally
    }

    public static func read(from url: URL) throws -> EvaluationDump {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(EvaluationDump.self, from: try Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// What `riftscan build-overlay` writes beside its overlays: every scan it
/// analysed (the gate input plus the reference standing) and, per fold, the
/// gate's record for each scan and the resulting exemplar count.
/// `admission-report` and `gate-diff` read it.
public struct AdmissionDump: Sendable, Codable {
    public struct Fold: Hashable, Sendable, Codable {
        /// The batches held out of this fold's overlay; empty for the full build.
        public let excludedBatches: [UUID]
        public let records: [ExemplarAdmission.Record]
        public let exemplarCount: Int
        public let exemplarsByGroup: [String: Int]
        /// Where the fold's overlay was written, relative to the dump.
        public let overlayFile: String?

        public init(excludedBatches: [UUID], records: [ExemplarAdmission.Record], exemplarCount: Int, exemplarsByGroup: [String: Int], overlayFile: String?) {
            self.excludedBatches = excludedBatches
            self.records = records
            self.exemplarCount = exemplarCount
            self.exemplarsByGroup = exemplarsByGroup
            self.overlayFile = overlayFile
        }

        public var name: String {
            excludedBatches.isEmpty ? "all" : "holdout-" + excludedBatches.map { String($0.uuidString.prefix(8)) }.joined(separator: "+")
        }
    }

    /// Measurement-only relaxations of the gate's inputs. The legacy batches
    /// carry `legacy` decisions in `legacy`-training batches, which the gate
    /// refuses by rules 1 and 4; to measure what it would yield on their
    /// standard captures, `build-overlay` can present legacy judgements as
    /// human and override the batch training quality. An overlay built under
    /// either assumption is a smoke-test artefact, never one to ship.
    public struct Assumptions: Hashable, Sendable, Codable {
        public var acceptLegacyDecisions = false
        public var trainingQuality: AdmissionInput.CaptureQuality?

        public init(acceptLegacyDecisions: Bool = false, trainingQuality: AdmissionInput.CaptureQuality? = nil) {
            self.acceptLegacyDecisions = acceptLegacyDecisions
            self.trainingQuality = trainingQuality
        }

        public static let none = Assumptions()

        public var isStrict: Bool { self == .none }

        /// `input` as the gate will see it under these assumptions.
        public func apply(to input: AdmissionInput) -> AdmissionInput {
            guard !isStrict else { return input }
            return AdmissionInput(
                scanID: input.scanID,
                batchID: input.batchID,
                decisionSource: acceptLegacyDecisions && input.decisionSource == .legacy ? .human : input.decisionSource,
                decisionKind: input.decisionKind,
                cardID: input.cardID,
                placement: input.placement,
                calibrationHash: input.calibrationHash,
                captureQuality: input.captureQuality,
                trainingQuality: trainingQuality ?? input.trainingQuality,
                code: input.code,
                referenceSimilarity: input.referenceSimilarity,
                codeAlternatives: input.codeAlternatives,
                featurePrint: input.featurePrint
            )
        }

        public var description: String {
            var parts: [String] = []
            if acceptLegacyDecisions { parts.append("legacy decisions treated as human") }
            if let trainingQuality { parts.append("training quality assumed \(trainingQuality.rawValue)") }
            return parts.isEmpty ? "strict (no assumptions)" : parts.joined(separator: ", ")
        }
    }

    public let generatedAt: Date
    public let gateVersion: Int
    public let engine: EngineFingerprint
    public let policy: LearningPolicy.AdmissionPolicy
    public let assumptions: Assumptions
    /// Every scan as recognised on the Mac, before any assumption is applied.
    public let analyses: [AnalysedScan]
    public let folds: [Fold]

    public init(generatedAt: Date, engine: EngineFingerprint, policy: LearningPolicy.AdmissionPolicy, assumptions: Assumptions = .none, analyses: [AnalysedScan], folds: [Fold]) {
        self.generatedAt = generatedAt
        self.gateVersion = ExemplarAdmission.gateVersion
        self.engine = engine
        self.policy = policy
        self.assumptions = assumptions
        self.analyses = analyses
        self.folds = folds
    }

    /// The gate inputs of a fold in run order (every analysed scan outside the
    /// fold's held-out batches, under the dump's assumptions).
    public func inputs(for fold: Fold) -> [AdmissionInput] {
        analyses.filter { !fold.excludedBatches.contains($0.input.batchID) }.map { assumptions.apply(to: $0.input) }
    }

    public static func read(from url: URL) throws -> AdmissionDump {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AdmissionDump.self, from: try Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    // MARK: Report

    /// What `admission-report` prints: the distribution of similarities between
    /// scans of *different* art groups (the impostor rate the 0.90 rule guards
    /// against), the reference floor's ROC (genuine = each scan's similarity to
    /// its confirmed card, impostor = its similarity to the closest other art
    /// group's reference), and the gate's outcomes by reason.
    public struct Report: Hashable, Sendable {
        public struct ROCPoint: Hashable, Sendable {
            public let threshold: Double
            /// Share of genuine similarities at or above the threshold.
            public let genuinePassRate: Double
            /// Share of impostor similarities at or above the threshold.
            public let impostorPassRate: Double
        }

        public let scanCount: Int
        public let impostorPairCount: Int
        public let impostorP50: Double
        public let impostorP95: Double
        public let impostorP99: Double
        public let impostorMax: Double
        /// Pairs of different-group scans at or above the impostor similarity.
        public let impostorCollisions: Int
        public let genuineP50: Double
        public let roc: [ROCPoint]
        /// `outcome` or `outcome/reason` to count, per fold name.
        public let reasonsByFold: [String: [String: Int]]
    }

    public func report(impostorSimilarity: Double? = nil, thresholds: [Double] = stride(from: 0.50, through: 0.80, by: 0.02).map { ($0 * 100).rounded() / 100 }) -> Report {
        let impostorThreshold = impostorSimilarity ?? policy.impostorSimilarity
        var impostors: [Double] = []
        let grouped = analyses.filter { $0.input.artGroup != nil }
        for (offset, a) in grouped.enumerated() {
            for b in grouped[(offset + 1)...] where a.input.artGroup != b.input.artGroup {
                impostors.append(SimilarityContract.similarity(a.input.featurePrint, b.input.featurePrint))
            }
        }
        let genuine = grouped.map { SimilarityContract.round($0.input.referenceSimilarity) }
        let impostorReferences = grouped.map { SimilarityContract.round($0.bestOtherReferenceSimilarity) }
        let roc = thresholds.map { threshold in
            Report.ROCPoint(
                threshold: threshold,
                genuinePassRate: genuine.isEmpty ? 0 : Double(genuine.filter { $0 >= threshold }.count) / Double(genuine.count),
                impostorPassRate: impostorReferences.isEmpty ? 0 : Double(impostorReferences.filter { $0 >= threshold }.count) / Double(impostorReferences.count)
            )
        }
        var reasons: [String: [String: Int]] = [:]
        for fold in folds {
            for record in fold.records {
                let key = record.outcome.reason.map { "\(record.outcome.label)/\($0)" } ?? record.outcome.label
                reasons[fold.name, default: [:]][key, default: 0] += 1
            }
        }
        return Report(
            scanCount: grouped.count,
            impostorPairCount: impostors.count,
            impostorP50: Statistics.percentile(impostors, 0.50),
            impostorP95: Statistics.percentile(impostors, 0.95),
            impostorP99: Statistics.percentile(impostors, 0.99),
            impostorMax: impostors.max() ?? 0,
            impostorCollisions: impostors.filter { $0 >= impostorThreshold }.count,
            genuineP50: Statistics.percentile(genuine, 0.50),
            roc: roc,
            reasonsByFold: reasons
        )
    }
}
