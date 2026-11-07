import Foundation

/// The reference index: one ``Entry`` per printing, built once from the cached
/// reference images and saved as JSON. It embeds the card metadata so
/// recognition needs no catalog at run time.
public struct CardIndex: Sendable, Codable {
    public static let currentFormatVersion = 1

    public struct Entry: Hashable, Sendable, Codable, Identifiable {
        public let card: Card
        public let descriptor: CardDescriptor

        public init(card: Card, descriptor: CardDescriptor) {
            self.card = card
            self.descriptor = descriptor
        }

        public var id: Card.ID { card.id }
    }

    public let formatVersion: Int
    public let canvas: CanvasSpecification
    public let builtAt: Date
    public let entries: [Entry]
    /// The ``CalibrationCanvas`` as printed by the feature printer that produced
    /// the entries; compare it with the device's own calibration print to know
    /// whether the two embed images the same way. Absent from indexes built
    /// before it was recorded (still format version 1).
    public let calibrationPrint: FeaturePrint?

    public init(canvas: CanvasSpecification, builtAt: Date, entries: [Entry], calibrationPrint: FeaturePrint? = nil) {
        self.formatVersion = Self.currentFormatVersion
        self.canvas = canvas
        self.builtAt = builtAt
        self.entries = entries
        self.calibrationPrint = calibrationPrint
    }

    /// The digest of ``calibrationPrint``, the key artefacts in the same
    /// embedding space share.
    public var calibrationHash: FeaturePrint.Digest? { calibrationPrint?.digest }

    /// Every printing's code, as the OCR parser's vocabulary: a reading counts
    /// only when it names one of these (denominator aside) with a denominator
    /// its set prints.
    public var vocabulary: PrintedCodeParser.Vocabulary {
        PrintedCodeParser.Vocabulary(codes: entries.map(\.card.code))
    }

    public static func read(from url: URL) throws -> CardIndex {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let index = try decoder.decode(CardIndex.self, from: try Data(contentsOf: url))
        guard index.formatVersion == currentFormatVersion else {
            throw CardIndexError.unsupportedFormat(found: index.formatVersion, expected: currentFormatVersion)
        }
        return index
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// An index file was written by an incompatible version.
public enum CardIndexError: Error {
    case unsupportedFormat(found: Int, expected: Int)
}
