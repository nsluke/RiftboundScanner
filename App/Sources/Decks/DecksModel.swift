import Foundation

/// Where what is on screen came from, so a screen can say so.
nonisolated enum DeckFreshness: Hashable, Sendable {
    /// Fetched from the server during this load.
    case live
    /// The server could not be reached; this is the copy saved at `asOf`.
    case cached(asOf: Date, reason: ServerError)

    var isCached: Bool {
        if case .cached = self { return true }
        return false
    }
}

nonisolated struct DeckListing: Hashable, Sendable {
    let decks: [DeckSummary]
    let freshness: DeckFreshness
}

/// The Decks tab: the server's deck list, or the cached list with a reason
/// when the server is out of reach, or a failure with retry when there is
/// nothing to show.
@Observable
final class DecksModel {
    private(set) var decks: Loadable<DeckListing, ServerError> = .idle

    private let client: any CollectionServing
    private let cache: any DeckCacheStoring
    private let now: @Sendable () -> Date

    init(client: any CollectionServing, cache: any DeckCacheStoring, now: @escaping @Sendable () -> Date) {
        self.client = client
        self.cache = cache
        self.now = now
    }

    /// Fetches the list conditionally on the cached validator. A loaded list
    /// stays on screen while it refreshes; only a first load shows a spinner.
    func load() async {
        if case .loaded = decks {} else { decks = .loading }
        let stored = await cache.load()
        do {
            let page = try await client.decks(ifNoneMatch: stored.listing?.validator)
            decks = .loaded(DeckListing(decks: page.value, freshness: .live))
            var updated = stored
            updated.listing = DeckCache.Listing(decks: page.value, validator: page.validator, fetchedAt: now())
            try? await cache.save(updated)
        } catch {
            if let listing = stored.listing {
                decks = .loaded(DeckListing(decks: listing.decks, freshness: .cached(asOf: listing.fetchedAt, reason: error)))
            } else {
                decks = .failed(error)
            }
        }
    }

    var isLoading: Bool {
        if case .loading = decks { return true }
        return false
    }
}
