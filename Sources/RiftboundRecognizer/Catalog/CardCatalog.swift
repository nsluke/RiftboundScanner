import Foundation

/// The community catalog (`cards.json`) mapped to domain values.
///
/// Records that cannot be represented as a ``Card`` (no printed code, no image
/// URL) are reported in ``skipped`` rather than failing the whole load. The
/// wire format is decoded into private DTOs so catalog field names never leak
/// into the domain model.
public struct CardCatalog: Sendable {
    public struct SkippedRecord: Hashable, Sendable {
        public let id: String
        public let reason: String

        public init(id: String, reason: String) {
            self.id = id
            self.reason = reason
        }
    }

    public let cards: [Card]
    public let skipped: [SkippedRecord]

    public init(cards: [Card], skipped: [SkippedRecord] = []) {
        self.cards = cards
        self.skipped = skipped
    }

    public init(jsonData: Data) throws(CatalogError) {
        let document: CatalogDocument
        do {
            document = try JSONDecoder().decode(CatalogDocument.self, from: jsonData)
        } catch {
            throw .malformed(underlying: error)
        }
        var cards: [Card] = []
        var skipped: [SkippedRecord] = []
        for record in document.cards {
            switch record.card {
            case .success(let card): cards.append(card)
            case .failure(let reason): skipped.append(SkippedRecord(id: record.id, reason: reason.rawValue))
            }
        }
        self.init(cards: cards, skipped: skipped)
    }

    public static func load(from url: URL) throws(CatalogError) -> CardCatalog {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw .unreadable(url, underlying: error)
        }
        return try CardCatalog(jsonData: data)
    }

    public subscript(id: Card.ID) -> Card? {
        cards.first { $0.id == id }
    }

    /// Every set code and collector-number prefix in the catalog; the OCR parser
    /// uses them to repair misread characters.
    public var vocabulary: PrintedCodeParser.Vocabulary {
        PrintedCodeParser.Vocabulary(
            sets: Set(cards.map(\.code.set)),
            numberPrefixes: Set(cards.map(\.code.number.prefix))
        )
    }
}

/// Why a catalog file could not be loaded.
public enum CatalogError: Error {
    case unreadable(URL, underlying: any Error)
    case malformed(underlying: any Error)
}

// MARK: - Wire format

private struct CatalogDocument: Decodable {
    let cards: [CardRecord]
}

private struct CardRecord: Decodable {
    enum SkipReason: String {
        case missingPublicCode = "no public_code"
        case unparseablePublicCode = "unparseable public_code"
        case invalidImageURL = "invalid image url"
    }

    let id: String
    let publicCode: String?
    let name: String
    let displayName: String?
    let set: SetRecord
    let type: String?
    let rarity: String?
    let printing: PrintingRecord?
    let image: ImageRecord
    let orientation: String?

    enum CodingKeys: String, CodingKey {
        case id
        case publicCode = "public_code"
        case name
        case displayName = "display_name"
        case set, type, rarity, printing, image, orientation
    }

    var card: Result<Card, SkipReason> {
        guard let publicCode else { return .failure(.missingPublicCode) }
        guard let code = PrintedCode(parsing: publicCode) else { return .failure(.unparseablePublicCode) }
        guard let imageURL = URL(string: image.url), imageURL.scheme == "https" else { return .failure(.invalidImageURL) }
        var traits: PrintingTraits = []
        if printing?.alternateArt == true { traits.insert(.alternateArt) }
        if printing?.signature == true { traits.insert(.signature) }
        if printing?.overnumbered == true { traits.insert(.overnumbered) }
        return .success(Card(
            id: Card.ID(rawValue: id),
            name: name,
            displayName: displayName ?? name,
            code: code,
            setName: set.name,
            rarity: Rarity(label: rarity ?? ""),
            kind: type.map(Kind.init(label:)),
            printing: traits,
            orientation: resolvedOrientation,
            imageURL: imageURL
        ))
    }

    private var resolvedOrientation: Card.Orientation {
        if let orientation, let explicit = Card.Orientation(rawValue: orientation) {
            return explicit
        }
        if let width = image.width, let height = image.height, width > height {
            return .landscape
        }
        return .portrait
    }
}

extension CardRecord.SkipReason: Error {}

private struct SetRecord: Decodable {
    let id: String
    let name: String
}

private struct PrintingRecord: Decodable {
    let alternateArt: Bool?
    let signature: Bool?
    let overnumbered: Bool?

    enum CodingKeys: String, CodingKey {
        case alternateArt = "alternate_art"
        case signature, overnumbered
    }
}

private struct ImageRecord: Decodable {
    let url: String
    let width: Int?
    let height: Int?
}
