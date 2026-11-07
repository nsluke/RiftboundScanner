import Foundation

/// Where the catalog on screen came from.
nonisolated enum CatalogOrigin: Hashable, Sendable {
    /// The `CardVault.json` this build shipped with: the cold-start seed.
    case bundled
    /// `GET /api/catalog`, stored under `catalog_version`.
    case server(version: String, fetchedAt: Date)

    var version: String? {
        if case .server(let version, _) = self { return version }
        return nil
    }
}

/// The vault the Collection shows and what it is: the bundled seed, or the
/// server's catalog with the count of printings this build's bundle does not
/// know (so cannot have in its recogniser index: scanning them needs an app
/// rebuild, ADR-002 decision 10).
nonisolated struct CatalogState: Sendable {
    let vault: CardVault
    let origin: CatalogOrigin
    /// Server rows whose code the bundled vault lacks. Non-zero means the
    /// server's catalog is newer than this build.
    let printingsNewerThanBundle: Int

    init(vault: CardVault, origin: CatalogOrigin, printingsNewerThanBundle: Int = 0) {
        self.vault = vault
        self.origin = origin
        self.printingsNewerThanBundle = printingsNewerThanBundle
    }

    static func bundled(_ seed: CardVault) -> CatalogState {
        CatalogState(vault: seed, origin: .bundled)
    }

    /// The server catalog turned into a vault. Art and Cardmarket links are
    /// never served (decision 15), so each row takes them from the bundled
    /// row with the same code; a printing the bundle lacks shows no art.
    static func server(_ catalog: CatalogResponse, seed: CardVault, fetchedAt: Date) -> CatalogState {
        let bundledCodes = Set(seed.cards.map(\.code))
        let cards = catalog.cards.map { VaultCard($0, art: seed.card(code: $0.code)) }
        let newer = catalog.cards.count { !bundledCodes.contains($0.code) }
        let asOf = CardVault.date(fromDay: catalog.asOf) ?? seed.asOf
        return CatalogState(
            vault: CardVault(asOf: asOf, cards: cards),
            origin: .server(version: catalog.catalogVersion, fetchedAt: fetchedAt),
            printingsNewerThanBundle: newer
        )
    }
}

/// Where the Collection's vault comes from: the cached server catalog when
/// one was fetched, otherwise the bundled seed.
nonisolated protocol CatalogSourcing: Sendable {
    /// What to show now, without going to the network.
    func current() async -> CatalogState
    /// Asks the server conditionally on the stored `catalog_version` and keeps the result.
    func refresh() async throws(ServerError) -> CatalogState
}

/// `GET /api/catalog` (S8: ETag is the content hash `catalog_version`),
/// stored as `AppPaths.catalog/catalog.json`; the bundled vault until the
/// first successful fetch.
actor ServerCatalogSource: CatalogSourcing {
    private let client: any CollectionServing
    private let seed: CardVault
    private let file: SnapshotFile<CatalogResponse>
    private let now: @Sendable () -> Date
    private var state: CatalogState?

    init(client: any CollectionServing, seed: CardVault, url: URL?, now: @escaping @Sendable () -> Date) {
        self.client = client
        self.seed = seed
        file = SnapshotFile(url: url)
        self.now = now
    }

    func current() async -> CatalogState {
        if let state { return state }
        let built: CatalogState
        if let stored = await file.load() {
            built = .server(stored.value, seed: seed, fetchedAt: stored.fetchedAt)
        } else {
            built = .bundled(seed)
        }
        state = built
        return built
    }

    func refresh() async throws(ServerError) -> CatalogState {
        let client = client
        let outcome = try await file.refresh(now: now()) { validator throws(ServerError) in
            try await client.catalog(ifNoneMatch: validator)
        }
        switch outcome {
        case .unchanged(let stored):
            // Same catalog_version: keep the vault already built, seen now.
            if let state, case .server(let version, _) = state.origin {
                let refreshed = CatalogState(vault: state.vault, origin: .server(version: version, fetchedAt: stored.fetchedAt), printingsNewerThanBundle: state.printingsNewerThanBundle)
                self.state = refreshed
                return refreshed
            }
            let built = CatalogState.server(stored.value, seed: seed, fetchedAt: stored.fetchedAt)
            state = built
            return built
        case .changed(let stored):
            let built = CatalogState.server(stored.value, seed: seed, fetchedAt: stored.fetchedAt)
            state = built
            return built
        }
    }
}
