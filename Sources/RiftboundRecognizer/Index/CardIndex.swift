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

    public init(canvas: CanvasSpecification, builtAt: Date, entries: [Entry]) {
        self.formatVersion = Self.currentFormatVersion
        self.canvas = canvas
        self.builtAt = builtAt
        self.entries = entries
    }

    public var vocabulary: PrintedCodeParser.Vocabulary {
        PrintedCodeParser.Vocabulary(
            sets: Set(entries.map(\.card.code.set)),
            numberPrefixes: Set(entries.map(\.card.code.number.prefix))
        )
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
