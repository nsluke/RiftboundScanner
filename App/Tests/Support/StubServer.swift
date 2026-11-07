import Foundation
import Synchronization
@testable import RiftboundScannerApp

/// A canned HTTP answer.
nonisolated struct StubResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data

    init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    static func json(_ status: Int, _ json: String, headers: [String: String] = [:]) -> StubResponse {
        var headers = headers
        headers["Content-Type"] = "application/json"
        return StubResponse(status: status, headers: headers, body: Data(json.utf8))
    }

    static let notFound = StubResponse(status: 404, body: Data(#"{"detail":"not found"}"#.utf8))
}

/// A request as the stub saw it, with the body read from its stream.
nonisolated struct RecordedRequest: Sendable {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data

    var path: String { url.path() }
    var json: JSONValue? { try? JSONValue(data: body) }
}

/// One test's fake server. The client's `X-Client` header routes requests
/// here, so suites run in parallel without sharing handlers.
nonisolated final class StubServer: Sendable {
    typealias Handler = @Sendable (RecordedRequest) -> StubResponse?

    let identity: String
    private let state = Mutex<State>(State())

    private struct State {
        var handlers: [Handler] = []
        var requests: [RecordedRequest] = []
    }

    init() {
        identity = "StubServer/\(UUID().uuidString)"
        StubURLProtocol.register(self)
    }

    deinit {
        StubURLProtocol.unregister(identity)
    }

    /// Adds a handler; the first one returning non-nil answers.
    func respond(_ handler: @escaping Handler) {
        state.withLock { $0.handlers.append(handler) }
    }

    /// Answers every request to `path` (exact match) with the response.
    func on(_ path: String, _ response: StubResponse) {
        respond { $0.path == path ? response : nil }
    }

    /// Answers `path` with each response in turn, repeating the last.
    func on(_ path: String, sequence responses: [StubResponse]) {
        let cursor = Mutex(0)
        respond { request in
            guard request.path == path else { return nil }
            return cursor.withLock { index in
                defer { index += 1 }
                return responses[min(index, responses.count - 1)]
            }
        }
    }

    var requests: [RecordedRequest] {
        state.withLock { $0.requests }
    }

    fileprivate func handle(_ request: RecordedRequest) -> StubResponse {
        state.withLock { state in
            state.requests.append(request)
            for handler in state.handlers {
                if let response = handler(request) { return response }
            }
            return .notFound
        }
    }

    /// A session whose only transport is this stub.
    var session: URLSession {
        HTTPCollectionClient.makeSession(protocolClasses: [StubURLProtocol.self])
    }

    /// A client wired to this stub, a fixed endpoint and an optional token.
    func client(endpoint: ServerEndpoint = .lan, token: String? = nil, cache: ResponseCache = ResponseCache(directory: nil)) -> HTTPCollectionClient {
        HTTPCollectionClient(session: session, endpoints: FixedEndpoints(.available(endpoint, health: HealthReport())), token: { token }, clientIdentity: identity, cache: cache)
    }
}

nonisolated final class StubURLProtocol: URLProtocol {
    private static let servers = Mutex<[String: StubServer]>([:])

    static func register(_ server: StubServer) {
        servers.withLock { $0[server.identity] = server }
    }

    static func unregister(_ identity: String) {
        _ = servers.withLock { $0.removeValue(forKey: identity) }
    }

    private static func server(for request: URLRequest) -> StubServer? {
        guard let identity = request.value(forHTTPHeaderField: "X-Client") else { return nil }
        return servers.withLock { $0[identity] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        server(for: request) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let client, let server = Self.server(for: request), let url = request.url else { return }
        let recorded = RecordedRequest(
            method: request.httpMethod ?? "GET",
            url: url,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody ?? Self.read(request.httpBodyStream)
        )
        let response = server.handle(recorded)
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: response.body)
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 65_536)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 65_536)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// A resolver that always answers the same, recording invalidations.
actor FixedEndpoints: EndpointResolving {
    var resolution: EndpointResolution
    private(set) var invalidations = 0

    init(_ resolution: EndpointResolution) {
        self.resolution = resolution
    }

    func resolve() async -> EndpointResolution { resolution }

    func invalidate() {
        invalidations += 1
    }

    func set(_ resolution: EndpointResolution) {
        self.resolution = resolution
    }
}

/// A failing transport, for the unreachable path.
nonisolated final class FailingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }
    override func stopLoading() {}
}
