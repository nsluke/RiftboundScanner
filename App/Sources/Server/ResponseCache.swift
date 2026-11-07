import CryptoKit
import Foundation

/// Bodies of conditional GETs keyed by route and the app's own validator, so
/// a 304 can be answered from what the app stored rather than from
/// `URLCache` (which is off: Caddy rewrites ETags and the app must compare
/// its own validators). Memory first, with an optional directory behind it.
actor ResponseCache {
    private let directory: URL?
    private var memory: [String: Data] = [:]

    /// `directory: nil` keeps everything in memory (tests, previews).
    init(directory: URL?) {
        self.directory = directory
    }

    func body(for route: String, validator: String) -> Data? {
        let key = Self.key(route: route, validator: validator)
        if let data = memory[key] { return data }
        guard let directory, let data = try? Data(contentsOf: directory.appending(path: key)) else { return nil }
        memory[key] = data
        return data
    }

    func store(_ data: Data, for route: String, validator: String) {
        let key = Self.key(route: route, validator: validator)
        // One body per route: a new validator replaces the old entry.
        for stale in memory.keys where stale.hasPrefix(Self.prefix(route: route)) {
            memory[stale] = nil
            if let directory { try? FileManager.default.removeItem(at: directory.appending(path: stale)) }
        }
        memory[key] = data
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appending(path: key), options: .atomic)
        }
    }

    func removeAll() {
        memory.removeAll()
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func prefix(route: String) -> String {
        let routeHash = SHA256.hash(data: Data(route.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "route-\(routeHash)-"
    }

    private static func key(route: String, validator: String) -> String {
        let validatorHash = SHA256.hash(data: Data(validator.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return prefix(route: route) + validatorHash + ".json"
    }
}
