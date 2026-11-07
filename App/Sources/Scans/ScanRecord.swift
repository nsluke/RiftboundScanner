import CoreGraphics
import Foundation
import RiftboundRecognizer

/// One captured photo, what the recogniser made of it, and what was decided
/// about it. Written to `scans.json` in the batch folder; the survey script
/// reads it. Version 2 (ADR-002, decision 6) adds the decision log, the
/// analysis, the engine stamp and the capture quality as optional keys with
/// legacy defaults, so v1 files keep decoding.
nonisolated struct ScanRecord: Hashable, Sendable, Codable, Identifiable {
    /// Encodes as the bare UUID string, so the JSON stays readable by scripts.
    struct ID: RawRepresentable, Hashable, Sendable, Codable {
        let rawValue: UUID

        init(rawValue: UUID) {
            self.rawValue = rawValue
        }

        init(from decoder: any Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(UUID.self)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    let id: ID
    let batchID: ScanBatch.ID
    let capturedAt: Date
    /// Relative to the batch folder.
    let photoFileName: String
    let rectifiedFileName: String?
    let processingSeconds: Double
    let placement: Placement
    let codeReading: CodeReadingSummary?
    /// Best first; at most five.
    let candidates: [Candidate]
    /// Every verdict ever given, oldest first; `seq` runs 1, 2, 3. Appended
    /// only by the store (`ScanStoring.decide`), never edited.
    private(set) var decisions: [Decision]
    /// The latest decision's verdict, kept encoded for the Python readers.
    private(set) var verdict: Verdict
    private(set) var verdictAt: Date?
    /// How the photo was cropped to the viewfinder guide, for diagnosing the
    /// mapping from screen to sensor; absent for uncropped or older scans.
    let crop: CropDebug?
    /// What the recogniser computed; `nil` on v1 records until re-identified.
    let analysis: ScanAnalysis?
    /// The engine that produced `candidates` and `analysis`; `nil` on v1 records.
    let engine: EngineStamp?
    /// Whether the photo can train the recogniser; v1 records are `legacy`.
    let captureQuality: CaptureQuality

    init(
        id: ID,
        batchID: ScanBatch.ID,
        capturedAt: Date,
        photoFileName: String,
        rectifiedFileName: String?,
        processingSeconds: Double,
        placement: Placement,
        codeReading: CodeReadingSummary?,
        candidates: [Candidate],
        decisions: [Decision] = [],
        crop: CropDebug? = nil,
        analysis: ScanAnalysis? = nil,
        engine: EngineStamp? = nil,
        captureQuality: CaptureQuality = .legacy
    ) {
        self.id = id
        self.batchID = batchID
        self.capturedAt = capturedAt
        self.photoFileName = photoFileName
        self.rectifiedFileName = rectifiedFileName
        self.processingSeconds = processingSeconds
        self.placement = placement
        self.codeReading = codeReading
        self.candidates = candidates
        self.decisions = decisions
        self.verdict = decisions.last?.verdict ?? .pending
        self.verdictAt = decisions.last?.decidedAt
        self.crop = crop
        self.analysis = analysis
        self.engine = engine
        self.captureQuality = captureQuality
    }

    var topCandidate: Candidate? { candidates.first }

    var lastDecision: Decision? { decisions.last }

    /// The card that was actually in the photo, as the latest decision
    /// recorded it. A snapshot: reordering `candidates` cannot change it.
    var confirmedCardID: Card.ID? {
        decisions.last?.cardID
    }

    /// The finish the decision log settled on; `nil` means inherit the batch
    /// default (or whatever `FinishPolicy` forces for the printing).
    var effectiveFinish: Finish? {
        decisions.reduce(nil) { $1.finish.value ?? $0 }
    }

    /// The printing to ledger when a decision chose one the recogniser cannot
    /// see; `nil` means the confirmed card's own key.
    var effectivePrintingCode: PrintingKey? {
        decisions.reduce(nil) { $1.ledgerPrintingCode.value ?? $0 }
    }

    /// The card a verdict names on this record, as a decision would snapshot it.
    func cardID(for verdict: Verdict) -> Card.ID? {
        switch verdict {
        case .pending, .rejected, .voided: nil
        case .correct: topCandidate?.card.id
        case .corrected(let id): id
        }
    }

    /// A copy with one more decision, numbered after the last. The store is
    /// the only caller; models ask it to decide and take back the result.
    func deciding(_ input: DecisionInput, id: Decision.ID, at decidedAt: Date) -> ScanRecord {
        appending(Decision(
            id: id,
            seq: decisions.count + 1,
            verdict: input.verdict,
            cardID: cardID(for: input.verdict),
            source: input.source,
            decidedAt: decidedAt,
            finish: input.finish,
            ledgerPrintingCode: input.ledgerPrintingCode
        ))
    }

    /// Whether `other` is this record with zero or more decisions appended,
    /// i.e. an update that cannot lose a decision already on disk.
    func isExtended(by other: ScanRecord) -> Bool {
        other.decisions.count >= decisions.count && Array(other.decisions.prefix(decisions.count)) == decisions
    }

    private func appending(_ decision: Decision) -> ScanRecord {
        var copy = self
        copy.decisions.append(decision)
        copy.verdict = decision.verdict
        copy.verdictAt = decision.decidedAt
        return copy
    }

    // MARK: - Coding

    private enum CodingKeys: String, CodingKey {
        case id, batchID, capturedAt, photoFileName, rectifiedFileName, processingSeconds, placement, codeReading, candidates
        case decisions, verdict, verdictAt, crop, analysis, engine, captureQuality
    }

    /// v1 files carry `verdict`/`verdictAt` and no `decisions`; a judged v1
    /// record gets one synthesised `legacy` decision so every reader sees
    /// the same shape, and `legacy` ledgers and trains nothing.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(ID.self, forKey: .id)
        let capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        let candidates = try container.decode([Candidate].self, forKey: .candidates)
        var decisions = try container.decodeIfPresent([Decision].self, forKey: .decisions) ?? []
        let encodedVerdict = try container.decodeIfPresent(Verdict.self, forKey: .verdict) ?? .pending
        let encodedVerdictAt = try container.decodeIfPresent(Date.self, forKey: .verdictAt)
        if decisions.isEmpty, encodedVerdict != .pending {
            let cardID: Card.ID? = switch encodedVerdict {
            case .correct: candidates.first?.card.id
            case .corrected(let corrected): corrected
            case .pending, .rejected, .voided: nil
            }
            decisions = [Decision(id: .legacy(for: id), seq: 1, verdict: encodedVerdict, cardID: cardID, source: .legacy, decidedAt: encodedVerdictAt ?? capturedAt)]
        }
        self.init(
            id: id,
            batchID: try container.decode(ScanBatch.ID.self, forKey: .batchID),
            capturedAt: capturedAt,
            photoFileName: try container.decode(String.self, forKey: .photoFileName),
            rectifiedFileName: try container.decodeIfPresent(String.self, forKey: .rectifiedFileName),
            processingSeconds: try container.decode(Double.self, forKey: .processingSeconds),
            placement: try container.decode(Placement.self, forKey: .placement),
            codeReading: try container.decodeIfPresent(CodeReadingSummary.self, forKey: .codeReading),
            candidates: candidates,
            decisions: decisions,
            crop: try container.decodeIfPresent(CropDebug.self, forKey: .crop),
            analysis: try container.decodeIfPresent(ScanAnalysis.self, forKey: .analysis),
            engine: try container.decodeIfPresent(EngineStamp.self, forKey: .engine),
            captureQuality: try container.decodeIfPresent(CaptureQuality.self, forKey: .captureQuality) ?? .legacy
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(batchID, forKey: .batchID)
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encode(photoFileName, forKey: .photoFileName)
        try container.encodeIfPresent(rectifiedFileName, forKey: .rectifiedFileName)
        try container.encode(processingSeconds, forKey: .processingSeconds)
        try container.encode(placement, forKey: .placement)
        try container.encodeIfPresent(codeReading, forKey: .codeReading)
        try container.encode(candidates, forKey: .candidates)
        try container.encode(decisions, forKey: .decisions)
        try container.encode(verdict, forKey: .verdict)
        try container.encodeIfPresent(verdictAt, forKey: .verdictAt)
        try container.encodeIfPresent(crop, forKey: .crop)
        try container.encodeIfPresent(analysis, forKey: .analysis)
        try container.encodeIfPresent(engine, forKey: .engine)
        try container.encode(captureQuality, forKey: .captureQuality)
    }
}

/// A ranked printing with the scores that put it there.
nonisolated struct Candidate: Hashable, Sendable, Codable {
    let card: Card
    let score: Double
    let descriptorScore: Double
    let orientation: CardOrientation
    let codeAgreement: CodeAgreement?
    /// Whether `codeAgreement` was judged against the code as read (`literal`)
    /// or against a parser repair of it (`alternative`); `nil` without a code
    /// agreement. On the wire only `alternative` is written: absent means
    /// literal, so records written before the parser offered alternatives
    /// (which all matched the literal reading) re-encode byte for byte.
    let codeOrigin: CodeAlternative.Origin?

    init(card: Card, score: Double, descriptorScore: Double, orientation: CardOrientation, codeAgreement: CodeAgreement?, codeOrigin: CodeAlternative.Origin? = nil) {
        self.card = card
        self.score = score
        self.descriptorScore = descriptorScore
        self.orientation = orientation
        self.codeAgreement = codeAgreement
        self.codeOrigin = codeAgreement == nil ? nil : codeOrigin ?? .literal
    }

    /// Until the parser's alternatives reach `Match` (P2), every agreement is
    /// against the literal reading.
    init(_ match: Match) {
        self.init(card: match.card, score: match.score, descriptorScore: match.descriptorScore, orientation: match.orientation, codeAgreement: match.codeAgreement, codeOrigin: .literal)
    }

    private enum CodingKeys: String, CodingKey {
        case card, score, descriptorScore, orientation, codeAgreement, codeOrigin
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            card: try container.decode(Card.self, forKey: .card),
            score: try container.decode(Double.self, forKey: .score),
            descriptorScore: try container.decode(Double.self, forKey: .descriptorScore),
            orientation: try container.decode(CardOrientation.self, forKey: .orientation),
            codeAgreement: try container.decodeIfPresent(CodeAgreement.self, forKey: .codeAgreement),
            codeOrigin: try container.decodeIfPresent(CodeAlternative.Origin.self, forKey: .codeOrigin)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(card, forKey: .card)
        try container.encode(score, forKey: .score)
        try container.encode(descriptorScore, forKey: .descriptorScore)
        try container.encode(orientation, forKey: .orientation)
        try container.encodeIfPresent(codeAgreement, forKey: .codeAgreement)
        if codeOrigin == .alternative {
            try container.encode(codeOrigin, forKey: .codeOrigin)
        }
    }
}

/// Where the recogniser found the card.
nonisolated enum Placement: Hashable, Sendable, Codable {
    case detected(confidence: Double)
    case wholeImage

    init(_ location: CardLocation) {
        switch location {
        case .detected(_, let confidence): self = .detected(confidence: confidence)
        case .assumedWholeImage: self = .wholeImage
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, confidence
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "detected": self = .detected(confidence: try container.decode(Double.self, forKey: .confidence))
        case "wholeImage": self = .wholeImage
        case let other: throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown placement \(other)")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .detected(let confidence):
            try container.encode("detected", forKey: .kind)
            try container.encode(confidence, forKey: .confidence)
        case .wholeImage:
            try container.encode("wholeImage", forKey: .kind)
        }
    }
}

/// The printed code the OCR pass read, if any.
nonisolated struct CodeReadingSummary: Hashable, Sendable, Codable {
    let code: PrintedCode
    let confidence: Double
    let text: String
    let orientation: CardOrientation
    let layout: Card.Orientation

    init(code: PrintedCode, confidence: Double, text: String, orientation: CardOrientation, layout: Card.Orientation) {
        self.code = code
        self.confidence = confidence
        self.text = text
        self.orientation = orientation
        self.layout = layout
    }

    init(_ reading: CodeReading) {
        self.init(code: reading.code, confidence: reading.confidence, text: reading.text, orientation: reading.orientation, layout: reading.layout)
    }
}

/// What the user said about the top candidate.
nonisolated enum Verdict: Hashable, Sendable {
    case pending
    /// The top candidate was right.
    case correct
    /// The card was a different printing.
    case corrected(Card.ID)
    case rejected(RejectionReason)
    /// The batch was voided after this scan was judged; its ledger effect is undone.
    case voided
}

nonisolated enum RejectionReason: String, Hashable, Sendable, Codable, CaseIterable {
    case notACard
    case cardNotInCatalog
    case unreadable

    var label: String {
        switch self {
        case .notACard: String(localized: "Not a card")
        case .cardNotInCatalog: String(localized: "Card not in catalog")
        case .unreadable: String(localized: "Can't tell")
        }
    }
}

extension Verdict: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, cardID, reason
    }

    private enum Kind: String, Codable {
        case pending, correct, corrected, rejected, voided
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .pending: self = .pending
        case .correct: self = .correct
        case .corrected: self = .corrected(try container.decode(Card.ID.self, forKey: .cardID))
        case .rejected: self = .rejected(try container.decode(RejectionReason.self, forKey: .reason))
        case .voided: self = .voided
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pending:
            try container.encode(Kind.pending, forKey: .kind)
        case .correct:
            try container.encode(Kind.correct, forKey: .kind)
        case .corrected(let id):
            try container.encode(Kind.corrected, forKey: .kind)
            try container.encode(id, forKey: .cardID)
        case .rejected(let reason):
            try container.encode(Kind.rejected, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case .voided:
            try container.encode(Kind.voided, forKey: .kind)
        }
    }
}

/// The numbers behind a guide crop, saved with the scan so a bad crop can be
/// traced to the frame that produced it.
nonisolated struct CropDebug: Hashable, Sendable, Codable {
    struct Rect: Hashable, Sendable, Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        init(_ rect: CGRect) {
            x = rect.origin.x
            y = rect.origin.y
            width = rect.width
            height = rect.height
        }
    }

    let guideFrame: Rect
    let previewFrame: Rect
    let photoWidth: Int
    let photoHeight: Int
    let pixelRect: Rect

    init(crop: GuideCrop, photoWidth: Int, photoHeight: Int, pixelRect: CGRect) {
        guideFrame = Rect(crop.guideFrame)
        previewFrame = Rect(crop.previewFrame)
        self.photoWidth = photoWidth
        self.photoHeight = photoHeight
        self.pixelRect = Rect(pixelRect)
    }
}
