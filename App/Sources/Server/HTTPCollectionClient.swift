import CryptoKit
import Foundation

/// The live server client (ADR-002 Decision 5). Plain HTTP to whichever
/// endpoint the resolver found; no `URLCache` (conditional requests carry the
/// app's own validators and the server compares them weakly); `X-Client` on
/// every request and `Authorization: Bearer` when a write token is set.
actor HTTPCollectionClient: CollectionServing {
    /// Per-request timeout; uploads get `resourceTimeout` for the whole transfer.
    static let requestTimeout: TimeInterval = 15
    static let resourceTimeout: TimeInterval = 60

    private let session: URLSession
    private let endpoints: any EndpointResolving
    private let token: @Sendable () async -> String?
    private let clientIdentity: String
    private let cache: ResponseCache
    private let encoder = JSONEncoder.server
    private let decoder = JSONDecoder.server

    /// - Parameters:
    ///   - session: from `makeSession(protocolClasses:)`; tests pass a stubbed `URLProtocol`.
    ///   - token: read on every request, so a token typed in Settings applies at once.
    ///   - clientIdentity: the `X-Client` value, e.g. `RiftboundScanner/0.2.0 (iPhone17,1; iOS 26.1)`.
    init(session: URLSession = HTTPCollectionClient.makeSession(), endpoints: any EndpointResolving, token: @escaping @Sendable () async -> String?, clientIdentity: String, cache: ResponseCache) {
        self.session = session
        self.endpoints = endpoints
        self.token = token
        self.clientIdentity = clientIdentity
        self.cache = cache
    }

    /// A session with every cache turned off and the ADR's timeouts.
    nonisolated static func makeSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["Accept": "application/json"]
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        return URLSession(configuration: configuration)
    }

    /// The client's `X-Client` string for this build and device.
    nonisolated static func clientIdentity(appVersion: String, device: ScanBatch.Device) -> String {
        "RiftboundScanner/\(appVersion) (\(device.model); \(device.systemVersion))"
    }

    // MARK: - CollectionServing

    func health() async throws(ServerError) -> HealthReport {
        let report: HealthReport = try await get("health")
        guard report.isSupported else { throw .serverOutdated(report) }
        return report
    }

    func resolve(keys: [String]) async throws(ServerError) -> ResolveResponse {
        try await get("api/cards/resolve", query: [URLQueryItem(name: "keys", value: keys.joined(separator: ","))])
    }

    func syncLedger(_ request: LedgerSyncRequest) async throws(ServerError) -> LedgerSyncResponse {
        let response = try await send(.post, "api/sync/ledger", body: try encode(request))
        return try decode(LedgerSyncResponse.self, from: response.data)
    }

    func putBatch(_ batch: BatchUpload) async throws(ServerError) -> UpsertOutcome {
        let response = try await send(.put, "api/scans/batches/\(batch.id.uuidString)", body: try encode(batch))
        return response.status == 201 ? .created : .updated
    }

    func putScan(_ scan: ScanUpload) async throws(ServerError) -> ScanUploadReceipt {
        let response = try await send(.put, "api/scans/\(scan.id.uuidString)", body: try encode(scan))
        if response.status == 201 {
            return ScanUploadReceipt(outcome: .created)
        }
        let body = try? decoder.decode(ScanUploadReceipt.Body.self, from: response.data)
        let outcome: UpsertOutcome = body?.status == "unchanged" ? .unchanged : .updated
        return ScanUploadReceipt(outcome: outcome, isDeferred: body?.deferred ?? false, updated: body?.updated ?? [])
    }

    func putAsset(_ data: Data, kind: AssetKind, scanID: UUID) async throws(ServerError) -> AssetReceipt {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let response = try await send(.put, "api/scans/\(scanID.uuidString)/\(kind.rawValue)", body: data, contentType: "image/jpeg", headers: ["X-Content-SHA256": digest])
        return AssetReceipt(outcome: response.status == 201 ? .created : .updated, sha256: digest)
    }

    func holdings(ifNoneMatch validator: String?) async throws(ServerError) -> Versioned<HoldingsResponse> {
        try await getConditional("api/holdings", validator: validator)
    }

    func ledger(since id: Int) async throws(ServerError) -> LedgerPage {
        try await get("api/ledger", query: [URLQueryItem(name: "since_id", value: String(id))])
    }

    func catalog(ifNoneMatch validator: String?) async throws(ServerError) -> Versioned<CatalogResponse> {
        try await getConditional("api/catalog", validator: validator)
    }

    func latestPrices(ifNoneMatch validator: String?) async throws(ServerError) -> Versioned<PriceSheetResponse> {
        try await getConditional("api/prices/latest", validator: validator)
    }

    func overlayMeta(calibration: String) async throws(ServerError) -> OverlayMeta {
        try await get("api/learning/overlay/meta", query: [URLQueryItem(name: "calibration", value: calibration)])
    }

    func overlay(calibration: String, ifNoneMatch validator: String?) async throws(ServerError) -> Versioned<Data> {
        let (data, validator) = try await getConditionalBody("api/learning/overlay", query: [URLQueryItem(name: "calibration", value: calibration)], validator: validator)
        return Versioned(value: data, validator: validator)
    }

    func overlayChanges(calibration: String, sinceVersion: Int) async throws(ServerError) -> OverlayChanges {
        try await get("api/learning/overlay/changes", query: [URLQueryItem(name: "since_version", value: String(sinceVersion)), URLQueryItem(name: "calibration", value: calibration)])
    }

    func policy() async throws(ServerError) -> PolicyDocument {
        let response = try await send(.get, "api/learning/policy")
        let header = try decode(PolicyDocument.Header.self, from: response.data)
        return PolicyDocument(version: header.version, json: response.data)
    }

    func learningStats() async throws(ServerError) -> LearningStats {
        try await get("api/learning/stats")
    }

    func decks(ifNoneMatch validator: String?) async throws(ServerError) -> Versioned<[DeckSummary]> {
        let page: Versioned<DecksResponse> = try await getConditional("api/decks", validator: validator)
        return Versioned(value: page.value.items, validator: page.validator)
    }

    func deck(id: Int) async throws(ServerError) -> DeckDetail {
        try await get("api/decks/\(id)")
    }

    func setDeckCard(deckID: Int, _ change: DeckCardChange) async throws(ServerError) -> DeckDetail {
        let response = try await send(.put, "api/decks/\(deckID)/cards", body: try encode(change))
        return try decode(DeckDetail.self, from: response.data)
    }

    func deckExport(id: Int, style: DeckExportStyle) async throws(ServerError) -> String {
        let response = try await send(.get, "api/decks/\(id)/export", query: [URLQueryItem(name: "style", value: style.rawValue)])
        return String(decoding: response.data, as: UTF8.self)
    }

    func postEvaluation(_ run: EvaluationRunUpload) async throws(ServerError) -> EvaluationReceipt {
        let response = try await send(.post, "api/learning/evaluations", body: try encode(run))
        return (try? decoder.decode(EvaluationReceipt.self, from: response.data)) ?? EvaluationReceipt(id: run.id)
    }

    // MARK: - Transport

    private enum Method: String {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
    }

    private struct Response {
        let status: Int
        let headers: [String: String]
        let data: Data

        /// The ETag with `W/`, quotes and Caddy's `-<encoding>` suffix removed.
        var validator: String? {
            headers["Etag"].flatMap(HTTPCollectionClient.bareValidator)
        }
    }

    private func get<Value: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws(ServerError) -> Value {
        let response = try await send(.get, path, query: query)
        return try decode(Value.self, from: response.data)
    }

    private func getConditional<Value: Decodable & Hashable & Sendable>(_ path: String, query: [URLQueryItem] = [], validator: String?) async throws(ServerError) -> Versioned<Value> {
        let (data, validator) = try await getConditionalBody(path, query: query, validator: validator)
        return Versioned(value: try decode(Value.self, from: data), validator: validator)
    }

    /// Sends `If-None-Match` when the caller has a validator. A 304 is
    /// answered from the cache under that validator; if the cache lost the
    /// body the request is repeated unconditionally.
    private func getConditionalBody(_ path: String, query: [URLQueryItem], validator: String?) async throws(ServerError) -> (Data, String?) {
        let route = path + (query.isEmpty ? "" : "?" + query.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&"))
        if let validator {
            let response = try await send(.get, path, query: query, headers: ["If-None-Match": "\"\(validator)\""], acceptNotModified: true)
            if response.status == 304 {
                if let cached = await cache.body(for: route, validator: validator) {
                    return (cached, validator)
                }
            } else {
                return try await remember(response, route: route)
            }
        }
        let response = try await send(.get, path, query: query)
        return try await remember(response, route: route)
    }

    private func remember(_ response: Response, route: String) async throws(ServerError) -> (Data, String?) {
        if let validator = response.validator {
            await cache.store(response.data, for: route, validator: validator)
        }
        return (response.data, response.validator)
    }

    private func send(_ method: Method, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, contentType: String = "application/json", headers: [String: String] = [:], acceptNotModified: Bool = false) async throws(ServerError) -> Response {
        let base: URL
        switch await endpoints.resolve() {
        case .available(let endpoint, _): base = endpoint.url
        case .unavailable(let reason): throw .noEndpoint(reason)
        }
        var url = base.appending(path: path)
        if !query.isEmpty {
            url.append(queryItems: query)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(clientIdentity, forHTTPHeaderField: "X-Client")
        if let token = await token(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            await endpoints.invalidate()
            throw .timedOut
        } catch {
            await endpoints.invalidate()
            throw .unreachable(error.localizedDescription)
        }
        guard let http = urlResponse as? HTTPURLResponse else { throw .malformed("not an HTTP response") }
        var fields: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String {
                fields[name.capitalized] = value
            }
        }
        let response = Response(status: http.statusCode, headers: fields, data: data)
        try check(response, acceptNotModified: acceptNotModified)
        return response
    }

    private func check(_ response: Response, acceptNotModified: Bool) throws(ServerError) {
        switch response.status {
        case 200..<300: return
        case 304 where acceptNotModified: return
        case 401: throw .unauthorized
        case 403: throw .forbidden
        case 404: throw .notFound
        case 409: throw .conflict(detail: Self.detail(in: response.data), serverSeq: Self.serverSeq(in: response.data))
        case 410: throw .gone
        case 413: throw .payloadTooLarge
        case 422: throw .unprocessable(detail: Self.detail(in: response.data))
        case 507: throw .insufficientStorage
        default: throw .unexpectedStatus(response.status, detail: Self.detail(in: response.data))
        }
    }

    private func encode(_ value: some Encodable) throws(ServerError) -> Data {
        do {
            return try encoder.encode(value)
        } catch {
            throw .malformed("encoding: \(error)")
        }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws(ServerError) -> Value {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw .malformed(String(describing: error))
        }
    }

    /// FastAPI's `{"detail": ...}`, when the body has one.
    private static func detail(in data: Data) -> String? {
        guard let value = try? JSONValue(data: data) else { return nil }
        switch value["detail"] {
        case .string(let text)?: return text
        case .some(let other): return String(describing: other)
        case nil: return nil
        }
    }

    private static func serverSeq(in data: Data) -> Int? {
        guard let value = try? JSONValue(data: data) else { return nil }
        if case .number(let seq)? = value["server_seq"] { return Int(seq) }
        if case .number(let seq)? = value["detail"]?["server_seq"] { return Int(seq) }
        return nil
    }

    /// `W/"abc-gzip"` -> `abc`. Caddy's `encode gzip` appends the encoding
    /// and the server compares weakly, so the app stores the bare value.
    nonisolated static func bareValidator(_ etag: String) -> String? {
        var text = etag.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("W/") { text.removeFirst(2) }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        for suffix in ["-gzip", "-br", "-zstd", "-deflate"] where text.hasSuffix(suffix) {
            text.removeLast(suffix.count)
        }
        return text.isEmpty ? nil : text
    }
}

