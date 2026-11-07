import Foundation
import RiftboundRecognizer

/// Everything the scanner's index does not know about a printing: rules text,
/// domains, stats, tags, TCGplayer product ids and a snapshot of market
/// prices. Extracted from Luke's Card Vault page and bundled as
/// `CardVault.json`; the live price feed updates the prices.
nonisolated struct VaultCard: Hashable, Sendable, Codable, Identifiable {
    /// The vault's printing code, e.g. `OGN-066a`, `RAD-SP1`, `OGN-066-P` (a promo).
    let code: String
    let name: String
    let set: String
    let setName: String
    let rarity: String
    let type: String?
    let supertype: String?
    let domains: [String]
    let energy: Int?
    let might: Int?
    let power: Int?
    let text: String?
    let flavor: String?
    let tags: [String]
    let tcgplayerID: Int?
    /// TCGplayer market prices as of the vault's snapshot date.
    let marketNormal: Double?
    let marketFoil: Double?
    let hasNormal: Bool
    let hasFoil: Bool
    let promo: Bool
    let banned: Bool
    let cardmarketURL: URL?
    let image: URL

    var id: String { code }

    /// The code without its denominator, the key shared with the index's
    /// `PrintedCode`. Promo and special suffixes keep the raw code so they
    /// never collide with the base printing.
    var key: String {
        guard code.wholeMatch(of: #/[A-Z]{3}-[A-Z]{0,2}[0-9]{1,3}[aA*]?/#) != nil, let parsed = PrintedCode(parsing: code) else {
            return code
        }
        return parsed.key
    }

    var tcgplayerURL: URL? {
        tcgplayerID.flatMap { URL(string: "https://www.tcgplayer.com/product/\($0)") }
    }
}

nonisolated extension PrintedCode {
    /// Set, number and variant with no denominator: `OGN-066a`.
    var key: String { "\(set.rawValue)-\(number.rawValue)\(variant.rawValue)" }
}

/// The bundled vault, keyed for joining with the index.
nonisolated struct CardVault: Sendable {
    let asOf: Date
    let cards: [VaultCard]
    private let byKey: [String: VaultCard]

    init(asOf: Date, cards: [VaultCard]) {
        self.asOf = asOf
        self.cards = cards
        byKey = Dictionary(cards.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }

    static let empty = CardVault(asOf: .distantPast, cards: [])

    subscript(key: String) -> VaultCard? { byKey[key] }

    subscript(card: Card) -> VaultCard? { byKey[card.code.key] }

    private struct File: Decodable {
        let asOf: String
        let cards: [VaultCard]
    }

    /// Decodes the bundled file; about a megabyte, so it runs off the main actor.
    @concurrent
    static func read(from url: URL) async throws -> CardVault {
        let file = try JSONDecoder().decode(File.self, from: try Data(contentsOf: url))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return CardVault(asOf: formatter.date(from: file.asOf) ?? .distantPast, cards: file.cards)
    }
}
