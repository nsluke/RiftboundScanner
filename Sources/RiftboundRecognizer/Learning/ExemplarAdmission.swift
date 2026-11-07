import Foundation

/// Everything the admission gate needs to know about one confirmed scan
/// (ADR-002, section 7). The phone computes most of it at identify and upload
/// time; the server stores it; `riftscan build-overlay` recomputes it on the
/// Mac from the photo. Nothing here is an image or a Riot URL.
///
/// The gate is deliberately a pure function of this value, the other scans
/// offered as witnesses and the exemplars already admitted, so the Swift and
/// Python implementations can be checked against one fixture.
public struct AdmissionInput: Hashable, Sendable, Codable {
    /// Who gave the latest decision; the package's copy of the app's
    /// `DecisionSource`, with the same raw values.
    public enum DecisionSource: String, Hashable, Sendable, Codable, CaseIterable {
        case human, autoAccepted, audit, spotCheck, legacy

        /// A person looked at the card (rule 1).
        public var isHuman: Bool {
            switch self {
            case .human, .audit, .spotCheck: true
            case .autoAccepted, .legacy: false
            }
        }
    }

    public enum DecisionKind: String, Hashable, Sendable, Codable, CaseIterable {
        case pending, correct, corrected, rejected, voided

        /// The decision names a card that was in the photo.
        public var confirmsACard: Bool { self == .correct || self == .corrected }
    }

    public enum Placement: String, Hashable, Sendable, Codable {
        case detected, wholeImage
    }

    /// Per-scan `captureQuality` and the batch's `trainingQuality` override
    /// share one vocabulary (rule 4).
    public enum CaptureQuality: String, Hashable, Sendable, Codable, CaseIterable {
        case standard, legacy
    }

    /// The winning printed code as evidence: where it was read, whether it was
    /// read literally or repaired by the parser (``CodeOrigin``, the
    /// recogniser's own vocabulary), and how it relates to the confirmed card.
    /// Absent when no code was read.
    public struct CodeEvidence: Hashable, Sendable, Codable {
        public let source: CodeSource
        public let origin: CodeOrigin
        public let agreement: CodeAgreement

        public init(source: CodeSource, origin: CodeOrigin, agreement: CodeAgreement) {
            self.source = source
            self.origin = origin
            self.agreement = agreement
        }
    }

    /// A code the OCR pass offered (the literal reading or a parser repair)
    /// with the reference similarity of the card it names, so the gate can see
    /// the margin between the confirmed card and the digit-neighbour the OCR
    /// might have meant. `referenceSimilarity` is `nil` when the code names no
    /// indexed printing; such an entry cannot be the true card and is ignored.
    public struct CodeAlternative: Hashable, Sendable, Codable {
        public let code: PrintedCode
        public let origin: CodeOrigin
        public let referenceSimilarity: Double?

        public init(code: PrintedCode, origin: CodeOrigin, referenceSimilarity: Double?) {
            self.code = code
            self.origin = origin
            self.referenceSimilarity = referenceSimilarity
        }

        public var artGroup: ArtGroup { ArtGroup(code: code) }
    }

    public let scanID: UUID
    public let batchID: UUID
    public let decisionSource: DecisionSource
    public let decisionKind: DecisionKind
    /// The card the latest decision confirmed (a snapshot, never re-derived).
    public let cardID: Card.ID?
    public let placement: Placement
    /// The embedding the descriptor was computed in (`EngineStamp.calibrationHash`).
    public let calibrationHash: FeaturePrint.Digest
    public let captureQuality: CaptureQuality
    /// The batch's `trainingQuality`; `legacy` vetoes every scan in it.
    public let trainingQuality: CaptureQuality
    public let code: CodeEvidence?
    /// Feature-print cosine between the oriented descriptor and the confirmed
    /// card's reference print.
    public let referenceSimilarity: Double
    public let codeAlternatives: [CodeAlternative]
    /// The oriented descriptor's feature print: the exemplar-to-be.
    public let featurePrint: FeaturePrint

    public init(
        scanID: UUID,
        batchID: UUID,
        decisionSource: DecisionSource,
        decisionKind: DecisionKind,
        cardID: Card.ID?,
        placement: Placement,
        calibrationHash: FeaturePrint.Digest,
        captureQuality: CaptureQuality,
        trainingQuality: CaptureQuality,
        code: CodeEvidence?,
        referenceSimilarity: Double,
        codeAlternatives: [CodeAlternative],
        featurePrint: FeaturePrint
    ) {
        self.scanID = scanID
        self.batchID = batchID
        self.decisionSource = decisionSource
        self.decisionKind = decisionKind
        self.cardID = cardID
        self.placement = placement
        self.calibrationHash = calibrationHash
        self.captureQuality = captureQuality
        self.trainingQuality = trainingQuality
        self.code = code
        self.referenceSimilarity = referenceSimilarity
        self.codeAlternatives = codeAlternatives
        self.featurePrint = featurePrint
    }

