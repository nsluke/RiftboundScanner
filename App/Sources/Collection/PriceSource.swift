import Foundation

/// One day's TCGplayer market prices for every printing the server has a
/// price for, keyed by vault code, as `GET /api/prices/latest` serves them.
/// The server refreshes them from tcgcsv; the app never talks to tcgcsv
/// itself (ADR-002, decision 10: tcgcsv forbids user-facing clients).
nonisolated struct PriceSheet: Hashable, Sendable {
    /// The price day (`YYYY-MM-DD`).
    let day: String
    let fetchedAt: Date
    let quotes: [String: PriceQuote]

    init(_ stored: ServerSnapshot<PriceSheetResponse>) {
        day = stored.value.day
        fetchedAt = stored.fetchedAt
        quotes = stored.value.items
    }

    init(day: String, fetchedAt: Date, quotes: [String: PriceQuote]) {
        self.day = day
        self.fetchedAt = fetchedAt
        self.quotes = quotes
    }

    subscript(code: String) -> PriceQuote? { quotes[code] }

    /// The price day as a date, for "as of" lines.
    var asOf: Date { CardVault.date(fromDay: day) ?? fetchedAt }
}

/// Where market prices come from. The live source reads the server; tests
/// run it over `StubCollectionClient` with an in-memory file.
nonisolated protocol PriceQuoting: Sendable {
    /// The last sheet fetched, if any, without going to the network.
    func cached() async -> PriceSheet?
    /// Asks the server conditionally on the stored day tag and keeps the result.
    /// `ServerError.notFound` means the server has no prices stored yet.
    func refresh() async throws(ServerError) -> PriceSheet
}

/// `GET /api/prices/latest` (S8: ETag `prices-<day>.<refreshed>`), stored
/// as `AppPaths.catalog/prices.json`.
actor ServerPriceSource: PriceQuoting {
    private let client: any CollectionServing
    private let file: SnapshotFile<PriceSheetResponse>
    private let now: @Sendable () -> Date

    init(client: any CollectionServing, url: URL?, now: @escaping @Sendable () -> Date) {
        self.client = client
        file = SnapshotFile(url: url)
        self.now = now
    }

    func cached() async -> PriceSheet? {
        await file.load().map(PriceSheet.init)
    }

    func refresh() async throws(ServerError) -> PriceSheet {
        let client = client
        let outcome = try await file.refresh(now: now()) { validator throws(ServerError) in
            try await client.latestPrices(ifNoneMatch: validator)
        }
        return PriceSheet(outcome.snapshot)
    }
}
