import Foundation

/// Whether the server can take a deck write right now. Decks are edited on
/// the server only (ADR-002 §5.5), so there is no queue: offline means the
/// action is disabled, with the reason.
nonisolated enum DeckWriteAvailability: Hashable, Sendable {
    case checking
    case online(ServerEndpoint)
    case offline(EndpointUnavailability)

    var isOnline: Bool {
        if case .online = self { return true }
        return false
    }
}

/// The "Add to deck" sheet: pick a deck, confirm the slot (pre-filled from
/// the card's type) and how many copies the deck should hold, then
/// `PUT /api/decks/{id}/cards`. The server answers with the refreshed deck.
@Observable
final class AddToDeckModel: Identifiable {
    let card: VaultCard
    /// The deck list, shared with the Decks tab's logic (and its cache).
    let decks: DecksModel

    private(set) var availability: DeckWriteAvailability = .checking
    private(set) var selectedDeckID: Int?
    /// The chosen deck in full, for the copies it already holds.
    private(set) var selectedDeck: Loadable<DeckDetail, ServerError> = .idle
    private(set) var submission: Loadable<DeckDetail, ServerError> = .idle

    /// Where the card goes; `DeckSlot.defaultSlot(for:)` until the user changes it.
    var slot: DeckSlot {
        didSet { quantity = existingQuantity + 1 }
    }

    /// The copies the deck should hold in `slot` after the change.
    var quantity: Int

    static let quantityRange = 1...99

    private let client: any CollectionServing
    private let endpoints: any EndpointResolving
    private let cache: any DeckCacheStoring
    private let now: @Sendable () -> Date

    init(card: VaultCard, client: any CollectionServing, endpoints: any EndpointResolving, cache: any DeckCacheStoring, now: @escaping @Sendable () -> Date) {
        self.card = card
        self.client = client
        self.endpoints = endpoints
        self.cache = cache
        self.now = now
        slot = DeckSlot.defaultSlot(for: card)
        quantity = 1
        decks = DecksModel(client: client, cache: cache, now: now)
    }

    var id: ObjectIdentifier { ObjectIdentifier(self) }

    /// Checks the server is reachable and loads the decks. The first deck
    /// (the most recently edited) is pre-selected so adding is one tap.
    func load() async {
        availability = .checking
        async let resolution = endpoints.resolve()
        async let listLoad: Void = decks.load()
        switch await resolution {
        case .available(let endpoint, _): availability = .online(endpoint)
        case .unavailable(let reason): availability = .offline(reason)
        }
        await listLoad
        if selectedDeckID == nil, let first = decks.decks.value?.decks.first {
            await select(deckID: first.id)
        }
    }

    /// Forgets the resolved endpoint and probes again.
    func retryConnection() async {
        await endpoints.invalidate()
        await load()
    }

    func select(deckID: Int) async {
        guard selectedDeckID != deckID || selectedDeck.value == nil else { return }
        selectedDeckID = deckID
        submission = .idle
        selectedDeck = .loading
        do {
            selectedDeck = .loaded(try await client.deck(id: deckID))
        } catch {
            let stored = await cache.load()
            if let cached = stored.details[deckID] {
                selectedDeck = .loaded(cached.deck)
            } else {
                selectedDeck = .failed(error)
            }
        }
        quantity = existingQuantity + 1
    }

    /// Copies of this card already in the chosen deck's `slot`.
    var existingQuantity: Int {
        selectedDeck.value?.cards.first { $0.cardID == card.code && $0.slot == slot }?.quantity ?? 0
    }

    var isSubmitting: Bool {
        if case .loading = submission { return true }
        return false
    }

    /// The write needs the server, a chosen deck and a sensible quantity.
    var canSubmit: Bool {
        availability.isOnline && selectedDeckID != nil && Self.quantityRange.contains(quantity) && !isSubmitting
    }

    /// Why the action is disabled, when it is because of the network.
    var offlineMessage: String? {
        guard case .offline(let reason) = availability else { return nil }
        return reason.message + " " + String(localized: "Decks are edited on the server, so adding a card needs Wi-Fi or your home VPN.")
    }

    func submit() async {
        guard canSubmit, let deckID = selectedDeckID else { return }
        submission = .loading
        do {
            let refreshed = try await client.setDeckCard(deckID: deckID, DeckCardChange(cardID: card.code, slot: slot, quantity: quantity))
            submission = .loaded(refreshed)
            selectedDeck = .loaded(refreshed)
            var stored = await cache.load()
            stored.details[deckID] = DeckCache.Detail(deck: refreshed, export: stored.details[deckID]?.export, fetchedAt: now())
            try? await cache.save(stored)
            await decks.load()
        } catch {
            submission = .failed(error)
        }
    }
}
