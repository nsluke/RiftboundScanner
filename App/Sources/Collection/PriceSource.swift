import Foundation

/// TCGplayer market prices for one product, by finish.
nonisolated struct ProductPrice: Hashable, Sendable, Codable {
    var normal: Double?
    var foil: Double?
}

/// A day's prices for every Riftbound product, keyed by TCGplayer product id.
nonisolated struct PriceSheet: Hashable, Sendable, Codable {
    let fetchedAt: Date
    let byProduct: [Int: ProductPrice]

    subscript(productID: Int) -> ProductPrice? { byProduct[productID] }
}

/// Where market prices come from. The live source reads tcgcsv.com's daily
/// mirror of TCGplayer; tests inject a stub.
nonisolated protocol PriceQuoting: Sendable {
    /// The most recent sheet, from cache when it is fresh enough.
    func quotes(maxAge: Duration) async throws -> PriceSheet
}

nonisolated enum PriceSourceError: Error, Hashable {
    case badResponse(Int)
    case malformed(String)

    var message: String {
        switch self {
        case .badResponse(let status): String(localized: "The price service answered \(status).")
        case .malformed(let detail): String(localized: "The price feed could not be read. \(detail)")
        }
    }
}

/// tcgcsv.com publishes TCGplayer's catalog and prices once a day as JSON,
/// per category and group. Riftbound is category 89; one request per group
/// (a set or promo pool) gives every product's market price. The site answers
/// 401 to anonymous client user agents, so every request names this app.
actor TCGCSVPriceSource: PriceQuoting {
    static let riftboundCategory = 89
    static let userAgent = "RiftboundScanner/0.1 (personal collection app)"

    private let session: URLSession
    private let cacheURL: URL
    private let now: @Sendable () -> Date
    private var inFlight: Task<PriceSheet, any Error>?

    init(session: URLSession = .shared, cacheURL: URL, now: @escaping @Sendable () -> Date) {
        self.session = session
        self.cacheURL = cacheURL
        self.now = now
    }

    func quotes(maxAge: Duration) async throws -> PriceSheet {
        if let cached = try? JSONDecoder.tcgcsv.decode(PriceSheet.self, from: Data(contentsOf: cacheURL)),
           now().timeIntervalSince(cached.fetchedAt) < maxAge.seconds {
            return cached
        }
        if let inFlight { return try await inFlight.value }
        let task = Task { try await self.fetch() }
        inFlight = task
        defer { inFlight = nil }
        let sheet = try await task.value
        try? JSONEncoder.tcgcsv.encode(sheet).write(to: cacheURL, options: .atomic)
        return sheet
    }

    private func fetch() async throws -> PriceSheet {
        let groups: Envelope<Group> = try await get("tcgplayer/\(Self.riftboundCategory)/groups")
        let prices = try await withThrowingTaskGroup(of: [Price].self) { tasks in
            for group in groups.results {
                tasks.addTask {
                    let envelope: Envelope<Price> = try await self.get("tcgplayer/\(Self.riftboundCategory)/\(group.groupId)/prices")
                    return envelope.results
                }
            }
            var all: [Price] = []
            for try await batch in tasks {
                all.append(contentsOf: batch)
            }
            return all
        }
        return PriceSheet(fetchedAt: now(), byProduct: Self.sheet(from: prices))
    }

    /// Folds the feed's one-row-per-finish shape into one entry per product.
    nonisolated static func sheet(from prices: [Price]) -> [Int: ProductPrice] {
        var byProduct: [Int: ProductPrice] = [:]
        for price in prices {
            var entry = byProduct[price.productId] ?? ProductPrice()
            switch price.subTypeName {
            case "Normal": entry.normal = price.marketPrice
            case "Foil": entry.foil = price.marketPrice
            default: continue
            }
            byProduct[price.productId] = entry
        }
        return byProduct
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: URL(string: "https://tcgcsv.com/")!.appending(path: path))
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PriceSourceError.badResponse(http.statusCode)
        }
        do {
            return try JSONDecoder.tcgcsv.decode(T.self, from: data)
        } catch {
            throw PriceSourceError.malformed(String(describing: error))
        }
    }

    struct Envelope<Result: Decodable & Sendable>: Decodable, Sendable {
        let results: [Result]
    }

    struct Group: Decodable, Sendable {
        let groupId: Int
        let name: String
    }

    struct Price: Decodable, Sendable, Hashable {
        let productId: Int
        let marketPrice: Double?
        let subTypeName: String
    }
}

nonisolated extension JSONDecoder {
    static var tcgcsv: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

nonisolated extension JSONEncoder {
    static var tcgcsv: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
