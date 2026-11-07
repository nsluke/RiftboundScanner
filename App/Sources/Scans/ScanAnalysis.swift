import Foundation
import RiftboundRecognizer

/// What the recogniser computed for a scan, kept so the learning loop can use
/// the scan without re-running Vision: the winning oriented descriptor, where
/// the card was, which code it read and from where, and a shortlist of
/// candidates by id. No card images or URLs live here (ADR-002, decision 15);
/// the `candidates` list on the record keeps the catalog rows for the UI.
nonisolated struct ScanAnalysis: Hashable, Sendable, Codable {
    static let shortlistLimit = 12

    /// The query descriptor in the orientation of the winning match; the one
    /// to compare with a reference or keep as an exemplar.
    let descriptor: OrientedDescriptor
    /// The card's corners in the photo, `nil` when the whole image was used.
    let quad: CardQuad?
    /// Where the winning code came from; `nil` when no code was read.
    let codeSource: CodeSource?
    /// The literal OCR reading and every parser alternative, in rank order.
    let codeAlternatives: [CodeAlternative]
    /// Up to `shortlistLimit` candidates, best first.
    let shortlist: [ShortlistEntry]
    /// The same-run scan this one appears to repeat (ADR-002, decision 16).
    let duplicateOf: ScanRecord.ID?
    let analyzedAt: Date

    init(
        descriptor: OrientedDescriptor,
        quad: CardQuad?,
        codeSource: CodeSource?,
        codeAlternatives: [CodeAlternative],
        shortlist: [ShortlistEntry],
        duplicateOf: ScanRecord.ID? = nil,
        analyzedAt: Date
    ) {
        self.descriptor = descriptor
        self.quad = quad
        self.codeSource = codeSource
        self.codeAlternatives = codeAlternatives
        self.shortlist = Array(shortlist.prefix(Self.shortlistLimit))
        self.duplicateOf = duplicateOf
        self.analyzedAt = analyzedAt
    }

    /// Everything a recognition result says, stamped `at`.
    init(_ result: RecognitionResult, at analyzedAt: Date) {
        self.init(
            descriptor: result.descriptor,
            quad: result.quad,
            codeSource: result.codeReading?.source,
            codeAlternatives: result.codeReading.map { [CodeAlternative(code: $0.code, origin: .literal)] } ?? [],
            shortlist: result.matches.prefix(Self.shortlistLimit).map(ShortlistEntry.init),
            analyzedAt: analyzedAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case descriptor, quad, codeSource, codeAlternatives, shortlist, duplicateOf, analyzedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            descriptor: try container.decode(OrientedDescriptor.self, forKey: .descriptor),
            quad: try container.decodeIfPresent(CardQuad.self, forKey: .quad),
            codeSource: try container.decodeIfPresent(CodeSource.self, forKey: .codeSource),
            codeAlternatives: try container.decodeIfPresent([CodeAlternative].self, forKey: .codeAlternatives) ?? [],
            shortlist: try container.decodeIfPresent([ShortlistEntry].self, forKey: .shortlist) ?? [],
            duplicateOf: try container.decodeIfPresent(ScanRecord.ID.self, forKey: .duplicateOf),
            analyzedAt: try container.decode(Date.self, forKey: .analyzedAt)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(descriptor, forKey: .descriptor)
        try container.encodeIfPresent(quad, forKey: .quad)
        try container.encodeIfPresent(codeSource, forKey: .codeSource)
        try container.encode(codeAlternatives, forKey: .codeAlternatives)
        try container.encode(shortlist, forKey: .shortlist)
        try container.encodeIfPresent(duplicateOf, forKey: .duplicateOf)
        try container.encode(analyzedAt, forKey: .analyzedAt)
    }
}

/// A code the OCR pass offered: the literal reading, or one of the parser's
/// repairs of it (`1` <-> `2`, `7` <-> `1`). At upload time each one gains a
/// reference similarity so the admission gate can see the margin between them.
nonisolated struct CodeAlternative: Hashable, Sendable, Codable {
    enum Origin: String, Hashable, Sendable, Codable {
        /// Exactly what was read.
        case literal
        /// A repair the parser proposed.
        case alternative
    }

    let code: PrintedCode
    let origin: Origin

    init(code: PrintedCode, origin: Origin) {
        self.code = code
        self.origin = origin
    }
}

/// One shortlisted printing, by id only.
nonisolated struct ShortlistEntry: Hashable, Sendable, Codable {
    let cardID: Card.ID
    /// Descriptor score plus the OCR adjustment, the ranking score.
    let score: Double
    /// Descriptor similarity to the bundled reference alone.
    let referenceScore: Double
    /// Reference score or, when an exemplar of this art is closer, that similarity.
    let fusedScore: Double
    let components: ScoreComponents
    let orientation: CardOrientation
    let codeAgreement: CodeAgreement?
    /// Similarity to the best learned exemplar of this printing's art, when one exists.
    let exemplarSimilarity: Double?

    init(
        cardID: Card.ID,
        score: Double,
        referenceScore: Double,
        fusedScore: Double,
        components: ScoreComponents,
        orientation: CardOrientation,
        codeAgreement: CodeAgreement?,
        exemplarSimilarity: Double? = nil
    ) {
        self.cardID = cardID
        self.score = score
        self.referenceScore = referenceScore
        self.fusedScore = fusedScore
        self.components = components
        self.orientation = orientation
        self.codeAgreement = codeAgreement
        self.exemplarSimilarity = exemplarSimilarity
    }

    /// Until the recogniser blends exemplars in, reference and fused scores
    /// are both the match's descriptor score.
    init(_ match: Match) {
        self.init(
            cardID: match.card.id,
            score: match.score,
            referenceScore: match.descriptorScore,
            fusedScore: match.descriptorScore,
            components: match.components,
            orientation: match.orientation,
            codeAgreement: match.codeAgreement
        )
    }
}

/// Which recogniser build, embedding and learned data produced a result
/// (ADR-002, decisions 8 and 14). Stored on every record and every evaluation run.
nonisolated struct EngineStamp: Hashable, Sendable, Codable {
    let packageVersion: String
    /// The 16-byte hash of the calibration canvas's feature print, as 32 hex characters.
    let calibrationHash: String
    let platform: String
    let osVersion: String
    /// The learned-exemplar overlay in use, `nil` for the bare index.
    let overlayVersion: Int?
    /// The learning policy in use, `nil` for the built-in defaults.
    let policyVersion: Int?

    init(packageVersion: String, calibrationHash: String, platform: String, osVersion: String, overlayVersion: Int? = nil, policyVersion: Int? = nil) {
        self.packageVersion = packageVersion
        self.calibrationHash = calibrationHash
        self.platform = platform
        self.osVersion = osVersion
        self.overlayVersion = overlayVersion
        self.policyVersion = policyVersion
    }

    init(_ fingerprint: EngineFingerprint, overlayVersion: Int? = nil, policyVersion: Int? = nil) {
        self.init(
            packageVersion: fingerprint.packageVersion,
            calibrationHash: fingerprint.calibrationHash.hex,
            platform: fingerprint.platform,
            osVersion: fingerprint.osVersion,
            overlayVersion: overlayVersion,
            policyVersion: policyVersion
        )
    }
}