    /// The learning identity the scan would be admitted for.
    public var artGroup: ArtGroup? { cardID.map(ArtGroup.init) }

    private enum CodingKeys: String, CodingKey {
        case scanID, batchID, decisionSource, decisionKind, cardID, placement, calibrationHash, captureQuality, trainingQuality
        case code, referenceSimilarity, codeAlternatives, featurePrint
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            scanID: try container.decode(UUID.self, forKey: .scanID),
            batchID: try container.decode(UUID.self, forKey: .batchID),
            decisionSource: try container.decode(DecisionSource.self, forKey: .decisionSource),
            decisionKind: try container.decode(DecisionKind.self, forKey: .decisionKind),
            cardID: try container.decodeIfPresent(Card.ID.self, forKey: .cardID),
            placement: try container.decode(Placement.self, forKey: .placement),
            calibrationHash: try container.decode(FeaturePrint.Digest.self, forKey: .calibrationHash),
            captureQuality: try container.decode(CaptureQuality.self, forKey: .captureQuality),
            trainingQuality: try container.decode(CaptureQuality.self, forKey: .trainingQuality),
            code: try container.decodeIfPresent(CodeEvidence.self, forKey: .code),
            referenceSimilarity: try container.decode(Double.self, forKey: .referenceSimilarity),
            codeAlternatives: try container.decodeIfPresent([CodeAlternative].self, forKey: .codeAlternatives) ?? [],
            featurePrint: try container.decode(FeaturePrint.self, forKey: .featurePrint)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scanID, forKey: .scanID)
        try container.encode(batchID, forKey: .batchID)
        try container.encode(decisionSource, forKey: .decisionSource)
        try container.encode(decisionKind, forKey: .decisionKind)
        try container.encodeIfPresent(cardID, forKey: .cardID)
        try container.encode(placement, forKey: .placement)
        try container.encode(calibrationHash, forKey: .calibrationHash)
        try container.encode(captureQuality, forKey: .captureQuality)
        try container.encode(trainingQuality, forKey: .trainingQuality)
        try container.encodeIfPresent(code, forKey: .code)
        try container.encode(referenceSimilarity, forKey: .referenceSimilarity)
        try container.encode(codeAlternatives, forKey: .codeAlternatives)
        try container.encode(featurePrint, forKey: .featurePrint)
    }
}

/// An exemplar the gate must respect: what the overlay already holds for a
/// calibration hash, with the reference similarity its scan had (the cap rule
/// ranks by it). ``ExemplarIndex/Exemplar`` carries no reference similarity,
/// so building one from an overlay needs the value from the server's row.
public struct ExistingExemplar: Hashable, Sendable, Codable, Identifiable {
    public let scanID: UUID
    public let artGroup: ArtGroup
    public let featurePrint: FeaturePrint
    public let referenceSimilarity: Double

    public init(scanID: UUID, artGroup: ArtGroup, featurePrint: FeaturePrint, referenceSimilarity: Double) {
        self.scanID = scanID
        self.artGroup = artGroup
        self.featurePrint = featurePrint
        self.referenceSimilarity = referenceSimilarity
    }

    /// The exemplar an admitted input becomes.
    public init(admitting input: AdmissionInput, artGroup: ArtGroup) {
        self.init(scanID: input.scanID, artGroup: artGroup, featurePrint: input.featurePrint, referenceSimilarity: input.referenceSimilarity)
    }

    public var id: UUID { scanID }
}

/// What the gate decided for one scan. The flat JSON form (`outcome`, then the
/// keys that case carries) is what the fixture's `expected` holds and what
/// `POST /api/learning/admit/dry-run` returns.
public enum AdmissionOutcome: Hashable, Sendable {
    public enum Tier: String, Hashable, Sendable, Codable {
        /// Rule 5: a literal edge-band code agreeing with the confirmed card.
        case code
        /// Rule 5: no code, but a second human-confirmed scan of the same art agrees.
        case artCorroborated
    }

