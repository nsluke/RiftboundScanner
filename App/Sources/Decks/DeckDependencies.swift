import Foundation
import SwiftUI

/// What the Decks feature needs from the composition root: the server, the
/// discovery it checks before offering a write, the offline cache and a
/// clock. Wired once in `AppDependencies.live()` and handed down by `init`
/// (and, for the card sheet, through the SwiftUI environment).
nonisolated struct DeckDependencies: Sendable {
    let client: any CollectionServing
    let endpoints: any EndpointResolving
    let cache: any DeckCacheStoring
    let now: @Sendable () -> Date

    init(client: any CollectionServing, endpoints: any EndpointResolving, cache: any DeckCacheStoring, now: @escaping @Sendable () -> Date) {
        self.client = client
        self.endpoints = endpoints
        self.cache = cache
        self.now = now
    }

    @MainActor
    func makeDetailModel(for summary: DeckSummary) -> DeckDetailModel {
        DeckDetailModel(deckID: summary.id, name: summary.name, client: client, cache: cache, now: now)
    }

    @MainActor
    func makeAddToDeckModel(for card: VaultCard) -> AddToDeckModel {
        AddToDeckModel(card: card, client: client, endpoints: endpoints, cache: cache, now: now)
    }
}

extension EnvironmentValues {
    /// Set by `RootView` on the tabs that can add a card to a deck; `nil`
    /// (the default) hides the action, so a card sheet shown without the
    /// server wiring is still a complete screen.
    @Entry var deckDependencies: DeckDependencies?
}
