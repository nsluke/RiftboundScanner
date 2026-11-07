import Foundation
import RiftboundRecognizer

/// One printing as the collection screen shows it: the vault's facts, the
/// index's card when there is one, how many the user owns by finish (the
/// server's count), what this phone still owes the ledger for it, and what
/// it is worth.
nonisolated struct CollectionEntry: Hashable, Sendable, Identifiable {
    let vault: VaultCard
    let card: Card?
    /// The server's ledger count, by finish.
    let owned: OwnedCount
    /// Net unacknowledged change this phone owes the ledger ("+N pending").
    let pending: Int
    /// The server's latest prices when it has them, else the vault's snapshot.
    let normalPrice: Double?
    let foilPrice: Double?

    init(vault: VaultCard, card: Card?, owned: OwnedCount, pending: Int = 0, normalPrice: Double?, foilPrice: Double?) {
        self.vault = vault
        self.card = card
        self.owned = owned
        self.pending = pending
        self.normalPrice = normalPrice
        self.foilPrice = foilPrice
    }

    /// A count with no finish split (filters, previews).
    init(vault: VaultCard, card: Card?, quantity: Int, normalPrice: Double?, foilPrice: Double?) {
        self.init(vault: vault, card: card, owned: OwnedCount(normal: quantity, foil: 0), normalPrice: normalPrice, foilPrice: foilPrice)
    }

    var id: String { vault.id }

    /// How many the server says the user owns, both finishes.
    var quantity: Int { owned.total }

    /// The price to show and sort by: normal where the printing has a normal
    /// finish and a price, else foil (showcase and promo printings are foil only).
    var bestPrice: Double? {
        if vault.hasNormal, let normalPrice { return normalPrice }
        return foilPrice
    }

    var value: Double { (bestPrice ?? 0) * Double(quantity) }

    /// Art for the cell: the index's Riot URL when the scanner knows the
    /// printing, else the vault's; `nil` for a printing only the server knows.
    var artURL: URL? { card?.imageURL ?? vault.image }
}

/// What the collection screen is narrowed to. A pure value so it can be
/// tested without a view.
nonisolated struct CollectionFilter: Hashable, Sendable {
    enum Sort: Hashable, Sendable, CaseIterable {
        case setAndNumber
        case name
        case priceDescending
        case priceAscending
        case rarity
        case quantity

        var label: String {
            switch self {
            case .setAndNumber: String(localized: "Set & number")
            case .name: String(localized: "Name A–Z")
            case .priceDescending: String(localized: "Price, high to low")
            case .priceAscending: String(localized: "Price, low to high")
            case .rarity: String(localized: "Rarity")
            case .quantity: String(localized: "Most owned")
            }
        }
    }

    var query = ""
    /// Also match the query against rules text.
    var searchesText = false
    var sets: Set<String> = []
    var rarities: Set<String> = []
    var types: Set<String> = []
    var domains: Set<String> = []
    var minimumPrice: Double?
    var maximumPrice: Double?
    /// Show only printings the user owns; off, the whole catalog shows with counts.
    var ownedOnly = true
    var includesPromos = true
    var pricedOnly = false
    var hidesBanned = false
    var sort: Sort = .setAndNumber

    static let rarityRank = ["Common": 0, "Uncommon": 1, "Rare": 2, "Epic": 3, "Showcase": 4]

    /// Anything narrowing the list beyond owned-only, for the filter badge.
    var activeCount: Int {
        var count = 0
        if !sets.isEmpty { count += 1 }
        if !rarities.isEmpty { count += 1 }
        if !types.isEmpty { count += 1 }
        if !domains.isEmpty { count += 1 }
        if minimumPrice != nil || maximumPrice != nil { count += 1 }
        if !includesPromos { count += 1 }
        if pricedOnly { count += 1 }
        if hidesBanned { count += 1 }
        return count
    }

    func apply(to entries: [CollectionEntry]) -> [CollectionEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return entries.filter { entry in
            let vault = entry.vault
            // A printing only pending counts as "mine": the chip is the point.
            if ownedOnly, entry.quantity == 0, entry.pending <= 0 { return false }
            if !includesPromos, vault.promo { return false }
            if hidesBanned, vault.banned { return false }
            if pricedOnly, entry.bestPrice == nil { return false }
            if !sets.isEmpty, !sets.contains(vault.set) { return false }
            if !rarities.isEmpty, !rarities.contains(vault.rarity) { return false }
            if !types.isEmpty, !types.contains(vault.type ?? "") { return false }
            if !domains.isEmpty, !vault.domains.contains(where: domains.contains) { return false }
            if let minimumPrice, (entry.bestPrice ?? -1) < minimumPrice { return false }
            if let maximumPrice, (entry.bestPrice ?? .infinity) > maximumPrice { return false }
            if !needle.isEmpty {
                let haystack = [vault.name, vault.code, vault.tags.joined(separator: " "), searchesText ? vault.text ?? "" : ""].joined(separator: " ")
                if !haystack.localizedCaseInsensitiveContains(needle) { return false }
            }
            return true
        }
        .sorted(by: comparator)
    }

    private var comparator: (CollectionEntry, CollectionEntry) -> Bool {
        let bySet = Self.bySetAndNumber
        return switch sort {
        case .setAndNumber: bySet
        case .name: { lhs, rhs in
            let order = lhs.vault.name.localizedCaseInsensitiveCompare(rhs.vault.name)
            return order == .orderedSame ? bySet(lhs, rhs) : order == .orderedAscending
        }
        case .priceDescending: { lhs, rhs in
            switch (lhs.bestPrice, rhs.bestPrice) {
            case let (l?, r?) where l != r: return l > r
            case (.some, .none): return true
            case (.none, .some): return false
            default: return bySet(lhs, rhs)
            }
        }
        case .priceAscending: { lhs, rhs in
            switch (lhs.bestPrice, rhs.bestPrice) {
            case let (l?, r?) where l != r: return l < r
            case (.some, .none): return true
            case (.none, .some): return false
            default: return bySet(lhs, rhs)
            }
        }
        case .rarity: { lhs, rhs in
            let l = Self.rarityRank[lhs.vault.rarity] ?? -1, r = Self.rarityRank[rhs.vault.rarity] ?? -1
            return l != r ? l > r : bySet(lhs, rhs)
        }
        case .quantity: { lhs, rhs in
            lhs.quantity != rhs.quantity ? lhs.quantity > rhs.quantity : bySet(lhs, rhs)
        }
        }
    }

    private static func bySetAndNumber(_ lhs: CollectionEntry, _ rhs: CollectionEntry) -> Bool {
        if lhs.vault.set != rhs.vault.set { return lhs.vault.set < rhs.vault.set }
        return lhs.vault.code.compare(rhs.vault.code, options: .numeric) == .orderedAscending
    }
}

/// The headline numbers over a filtered list.
nonisolated struct CollectionTotals: Hashable, Sendable {
    let printings: Int
    let cards: Int
    let value: Double

    init(_ entries: [CollectionEntry]) {
        printings = entries.count
        cards = entries.reduce(0) { $0 + $1.quantity }
        value = entries.reduce(0) { $0 + $1.value }
    }
}
