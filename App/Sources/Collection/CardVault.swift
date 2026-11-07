import Foundation
import RiftboundRecognizer

/// Everything the scanner's index does not know about a printing: rules text,
/// domains, stats, tags, TCGplayer product ids and a snapshot of market
/// prices. Extracted from Luke's Card Vault page and bundled as
/// `CardVault.json`, the cold-start seed; the server's `GET /api/catalog`
/// replaces it and `GET /api/prices/latest` updates the prices (ADR-002,
/// decision 10).
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
    /// Reference art, from the bundled file only: the server never serves
    /// art (decision 15), so a printing it knows and the bundle does not has none.
    let image: URL?

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

    init(
        code: String, name: String, set: String, setName: String, rarity: String, type: String?, supertype: String?,
        domains: [String], energy: Int?, might: Int?, power: Int?, text: String?, flavor: String?, tags: [String], tcgplayerID: Int?,
        marketNormal: Double?, marketFoil: Double?, hasNormal: Bool, hasFoil: Bool, promo: Bool, banned: Bool,
        cardmarketURL: URL?, image: URL?
    ) {
        self.code = code
        self.name = name
        self.set = set
        self.setName = setName
        self.rarity = rarity
        self.type = type
        self.supertype = supertype
        self.domains = domains
        self.energy = energy
        self.might = might
        self.power = power
        self.text = text
        self.flavor = flavor
        self.tags = tags
        self.tcgplayerID = tcgplayerID
        self.marketNormal = marketNormal
        self.marketFoil = marketFoil
        self.hasNormal = hasNormal
        self.hasFoil = hasFoil
        self.promo = promo
        self.banned = banned
        self.cardmarketURL = cardmarketURL
        self.image = image
    }

    /// A server catalog row, with the art and Cardmarket link of the bundled
    /// row for the same code (the server carries neither).
    init(_ card: CatalogCard, art bundled: VaultCard?) {
        code = card.code
        name = card.name
        set = card.set
        setName = card.setName
        rarity = card.rarity
        type = card.type
        supertype = card.supertype
        domains = card.domains
        energy = card.energy
        might = card.might
        power = card.power
        text = card.text
        flavor = card.flavor
        tags = card.tags
        tcgplayerID = card.tcgplayerID
        marketNormal = card.marketNormal
        marketFoil = card.marketFoil
        hasNormal = card.hasNormal
        hasFoil = card.hasFoil
        promo = card.promo
        banned = card.banned
        cardmarketURL = bundled?.cardmarketURL
        image = bundled?.image
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

    /// The row with exactly this vault code (`card_id` on the server).
    func card(code: String) -> VaultCard? { byCode[code] }

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
        return CardVault(asOf: date(fromDay: file.asOf) ?? .distantPast, cards: file.cards)
    }

    /// A `YYYY-MM-DD` day (the vault's `asOf`, the server's `as_of` and price
    /// `day`) as midnight UTC; `nil` for anything else.
    static func date(fromDay day: String?) -> Date? {
        guard let day else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: day)
    }
}