    /// Why a scan was turned away by rules 1-5 or 8. The raw values are the
    /// `admission_log.reason` vocabulary.
    public enum RejectionReason: String, Hashable, Sendable, Codable, CaseIterable {
        /// Rule 1: the latest decision was made by a machine or synthesised.
        case decisionSource
        /// Rule 1: the latest decision confirms no card (pending, rejected, voided).
        case decisionKind
        /// Rule 1: a confirming decision with no card snapshot.
        case noCardID
        /// Rule 2: the whole image stood in for the card.
        case placement
        /// Rule 3: computed in another embedding space than the overlay's.
        case calibrationMismatch
        /// Rule 4: the photo was not a standard capture.
        case captureQuality
        /// Rule 4: the batch's training override is `legacy`.
        case trainingQuality
        /// Rule 5: the code was read off the whole photo, not the card's edge band.
        case codeSource
        /// Rule 5: the winning code was a parser repair, not what was printed.
        case codeNotLiteral
        /// Rule 5: the code read does not name the confirmed card exactly.
        case codeDisagrees
        /// Rule 5, tier code: reference similarity under ``LearningPolicy/AdmissionPolicy/referenceSimilarityFloor``.
        case referenceBelowFloor
        /// Rule 5, tier code: a code alternative naming another art group is too close.
        case alternativeMargin
        /// Rule 5, tier art: the scan's own reference similarity is under the witness floor.
        case witnessReferenceBelowFloor
        /// Rule 8: the group is full and the scan adds less variety than what is kept.
        case capReached
    }

    /// Admitted for its art group. `corroborators` are the witness scans that
    /// vouched for an `artCorroborated` admission and are admitted with it;
    /// `evicted` are exemplars the cap rule drops to make room.
    case admitted(tier: Tier, corroborators: [UUID], evicted: [UUID])
    case rejected(RejectionReason)
    /// Rule 5, tier art: eligible, but no second human scan agrees yet.
    case needsSecondWitness
    /// Rule 6: an exemplar of another art group is at least ``LearningPolicy/AdmissionPolicy/impostorSimilarity`` close.
    case blocked(by: UUID, similarity: Double)
    /// Rule 7: an exemplar of the same group is at least ``LearningPolicy/AdmissionPolicy/duplicateSimilarity`` close.
    case duplicate(of: UUID, similarity: Double)

    public var isAdmitted: Bool {
        if case .admitted = self { true } else { false }
    }

    public var tier: Tier? {
        if case .admitted(let tier, _, _) = self { tier } else { nil }
    }

    /// The `admission_log.outcome` word.
    public var label: String {
        switch self {
        case .admitted: "admitted"
        case .rejected: "rejected"
        case .needsSecondWitness: "needsSecondWitness"
        case .blocked: "blocked"
        case .duplicate: "duplicate"
        }
    }

    /// The `admission_log.reason` word, when the outcome has one.
    public var reason: String? {
        if case .rejected(let reason) = self { reason.rawValue } else { nil }
    }
}

extension AdmissionOutcome: Codable {
    private enum CodingKeys: String, CodingKey {
        case outcome, tier, corroborators, evicted, reason, blockingScanID, duplicateOf, similarity
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .outcome) {
        case "admitted":
            self = .admitted(
                tier: try container.decode(Tier.self, forKey: .tier),
                corroborators: try container.decodeIfPresent([UUID].self, forKey: .corroborators) ?? [],
                evicted: try container.decodeIfPresent([UUID].self, forKey: .evicted) ?? []
            )
        case "rejected":
            self = .rejected(try container.decode(RejectionReason.self, forKey: .reason))
        case "needsSecondWitness":
            self = .needsSecondWitness
        case "blocked":
            self = .blocked(by: try container.decode(UUID.self, forKey: .blockingScanID), similarity: try container.decode(Double.self, forKey: .similarity))
        case "duplicate":
            self = .duplicate(of: try container.decode(UUID.self, forKey: .duplicateOf), similarity: try container.decode(Double.self, forKey: .similarity))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .outcome, in: container, debugDescription: "unknown admission outcome '\(other)'")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(label, forKey: .outcome)
        switch self {
        case .admitted(let tier, let corroborators, let evicted):
            try container.encode(tier, forKey: .tier)
            try container.encode(corroborators, forKey: .corroborators)
            try container.encode(evicted, forKey: .evicted)
        case .rejected(let reason):
            try container.encode(reason, forKey: .reason)
        case .needsSecondWitness:
            break
        case .blocked(let scanID, let similarity):
            try container.encode(scanID, forKey: .blockingScanID)
            try container.encode(similarity, forKey: .similarity)
        case .duplicate(let scanID, let similarity):
            try container.encode(scanID, forKey: .duplicateOf)
            try container.encode(similarity, forKey: .similarity)
        }
    }
}

