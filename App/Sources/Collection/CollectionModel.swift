import Foundation
import RiftboundRecognizer

/// Whether the holdings on screen are the server's current answer or the
/// copy kept from the last time it answered.
nonisolated enum HoldingsFreshness: Hashable, Sendable {
    /// Fetched (or confirmed unchanged) during this load.
    case live
    /// The server could not be reached; this is the snapshot from `fetchedAt`.
    case cached(reason: ServerError)

    var isCached: Bool {
        if case .cached = self { return true }
        return false
    }
}

/// What the Collection knows the user owns: the server's ledger as last
/// seen, and how fresh that is.
nonisolated struct CollectionHoldings: Hashable, Sendable {
    let snapshot: HoldingsSnapshot
    let freshness: HoldingsFreshness
}

/// A line the Collection shows above the grid when something about what it
/// shows needs saying.
nonisolated enum CollectionNotice: Hashable, Sendable, Identifiable {
    /// Counts are the snapshot from `asOf`; pending chips are what this phone
    /// still owes the server.
    case offline(asOf: Date, reason: ServerError)
    /// The server's catalog has printings this build's bundle (and so its
    /// recogniser index) lacks: they can be tracked, not scanned, until the
    /// app is rebuilt (decision 10's new-set order).
    case catalogNewerThanBundle(printings: Int)

    var id: String {
        switch self {
        case .offline: "offline"
        case .catalogNewerThanBundle: "catalog"
        }
    }

    var message: String {
        switch self {
        case .offline(let asOf, let reason):
            String(localized: "Showing your collection as of \(asOf.formatted(date: .abbreviated, time: .shortened)). \(reason.message)")
        case .catalogNewerThanBundle(let printings):
            String(localized: "The server's catalog has \(printings) printings this build cannot scan yet. Rebuild the app with the new index to scan them.")
        }
    }
}

/// The user's cards: the server's holdings (never a count of local scans),
/// what this phone still owes the ledger, joined with the catalog and the
/// latest prices. Offline, the last holdings snapshot stands in; with no
/// snapshot the bundled vault shows with zero counts and a Connect action.
@Observable
final class CollectionModel {
    /// How long a cached price sheet or catalog is trusted before the server
    /// is asked again; a policy value, not a literal in the loaders.
    nonisolated struct Policy: Hashable, Sendable {
        var priceMaxAge: Duration = .hours(12)
        var catalogMaxAge: Duration = .hours(24)

        init(priceMaxAge: Duration = .hours(12), catalogMaxAge: Duration = .hours(24)) {
            self.priceMaxAge = priceMaxAge
            self.catalogMaxAge = catalogMaxAge
        }
    }

    private(set) var holdings: Loadable<CollectionHoldings, ServerError> = .idle
    private(set) var prices: Loadable<PriceSheet, ServerError> = .idle
    private(set) var catalog: CatalogState
    /// Net unacknowledged ledger change per printing.
    private(set) var pending: [PrintingKey: Int] = [:]
    /// Every printing in the vault with the user's count and current price;
    /// rebuilt when counts, pending items, prices or the catalog change.
    private(set) var entries: [CollectionEntry] = []
    var filter = CollectionFilter()

    private let catalogSource: any CatalogSourcing
    private let holdingsSource: any HoldingsSourcing
    private let priceSource: any PriceQuoting
    private let pendingSource: any PendingLedgerProviding
    private let endpoints: any EndpointResolving
    private let directory: CardDirectory
    private let now: @Sendable () -> Date
    private let policy: Policy
    /// The server's `catalog_version` as `/health` last reported it, for
    /// deciding whether the cached catalog is behind.
    private var serverCatalogVersion: String?

    init(
        catalog: any CatalogSourcing,
        holdings: any HoldingsSourcing,
        prices: any PriceQuoting,
        pending: any PendingLedgerProviding,
        endpoints: any EndpointResolving,
        directory: CardDirectory,
        seed: CardVault,
        now: @escaping @Sendable () -> Date,
        policy: Policy = Policy()
    ) {
        catalogSource = catalog
        holdingsSource = holdings
        priceSource = prices
        pendingSource = pending
        self.endpoints = endpoints
        self.directory = directory
        self.now = now
        self.policy = policy
        self.catalog = .bundled(seed)
        rebuildEntries()
    }

    var vault: CardVault { catalog.vault }

    // MARK: - Derived

    private func rebuildEntries() {
        let snapshot = holdings.value?.snapshot
        let sheet = prices.value
        entries = catalog.vault.cards.map { vaultCard in
            let live = sheet?[vaultCard.code]
            return CollectionEntry(
                vault: vaultCard,
                card: directory.card(forKey: vaultCard.key),
                owned: snapshot?[vaultCard.code] ?? .none,
                pending: pending[vaultCard.key] ?? 0,
                normalPrice: live?.normal ?? vaultCard.marketNormal,
                foilPrice: live?.foil ?? vaultCard.marketFoil
            )
        }
    }

    var shown: [CollectionEntry] { filter.apply(to: entries) }

    var totals: CollectionTotals { CollectionTotals(shown) }