nonisolated extension HTTPCollectionClient: ServerScanReading {
    /// The server's page cap for scan listings.
    private static let pageSize = 1000

    func scanBatches() async throws(ServerError) -> [ServerScanBatch] {
        try await everyPage("api/scans/batches", query: [])
    }

    func scanIDs(inBatch id: UUID) async throws(ServerError) -> [UUID] {
        let rows: [ServerScanSummary] = try await everyPage("api/scans", query: [URLQueryItem(name: "batch_id", value: id.uuidString)])
        return rows.map(\.id)
    }

    func scan(id: UUID) async throws(ServerError) -> ServerScan {
        try await get("api/scans/\(id.uuidString)")
    }

    func asset(_ kind: AssetKind, scanID: UUID) async throws(ServerError) -> Data {
        try await send(.get, "api/scans/\(scanID.uuidString)/\(kind.rawValue)").data
    }

    private func everyPage<Item: Decodable & Sendable>(_ path: String, query: [URLQueryItem]) async throws(ServerError) -> [Item] {
        var items: [Item] = []
        while true {
            let page: ServerPage<Item> = try await get(path, query: query + [
                URLQueryItem(name: "limit", value: String(Self.pageSize)),
                URLQueryItem(name: "offset", value: String(items.count)),
            ])
            items += page.items
            if page.items.isEmpty || items.count >= page.total {
                return items
            }
        }
    }
}