/// The exemplar admission gate, version 2 (ADR-002, section 7, rules 1-8): a
/// pure function of the candidate scan, the other scans offered as witnesses
/// for the art tier, and the exemplars already admitted for the same
/// calibration hash. Every similarity goes through ``SimilarityContract``, and
/// so does every number the gate derives from one before comparing it (the
/// alternative margin's difference, the cap rule's mean similarities).
///
/// Rules, in order: (1) the latest decision is human, audit or spot-check,
/// confirms a card and snapshots its id; (2) the card was detected, not
/// assumed to fill the photo; (3) the descriptor was computed in the overlay's
/// embedding space; (4) the capture is standard and the batch does not veto
/// training; (5) tier `code` (literal edge-band code naming the confirmed card
/// exactly, reference similarity at or above the floor, and a margin over every
/// code alternative that names another art group) or tier `artCorroborated`
/// (no code read; a second eligible, codeless, human-confirmed scan of the same
/// group from another capture agrees at the mutual-similarity threshold while
/// both clear the witness floor; one scan alone is `needsSecondWitness`);
/// (6) an existing exemplar of another group at or above the impostor
/// similarity blocks; (7) an existing exemplar of the same group at or above
/// the duplicate similarity makes it a duplicate; (8) a full group keeps its
/// medoid and then the most varied prints among those with the better half of
/// reference similarities.
public struct ExemplarAdmission: Hashable, Sendable {
    public static let gateVersion = 2

    public let policy: LearningPolicy.AdmissionPolicy
    /// The overlay's calibration hash; a scan from another space is refused (rule 3).
    public let calibrationHash: FeaturePrint.Digest

    public init(policy: LearningPolicy.AdmissionPolicy, calibrationHash: FeaturePrint.Digest) {
        self.policy = policy
        self.calibrationHash = calibrationHash
    }

    // MARK: Rules 1-4

    /// Why a scan can never become an exemplar whatever its code or witnesses
    /// say, or `nil` when rules 1-4 pass.
    public func ineligibility(of input: AdmissionInput) -> AdmissionOutcome.RejectionReason? {
        guard input.decisionSource.isHuman else { return .decisionSource }
        guard input.decisionKind.confirmsACard else { return .decisionKind }
        guard input.cardID != nil else { return .noCardID }
        guard input.placement == .detected else { return .placement }
        guard input.calibrationHash == calibrationHash else { return .calibrationMismatch }
        guard input.captureQuality == .standard else { return .captureQuality }
        guard input.trainingQuality != .legacy else { return .trainingQuality }
        return nil
    }

    // MARK: The gate

