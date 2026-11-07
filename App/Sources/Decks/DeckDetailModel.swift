import Foundation

/// One slot of a deck as the detail screen lists it.
nonisolated struct DeckSlotSection: Hashable, Sendable, Identifiable {
    let slot: DeckSlot
    let cards: [DeckCard]
    /// The server's count for the slot (quantities summed).
    let count: Int

    var id: DeckSlot { slot }
    var title: String { slot.title }
}

/// A deck as loaded, with where it came from.
nonisolated struct LoadedDeck: Hashable, Sendable {
    let deck: DeckDetail
    let freshness: DeckFreshness

    /// Every known slot in builder order, then any slot this app does not
    /// know, so nothing the server stores is hidden.
    var sections: [DeckSlotSection] {
        var slots = DeckSlot.allCases
        for card in deck.cards where !slots.contains(card.slot) {
            slots.append(card.slot)
        }
        return slots.map { slot in
            let cards = deck.cards(in: slot)
            return DeckSlotSection(slot: slot, cards: cards, count: deck.counts[slot] ?? cards.reduce(0) { $0 + $1.quantity })
        }
    }
}

/// One deck: its cards per slot with the server's owned/short arithmetic,
/// the validation verdict, and the Piltover text for sharing.
@Observable
final class DeckDetailModel {
    let deckID: Int
    /// From the list row, so the title shows before the detail arrives.
    let name: String

    private(set) var deck: Loadable<LoadedDeck, ServerError> = .idle
    /// The Piltover Archive text from `GET /api/decks/{id}/export?style=piltover`.
    private(set) var export: Loadable<String, ServerError> = .idle

    private let client: any CollectionServing
    private let cache: any DeckCacheStoring
    private let now: @Sendable () -> Date

    init(deckID: Int, name: String, client: any CollectionServing, cache: any DeckCacheStoring, now: @escaping @Sendable () -> Date) {
        self.deckID = deckID
        self.name = name
        self.client = client
        self.cache = cache
        self.now = now
    }

    /// The deck lacks this many copies, as the server computed it.
    var shortCount: Int? { deck.value?.deck.shortCount }

    /// Fetches the deck and its share text together. A failed export never
    /// fails the deck; the share button just stays away.
    func load() async {
        if case .loaded = deck {} else { deck = .loading }
        if case .loaded = export {} else { export = .loading }
        let stored = await cache.load()
        async let detailResult = fetchDetail()
        async let exportResult = fetchExport()
        let (detail, text) = await (detailResult, exportResult)
        switch detail {
        case .success(let fetched):
            deck = .loaded(LoadedDeck(deck: fetched, freshness: .live))
            switch text {
            case .success(let value): export = .loaded(value)
            case .failure(let error): export = .failed(error)
            }
            var updated = stored
            updated.details[deckID] = DeckCache.Detail(deck: fetched, export: try? text.get(), fetchedAt: now())
            try? await cache.save(updated)
        case .failure(let error):
            if let cached = stored.details[deckID] {
                deck = .loaded(LoadedDeck(deck: cached.deck, freshness: .cached(asOf: cached.fetchedAt, reason: error)))
                if case .success(let value) = text {
                    export = .loaded(value)
                } else if let saved = cached.export {
                    export = .loaded(saved)
                } else {
                    export = .failed(error)
                }
            } else {
                deck = .failed(error)
                export = .failed(error)
            }
        }
    }

    private func fetchDetail() async -> Result<DeckDetail, ServerError> {
        do {
            return .success(try await client.deck(id: deckID))
        } catch {
            return .failure(error)
        }
    }

    private func fetchExport() async -> Result<String, ServerError> {
        do {
            return .success(try await client.deckExport(id: deckID, style: .piltover))
        } catch {
            return .failure(error)
        }
    }
}
