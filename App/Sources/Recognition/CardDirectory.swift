import Foundation
import RiftboundRecognizer

/// Every printing the index knows, for lookups and the correction picker.
nonisolated struct CardDirectory: Sendable {
    /// Sorted by set, then collector number, then variant.
    let cards: [Card]
    private let byID: [Card.ID: Card]

    init(cards: [Card]) {
        self.cards = cards.sorted { lhs, rhs in
            if lhs.code.set != rhs.code.set { return lhs.code.set < rhs.code.set }
            if lhs.code.number.digits != rhs.code.number.digits { return lhs.code.number.digits < rhs.code.number.digits }
            return lhs.code.canonical < rhs.code.canonical
        }
        byID = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    init(index: CardIndex) {
        self.init(cards: index.entries.map(\.card))
    }

    subscript(id: Card.ID) -> Card? {
        byID[id]
    }

    /// Every set in the index, in code order.
    var sets: [SetCode] {
        var seen: Set<SetCode> = []
        return cards.compactMap { seen.insert($0.code.set).inserted ? $0.code.set : nil }
    }

    /// Printings in `set` whose collector number matches `numberText` as typed:
    /// digits compare by value (`7`, `07` and `007` agree) and any letter prefix
    /// must match exactly. Several printings can share a number (standard,
    /// alternate art, signature), in catalog order.
    func cards(in set: SetCode, number numberText: String) -> [Card] {
        let trimmed = numberText.trimmingCharacters(in: .whitespaces).uppercased()
        guard let typed = CollectorNumber(rawValue: trimmed) else { return [] }
        return cards.filter { $0.code.set == set && $0.code.number.prefix == typed.prefix && $0.code.number.digits == typed.digits }
    }

    /// Cards whose name or printed code contains `query`, ignoring case; every
    /// card when the query is blank.
    func matching(_ query: String) -> [Card] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return cards }
        return cards.filter { card in
            card.displayName.localizedCaseInsensitiveContains(trimmed)
                || card.code.canonical.localizedCaseInsensitiveContains(trimmed)
                || card.code.canonical.replacingOccurrences(of: "-", with: " ").localizedCaseInsensitiveContains(trimmed)
        }
    }
}