    /// Decides one scan. `witnesses` are other scans that may corroborate an
    /// art-tier admission (the gate checks each one's eligibility itself);
    /// `existing` are the exemplars currently admitted for this calibration
    /// hash, across every group.
    public func decide(_ candidate: AdmissionInput, witnesses: [AdmissionInput] = [], existing: [ExistingExemplar] = []) -> AdmissionOutcome {
        if let reason = ineligibility(of: candidate) {
            return .rejected(reason)
        }
        guard let group = candidate.artGroup else { return .rejected(.noCardID) }
        let reference = SimilarityContract.round(candidate.referenceSimilarity)

        // Rule 5.
        let tier: AdmissionOutcome.Tier
        var corroborators: [UUID] = []
        if let code = candidate.code {
            guard code.source == .edgeBand else { return .rejected(.codeSource) }
            guard code.origin == .literal else { return .rejected(.codeNotLiteral) }
            guard code.agreement == .exact else { return .rejected(.codeDisagrees) }
            guard reference >= policy.referenceSimilarityFloor else { return .rejected(.referenceBelowFloor) }
            for alternative in candidate.codeAlternatives where alternative.artGroup != group {
                guard let similarity = alternative.referenceSimilarity else { continue }
                // The margin is a difference of two rounded values, itself
                // rounded (contract point 4): 0.70 - 0.65 in binary doubles is
                // 0.04999..., which would refuse an exact 0.05 margin.
                if SimilarityContract.round(reference - SimilarityContract.round(similarity)) < policy.alternativeMargin {
                    return .rejected(.alternativeMargin)
                }
            }
            tier = .code
        } else {
            guard reference >= policy.witnessReferenceFloor else { return .rejected(.witnessReferenceBelowFloor) }
            corroborators = witnesses
                .filter { corroborates(candidate, group: group, witness: $0) }
                .map(\.scanID)
                .sorted { $0.uuidString < $1.uuidString }
            guard !corroborators.isEmpty else { return .needsSecondWitness }
            tier = .artCorroborated
        }

        // Rules 6 and 7, each against the closest offender.
        var impostor: (scanID: UUID, similarity: Double)?
        var twin: (scanID: UUID, similarity: Double)?
        for exemplar in existing {
            let similarity = SimilarityContract.similarity(candidate.featurePrint, exemplar.featurePrint)
            if exemplar.artGroup != group {
                if similarity >= policy.impostorSimilarity, Self.closer(similarity, exemplar.scanID, than: impostor) {
                    impostor = (exemplar.scanID, similarity)
                }
            } else if similarity >= policy.duplicateSimilarity, Self.closer(similarity, exemplar.scanID, than: twin) {
                twin = (exemplar.scanID, similarity)
            }
        }
        if let impostor {
            return .blocked(by: impostor.scanID, similarity: impostor.similarity)
        }
        if let twin {
            return .duplicate(of: twin.scanID, similarity: twin.similarity)
        }

        // Rule 8.
        let members = existing.filter { $0.artGroup == group }
        guard members.count >= policy.maximumPerGroup else {
            return .admitted(tier: tier, corroborators: corroborators, evicted: [])
        }
        let kept = Self.select(from: members + [ExistingExemplar(admitting: candidate, artGroup: group)], cap: policy.maximumPerGroup)
        guard kept.contains(candidate.scanID) else { return .rejected(.capReached) }
        let evicted = members.map(\.scanID).filter { !kept.contains($0) }.sorted { $0.uuidString < $1.uuidString }
        return .admitted(tier: tier, corroborators: corroborators, evicted: evicted)
    }

    /// Whether `witness` is a second human-confirmed, codeless capture of the
    /// same art that agrees with the candidate (rule 5, tier `artCorroborated`).
    private func corroborates(_ candidate: AdmissionInput, group: ArtGroup, witness: AdmissionInput) -> Bool {
        guard witness.scanID != candidate.scanID,
              witness.code == nil,
              witness.artGroup == group,
              ineligibility(of: witness) == nil,
              SimilarityContract.round(witness.referenceSimilarity) >= policy.witnessReferenceFloor
        else { return false }
        return SimilarityContract.similarity(candidate.featurePrint, witness.featurePrint) >= policy.witnessMutualSimilarity
    }

    private static func closer(_ similarity: Double, _ scanID: UUID, than current: (scanID: UUID, similarity: Double)?) -> Bool {
        guard let current else { return true }
        return similarity > current.similarity || (similarity == current.similarity && scanID.uuidString < current.scanID.uuidString)
    }

    // MARK: Rule 8

    /// The scans a full group keeps (rule 8): the medoid (highest mean
    /// similarity to the others) first, then by farthest-point selection
    /// (whichever remaining print is least similar to everything kept so far)
    /// drawn from the candidates whose reference similarity is in the top half,
    /// and from the rest only once that pool is exhausted. Ties fall to the
    /// lexically smaller scan id, so both implementations agree.
    public static func select(from candidates: [ExistingExemplar], cap: Int) -> Set<UUID> {
        guard cap > 0, candidates.count > cap else { return Set(candidates.map(\.scanID)) }
        let ordered = candidates.sorted { $0.scanID.uuidString < $1.scanID.uuidString }
        var similarity: [UUID: [UUID: Double]] = [:]
        for a in ordered {
            for b in ordered where a.scanID != b.scanID {
                similarity[a.scanID, default: [:]][b.scanID] = SimilarityContract.similarity(a.featurePrint, b.featurePrint)
            }
        }
        func meanSimilarity(_ exemplar: ExistingExemplar) -> Double {
            let others = similarity[exemplar.scanID] ?? [:]
            guard !others.isEmpty else { return 1 }
            return SimilarityContract.round(others.values.reduce(0, +) / Double(others.count))
        }
        let medoid = ordered.max { lhs, rhs in
            let left = meanSimilarity(lhs)
            let right = meanSimilarity(rhs)
            return left != right ? left < right : lhs.scanID.uuidString > rhs.scanID.uuidString
        }!

        var kept: [UUID] = [medoid.scanID]
        let byReference = ordered.sorted { lhs, rhs in
            let left = SimilarityContract.round(lhs.referenceSimilarity)
            let right = SimilarityContract.round(rhs.referenceSimilarity)
            return left != right ? left > right : lhs.scanID.uuidString < rhs.scanID.uuidString
        }
        let topHalfCount = (byReference.count + 1) / 2
        var pools = [Array(byReference.prefix(topHalfCount)), Array(byReference.dropFirst(topHalfCount))]
        for index in pools.indices {
            pools[index].removeAll { $0.scanID == medoid.scanID }
        }
        for var pool in pools where kept.count < cap {
            while kept.count < cap, !pool.isEmpty {
                // The farthest point: the smallest maximum similarity to what is kept.
                let next = pool.min { lhs, rhs in
                    let left = kept.map { similarity[lhs.scanID]?[$0] ?? 0 }.max() ?? 0
                    let right = kept.map { similarity[rhs.scanID]?[$0] ?? 0 }.max() ?? 0
                    return left != right ? left < right : lhs.scanID.uuidString < rhs.scanID.uuidString
                }!
                kept.append(next.scanID)
                pool.removeAll { $0.scanID == next.scanID }
            }
        }
        return Set(kept)
    }

