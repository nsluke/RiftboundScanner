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
