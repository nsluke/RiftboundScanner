import Foundation

/// How many of one printing the server's ledger says the user owns, by finish.
nonisolated struct OwnedCount: Hashable, Sendable, Codable {
    var normal: Int
    var foil: Int

    init(normal: Int = 0, foil: Int = 0) {
        self.normal = normal
        self.foil = foil
    }

    static let none = OwnedCount()

    var total: Int { normal + foil }
}

/// `GET /api/holdings` as the app last saw it, keyed by vault code
/// (`card_id`), with when it was fetched and the ledger-head validator to
/// send back. The phone never computes ownership from scans (ADR-002,
/// principle 1); this is its only picture of what it owns.
nonisolated struct HoldingsSnapshot: Hashable, Sendable {
    let fetchedAt: Date
    let validator: String?
    let holdings: HoldingsResponse
    /// Per vault code; a card the server lists with zero of both finishes is
    /// still present, so the Collection can tell "none" from "unknown".
    let counts: [String: OwnedCount]

    init(_ stored: ServerSnapshot<HoldingsResponse>) {
        fetchedAt = stored.fetchedAt
        validator = stored.validator
        holdings = stored.value
        counts = Dictionary(stored.value.items.map { ($0.cardID, OwnedCount(normal: $0.normal, foil: $0.foil)) }, uniquingKeysWith: { first, _ in first })
    }

    subscript(code: String) -> OwnedCount { counts[code] ?? .none }
}

/// How a holdings fetch ended.
nonisolated enum HoldingsRefresh: Hashable, Sendable {
    /// The ledger moved: new counts.
    case changed(HoldingsSnapshot)
    /// 304: the copy on hand is the server's current answer.
    case unchanged(HoldingsSnapshot)

    var snapshot: HoldingsSnapshot {
        switch self {
        case .changed(let snapshot), .unchanged(let snapshot): snapshot
        }
    }
}

/// Where the Collection's owned counts come from. The live source reads the
/// server conditionally on the ledger head and keeps the last answer on disk;
/// tests use it over `StubCollectionClient` with an in-memory file.
nonisolated protocol HoldingsSourcing: Sendable {
    /// The last answer the server gave, if any, without going to the network.
    func snapshot() async -> HoldingsSnapshot?
    /// Asks the server, sending the stored validator; keeps and returns the result.
    func refresh() async throws(ServerError) -> HoldingsRefresh
}

/// `GET /api/holdings` with the ETag-by-ledger-head validator (S3), stored as
/// `AppPaths.catalog/holdings.json`.
actor ServerHoldingsSource: HoldingsSourcing {
    private let client: any CollectionServing
    private let file: SnapshotFile<HoldingsResponse>
    private let now: @Sendable () -> Date

    /// - Parameter url: where the snapshot lives; `nil` keeps it in memory.
    init(client: any CollectionServing, url: URL?, now: @escaping @Sendable () -> Date) {
        self.client = client
        file = SnapshotFile(url: url)
        self.now = now
    }

    func snapshot() async -> HoldingsSnapshot? {
        await file.load().map(HoldingsSnapshot.init)
    }

    func refresh() async throws(ServerError) -> HoldingsRefresh {
        let client = client
        let outcome = try await file.refresh(now: now()) { validator throws(ServerError) in
            try await client.holdings(ifNoneMatch: validator)
        }
        switch outcome {
        case .changed(let stored): return .changed(HoldingsSnapshot(stored))
        case .unchanged(let stored): return .unchanged(HoldingsSnapshot(stored))
        }
    }
}