    var ownedTotals: CollectionTotals { CollectionTotals(entries.filter { $0.quantity > 0 }) }

    /// Items this phone still owes the ledger, net across every printing.
    var pendingTotal: Int { pending.values.reduce(0, +) }

    /// The day the prices on screen are from, or the vault's snapshot date.
    var pricesAsOf: Date { prices.value?.asOf ?? catalog.vault.asOf }

    /// Whether the server could not be reached and nothing has ever been
    /// fetched: the vault shows with zero counts and a Connect action.
    var isDisconnected: Bool {
        if case .failed = holdings { return true }
        return false
    }

    var notices: [CollectionNotice] {
        var notices: [CollectionNotice] = []
        if case .loaded(let loaded) = holdings, case .cached(let reason) = loaded.freshness {
            notices.append(.offline(asOf: loaded.snapshot.fetchedAt, reason: reason))
        }
        if catalog.printingsNewerThanBundle > 0 {
            notices.append(.catalogNewerThanBundle(printings: catalog.printingsNewerThanBundle))
        }
        return notices
    }

    var availableSets: [(code: String, name: String)] {
        var seen: Set<String> = []
        return catalog.vault.cards.compactMap { seen.insert($0.set).inserted ? ($0.set, $0.setName) : nil }
    }

    var availableTypes: [String] {
        Array(Set(catalog.vault.cards.compactMap(\.type))).sorted()
    }

    static let rarities = ["Common", "Uncommon", "Rare", "Epic", "Showcase"]
    static let domains = ["Fury", "Calm", "Mind", "Body", "Chaos", "Order", "Colorless"]

    // MARK: - Loading

    /// Everything the tab needs, cached parts from cache: the catalog and
    /// prices go to the server only when their copy is older than the policy
    /// allows; holdings and pending items are always re-read.
    func load() async {
        async let catalogLoad: Void = loadCatalog(force: false)
        async let holdingsLoad: Void = loadHoldings()
        async let priceLoad: Void = loadPrices(force: false)
        async let pendingLoad: Void = refreshPending()
        _ = await (catalogLoad, holdingsLoad, priceLoad, pendingLoad)
    }

    /// Pull to refresh: everything, conditionally on the stored validators.
    func refresh() async {
        async let catalogLoad: Void = loadCatalog(force: true)
        async let holdingsLoad: Void = loadHoldings()
        async let priceLoad: Void = loadPrices(force: true)
        async let pendingLoad: Void = refreshPending()
        _ = await (catalogLoad, holdingsLoad, priceLoad, pendingLoad)
    }

    /// The Connect action: forget the cached endpoint (and any backoff) so
    /// discovery probes again, then ask for holdings.
    func connect() async {
        await endpoints.invalidate()
        await loadHoldings()
    }

    /// The sync engine applied items: the ledger moved.
    func refreshHoldings() async {
        await loadHoldings()
    }

    /// The outbox changed: re-read what is still owed.
    func refreshPending() async {
        pending = await pendingSource.pendingDeltas().byPrinting
        rebuildEntries()
    }

    /// `/health.catalog_version` as the sync engine last saw it. A version
    /// the cached catalog does not have fetches the catalog now.
    func noteServerCatalogVersion(_ version: String?) async {
        serverCatalogVersion = version
        guard let version, catalog.origin.version != version else { return }
        await loadCatalog(force: true)
    }

    private func loadHoldings() async {
        if case .loaded = holdings {} else { holdings = .loading }
        do {
            let refreshed = try await holdingsSource.refresh()
            holdings = .loaded(CollectionHoldings(snapshot: refreshed.snapshot, freshness: .live))
        } catch {
            if let snapshot = await holdingsSource.snapshot() {
                holdings = .loaded(CollectionHoldings(snapshot: snapshot, freshness: .cached(reason: error)))
            } else {
                holdings = .failed(error)
            }
        }
        rebuildEntries()
    }

    private func loadPrices(force: Bool) async {
        let cached = await priceSource.cached()
        if let cached, !force, now().timeIntervalSince(cached.fetchedAt) < policy.priceMaxAge.seconds {
            prices = .loaded(cached)
            rebuildEntries()
            return
        }
        if case .loaded = prices {} else { prices = .loading }
        do {
            prices = .loaded(try await priceSource.refresh())
        } catch {
            // Stale beats blank: a sheet from an earlier day stays on screen.
            prices = cached.map { .loaded($0) } ?? .failed(error)
        }
        rebuildEntries()
    }

    private func loadCatalog(force: Bool) async {
        let current = await catalogSource.current()
        adopt(current)
        let stale: Bool = switch current.origin {
        case .bundled: true
        case .server(let version, let fetchedAt):
            now().timeIntervalSince(fetchedAt) >= policy.catalogMaxAge.seconds || (serverCatalogVersion.map { $0 != version } ?? false)
        }
        guard force || stale else { return }
        if let refreshed = try? await catalogSource.refresh() {
            adopt(refreshed)
        }
    }

    private func adopt(_ state: CatalogState) {
        catalog = state
        rebuildEntries()
    }
}

nonisolated extension Duration {
    static func hours(_ hours: Int) -> Duration { .seconds(hours * 3600) }
}