    // MARK: Many scans

    /// One scan's outcome in a run over a set of scans.
    public struct Record: Hashable, Sendable, Codable, Identifiable {
        public let scanID: UUID
        public let batchID: UUID
        public let artGroup: ArtGroup?
        public let outcome: AdmissionOutcome

        public var id: UUID { scanID }
    }

    /// What ``run(_:existing:)`` produced: a record per input, in input order,
    /// and the exemplars in force afterwards (the survivors of `existing` plus
    /// every admission, minus the cap's evictions).
    public struct Run: Hashable, Sendable {
        public let records: [Record]
        public let exemplars: [ExistingExemplar]

        public var admitted: [Record] { records.filter(\.outcome.isAdmitted) }
    }

    /// Admits a set of scans in order, as the server does when a batch arrives:
    /// scans with a code first (tier `code` needs no witness), then the
    /// codeless ones, each offered every other codeless input of its group as
    /// a witness. Exemplars admitted earlier in the run count as `existing`
    /// for the later scans, so dedupe, impostor and cap rules apply within the
    /// run; the cap's evictions are removed as they happen.
    public func run(_ inputs: [AdmissionInput], existing: [ExistingExemplar] = []) -> Run {
        var exemplars = existing
        var records: [Record] = []
        for step in replay(inputs, existing: existing) {
            exemplars = step.exemplarsAfter
            records.append(Record(scanID: step.request.candidate.scanID, batchID: step.request.candidate.batchID, artGroup: step.request.candidate.artGroup, outcome: step.outcome))
        }
        // Two inputs with one scan id (a scan pulled into two batch folders)
        // keep the first position rather than trapping; the importer refuses
        // such duplicates before they reach the gate.
        let order = Dictionary(inputs.enumerated().map { ($1.scanID, $0) }, uniquingKeysWith: { first, _ in first })
        return Run(records: records.sorted { (order[$0.scanID] ?? 0) < (order[$1.scanID] ?? 0) }, exemplars: exemplars)
    }

    /// One gate call of a run, with the inputs exactly as the gate saw them,
    /// so another implementation can be asked the same question (`gate-diff`).
    public struct Step: Hashable, Sendable {
        public let request: AdmissionRequest
        public let outcome: AdmissionOutcome
        public let exemplarsAfter: [ExistingExemplar]
    }

    /// The gate calls ``run(_:existing:)`` makes, in the order it makes them.
    public func replay(_ inputs: [AdmissionInput], existing: [ExistingExemplar] = []) -> [Step] {
        var exemplars = existing
        var steps: [Step] = []
        let coded = inputs.filter { $0.code != nil }
        let codeless = inputs.filter { $0.code == nil }
        for input in coded + codeless {
            let witnesses = input.code == nil ? codeless.filter { $0.scanID != input.scanID && $0.artGroup == input.artGroup } : []
            let request = AdmissionRequest(calibrationHash: calibrationHash, policy: policy, candidate: input, witnesses: witnesses, existing: exemplars)
            let outcome = decide(input, witnesses: witnesses, existing: exemplars)
            if case .admitted(_, _, let evicted) = outcome, let group = input.artGroup {
                exemplars.removeAll { evicted.contains($0.scanID) }
                exemplars.append(ExistingExemplar(admitting: input, artGroup: group))
            }
            steps.append(Step(request: request, outcome: outcome, exemplarsAfter: exemplars))
        }
        return steps
    }
}
