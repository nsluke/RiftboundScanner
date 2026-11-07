import Foundation

/// A server resource the app keeps a copy of between launches: the value,
/// the validator to send back as `If-None-Match`, and when it was fetched.
/// Holdings, the catalog and the price sheet are all kept this way under
/// `AppPaths.catalog`; each is a cache of something the server owns, so
/// deleting the file loses nothing (ADR-002, decision 10).
nonisolated struct ServerSnapshot<Value: Hashable & Sendable & Codable>: Hashable, Sendable, Codable {
    let value: Value
    let validator: String?
    let fetchedAt: Date

    init(value: Value, validator: String?, fetchedAt: Date) {
        self.value = value
        self.validator = validator
        self.fetchedAt = fetchedAt
    }

    /// The server answered 304 (or the same validator again): the same value,
    /// seen now.
    func seen(at date: Date) -> ServerSnapshot {
        ServerSnapshot(value: value, validator: validator, fetchedAt: date)
    }
}

/// One snapshot as one JSON file. `url: nil` keeps it in memory (tests,
/// previews). An unreadable file counts as absent: the next successful fetch
/// rewrites it.
actor SnapshotFile<Value: Hashable & Sendable & Codable> {
    private let url: URL?
    private var loaded: ServerSnapshot<Value>??
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(url: URL?) {
        self.url = url
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() -> ServerSnapshot<Value>? {
        if let loaded { return loaded }
        let read: ServerSnapshot<Value>? = url.flatMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(ServerSnapshot<Value>.self, from: data)
        }
        loaded = .some(read)
        return read
    }

    func save(_ snapshot: ServerSnapshot<Value>) throws {
        loaded = .some(snapshot)
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    func remove() {
        loaded = .some(nil)
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// How a conditional fetch ended: a new value, or the server's confirmation
/// that the copy on hand is current.
nonisolated enum SnapshotRefresh<Value: Hashable & Sendable & Codable>: Hashable, Sendable {
    case changed(ServerSnapshot<Value>)
    case unchanged(ServerSnapshot<Value>)

    var snapshot: ServerSnapshot<Value> {
        switch self {
        case .changed(let snapshot), .unchanged(let snapshot): snapshot
        }
    }

    var isChanged: Bool {
        if case .changed = self { return true }
        return false
    }
}

nonisolated extension SnapshotFile {
    /// Fetches conditionally on the stored validator and keeps the result.
    /// A 304 reaches the app as the cached body under the same validator
    /// (`HTTPCollectionClient`), so an unchanged validator keeps the stored
    /// value and only moves `fetchedAt`; a server without validators always
    /// counts as changed.
    func refresh(
        now: Date,
        fetch: (_ ifNoneMatch: String?) async throws(ServerError) -> Versioned<Value>
    ) async throws(ServerError) -> SnapshotRefresh<Value> {
        let cached = await load()
        let page = try await fetch(cached?.validator)
        if let cached, let validator = page.validator, validator == cached.validator {
            let kept = cached.seen(at: now)
            try? await save(kept)
            return .unchanged(kept)
        }
        let fresh = ServerSnapshot(value: page.value, validator: page.validator, fetchedAt: now)
        try? await save(fresh)
        return .changed(fresh)
    }
}
