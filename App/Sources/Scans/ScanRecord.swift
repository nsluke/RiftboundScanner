import CoreGraphics
import Foundation
import RiftboundRecognizer

/// One captured photo, what the recogniser made of it, and what the user said.
/// Written to `scans.json` in the batch folder; the survey script reads it.
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
    var verdict: Verdict
    var verdictAt: Date?
    /// How the photo was cropped to the viewfinder guide, for diagnosing the
    /// mapping from screen to sensor; absent for uncropped or older scans.
    let crop: CropDebug?

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
        verdict: Verdict = .pending,
        verdictAt: Date? = nil,
        crop: CropDebug? = nil
    ) {
        self.crop = crop
        self.id = id
        self.batchID = batchID
        self.capturedAt = capturedAt
        self.photoFileName = photoFileName
        self.rectifiedFileName = rectifiedFileName
        self.processingSeconds = processingSeconds
        self.placement = placement
        self.codeReading = codeReading
        self.candidates = candidates
        self.verdict = verdict
        self.verdictAt = verdictAt
    }

    var topCandidate: Candidate? { candidates.first }

    /// The card that was actually in the photo, as far as the user has said.
    var confirmedCardID: Card.ID? {
        switch verdict {
        case .pending, .rejected: nil
        case .correct: topCandidate?.card.id
        case .corrected(let id): id
        }
    }
}

/// A ranked printing with the scores that put it there.
nonisolated struct Candidate: Hashable, Sendable, Codable {
    let card: Card
    let score: Double
    let descriptorScore: Double
    let orientation: CardOrientation
    let codeAgreement: CodeAgreement?

    init(card: Card, score: Double, descriptorScore: Double, orientation: CardOrientation, codeAgreement: CodeAgreement?) {
        self.card = card
        self.score = score
        self.descriptorScore = descriptorScore
        self.orientation = orientation
        self.codeAgreement = codeAgreement
    }

    init(_ match: Match) {
        self.init(card: match.card, score: match.score, descriptorScore: match.descriptorScore, orientation: match.orientation, codeAgreement: match.codeAgreement)
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
        case pending, correct, corrected, rejected
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .pending: self = .pending
        case .correct: self = .correct
        case .corrected: self = .corrected(try container.decode(Card.ID.self, forKey: .cardID))
        case .rejected: self = .rejected(try container.decode(RejectionReason.self, forKey: .reason))
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
