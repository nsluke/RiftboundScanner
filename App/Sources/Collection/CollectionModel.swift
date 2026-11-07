import Foundation
import RiftboundRecognizer

/// The user's cards: every confirmed scan across every batch, counted per
/// printing and joined with the vault and the price feed.
@Observable
final class CollectionModel {
    private(set) var owned: Loadable<[String: Int], ScanProblem> = .idle
    private(set) var prices: Loadable<PriceSheet, PriceSourceError> = .idle
    /// Every printing in the vault with the user's count and current price;
    /// rebuilt when counts or prices change, not on every read.
    private(set) var entries: [CollectionEntry] = []
    var filter = CollectionFilter()

    let vault: CardVault
    private let store: any ScanStoring
    private let directory: CardDirectory
    private let priceSource: any PriceQuoting
    private let cardsByKey: [String: Card]

    init(store: any ScanStoring, directory: CardDirectory, vault: CardVault, priceSource: any PriceQuoting) {
        self.store = store
        self.directory = directory
        self.vault = vault
        self.priceSource = priceSource
        cardsByKey = Dictionary(directory.cards.map { ($0.code.key, $0) }, uniquingKeysWith: { first, _ in first })
        rebuildEntries()
    }

    private func rebuildEntries() {
        let counts = owned.value ?? [:]
        let sheet = prices.value
        entries = vault.cards.map { vaultCard in
            let live = vaultCard.tcgplayerID.flatMap { sheet?[$0] }
            return CollectionEntry(
                vault: vaultCard,
                card: cardsByKey[vaultCard.key],
                quantity: counts[vaultCard.key] ?? 0,
                normalPrice: live?.normal ?? vaultCard.marketNormal,
                foilPrice: live?.foil ?? vaultCard.marketFoil
            )
        }
    }

    var shown: [CollectionEntry] { filter.apply(to: entries) }

    var totals: CollectionTotals { CollectionTotals(shown) }

    var ownedTotals: CollectionTotals { CollectionTotals(entries.filter { $0.quantity > 0 }) }

    /// When the prices on screen were fetched, or the vault's snapshot date.
    var pricesAsOf: Date { prices.value?.fetchedAt ?? vault.asOf }

    var availableSets: [(code: String, name: String)] {
        var seen: Set<String> = []
        return vault.cards.compactMap { seen.insert($0.set).inserted ? ($0.set, $0.setName) : nil }
    }

    var availableTypes: [String] {
        Array(Set(vault.cards.compactMap(\.type))).sorted()
    }

    static let rarities = ["Common", "Uncommon", "Rare", "Epic", "Showcase"]
    static let domains = ["Fury", "Calm", "Mind", "Body", "Chaos", "Order", "Colorless"]

    // MARK: - Loading

    func load() async {
        async let ownedLoad: Void = loadOwned()
        async let priceLoad: Void = loadPrices(force: false)
        _ = await (ownedLoad, priceLoad)
    }

    func refreshPrices() async {
        await loadPrices(force: true)
    }

    private func loadOwned() async {
        if case .loaded = owned {} else { owned = .loading }
        do {
            var counts: [String: Int] = [:]
            for batch in try await store.batches() {
                for record in try await store.records(in: batch.id) {
                    guard let id = record.confirmedCardID, let card = directory[id] else { continue }
                    counts[card.code.key, default: 0] += 1
                }
            }
            owned = .loaded(counts)
            rebuildEntries()
        } catch {
            owned = .failed(.storage(String(describing: error)))
        }
    }

    private func loadPrices(force: Bool) async {
        if case .loaded = prices, !force { return }
        prices = .loading
        do {
            prices = .loaded(try await priceSource.quotes(maxAge: force ? .zero : .hours(12)))
            rebuildEntries()
        } catch let error as PriceSourceError {
            prices = .failed(error)
        } catch {
            prices = .failed(.malformed(String(describing: error)))
        }
    }
}

nonisolated extension Duration {
    static func hours(_ hours: Int) -> Duration { .seconds(hours * 3600) }
}
