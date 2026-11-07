import Foundation

/// What the Decks tab keeps between launches so it can show something when
/// the server is out of reach (stale beats blank). Decks stay
/// server-authoritative (ADR-002 §5.5); this is a cache, never a source of
/// truth, and deleting it loses nothing.
nonisolated struct DeckCache: Hashable, Sendable, Codable {
    /// The last `GET /api/decks` answer and the validator to send back.
    struct Listing: Hashable, Sendable, Codable {
        let decks: [DeckSummary]
        let validator: String?
        let fetchedAt: Date

        init(decks: [DeckSummary], validator: String?, fetchedAt: Date) {
            self.decks = decks
            self.validator = validator
            self.fetchedAt = fetchedAt
        }
    }

    /// The last `GET /api/decks/{id}` answer, with its share text when that
    /// request succeeded too.
    struct Detail: Hashable, Sendable, Codable {
        let deck: DeckDetail
        let export: String?
        let fetchedAt: Date

        init(deck: DeckDetail, export: String?, fetchedAt: Date) {
            self.deck = deck
            self.export = export
            self.fetchedAt = fetchedAt
        }
    }

    var listing: Listing?
    var details: [Int: Detail]

    init(listing: Listing? = nil, details: [Int: Detail] = [:]) {
        self.listing = listing
        self.details = details
    }

    static let empty = DeckCache()
}

nonisolated protocol DeckCacheStoring: Sendable {
    func load() async -> DeckCache
    func save(_ cache: DeckCache) async throws
}

/// The cache as one JSON file (`AppPaths.catalog/decks.json`). An unreadable
/// file counts as empty: the next successful fetch rewrites it.
actor FileDeckCacheStore: DeckCacheStoring {
    private let url: URL
    private var loaded: DeckCache?

    init(url: URL) {
        self.url = url
    }

    func load() -> DeckCache {
        if let loaded { return loaded }
        let cache: DeckCache
        if let data = try? Data(contentsOf: url), let decoded = try? Self.decoder.decode(DeckCache.self, from: data) {
            cache = decoded
        } else {
            cache = .empty
        }
        loaded = cache
        return cache
    }

    func save(_ cache: DeckCache) throws {
        loaded = cache
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(cache).write(to: url, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
