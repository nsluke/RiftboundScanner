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

    /// The identity shared with the index's printings; the raw code for rows
    /// the recogniser can never produce (promos, backs, oversized rows).
    var key: PrintingKey { PrintingKey(vaultCode: code) }

    /// Set and collector number, shared by every printing of one piece of art;
    /// `nil` for oversized `/NNN` rows.
    var artGroupCode: String? { key.artGroupCode }

    var tcgplayerURL: URL? {
        tcgplayerID.flatMap { URL(string: "https://www.tcgplayer.com/product/\($0)") }
    }
}

/// The bundled vault, keyed for joining with the index.
nonisolated struct CardVault: Sendable {
    let asOf: Date
    let cards: [VaultCard]
    private let byKey: [PrintingKey: VaultCard]
    private let byCode: [String: VaultCard]
    /// Rows per art group, in vault order.
    private let byArtGroup: [String: [VaultCard]]

    init(asOf: Date, cards: [VaultCard]) {
        self.asOf = asOf
        self.cards = cards
        byKey = Dictionary(cards.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        byCode = Dictionary(cards.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })
        var groups: [String: [VaultCard]] = [:]
        for card in cards {
            if let group = card.artGroupCode { groups[group, default: []].append(card) }
        }
        byArtGroup = groups
    }

    static let empty = CardVault(asOf: .distantPast, cards: [])

    subscript(key: PrintingKey) -> VaultCard? { byKey[key] }

    subscript(card: Card) -> VaultCard? { byKey[PrintingKey(card.code)] }

    /// The vault's spelling of an index printing (`SFD-227-STAR` for
    /// `sfd-227*-221`), `nil` when the vault has no row for it.
    func vaultCode(for id: Card.ID) -> String? {
        PrintingKey(cardID: id).flatMap { byKey[$0] }?.code
    }

    /// Every printing of the same art as `code`, itself included, in vault
    /// order: same set and collector number with any suffix (`SFD-178`,
    /// `SFD-178a-P`, `SFD-178-P`). Oversized `/NNN` rows never join a group,
    /// so such a row is only its own sibling. Empty for a code the vault lacks.
    func siblings(of code: String) -> [VaultCard] {
        guard let group = PrintingKey(vaultCode: code).artGroupCode else {
            return byCode[code].map { [$0] } ?? []
        }
        return byArtGroup[group] ?? []
    }

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
