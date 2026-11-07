import Foundation

/// The collection server as the app sees it (ADR-002 §5). The live
/// implementation is `HTTPCollectionClient`; tests inject `StubCollectionClient`.
/// Every method throws `ServerError`, so callers switch over what went wrong
/// instead of inspecting status codes.
nonisolated protocol CollectionServing: Sendable {
    /// `GET /health`. Throws `.serverOutdated` when the schema is older than the app needs.
    func health() async throws(ServerError) -> HealthReport
    /// `GET /api/cards/resolve?keys=`.
    func resolve(keys: [String]) async throws(ServerError) -> ResolveResponse
    /// `POST /api/sync/ledger`, at most `LedgerSyncRequest.maximumItems` items.
    func syncLedger(_ request: LedgerSyncRequest) async throws(ServerError) -> LedgerSyncResponse
    /// `PUT /api/scans/batches/{id}`.
    func putBatch(_ batch: BatchUpload) async throws(ServerError) -> UpsertOutcome
    /// `PUT /api/scans/{id}`; 409 surfaces as `.conflict(serverSeq:)`.
    func putScan(_ scan: ScanUpload) async throws(ServerError) -> ScanUploadReceipt
    /// `PUT /api/scans/{id}/{kind}` with `X-Content-SHA256`.
    func putAsset(_ data: Data, kind: AssetKind, scanID: UUID) async throws(ServerError) -> AssetReceipt
    /// `GET /api/holdings`, conditional on the ledger-head validator.
    func holdings(ifNoneMatch validator: String?) async throws(ServerError) -> Versioned<HoldingsResponse>
    /// `GET /api/ledger?since_id=`.
    func ledger(since id: Int) async throws(ServerError) -> LedgerPage
    /// `GET /api/catalog`, conditional on `catalog_version`.
    func catalog(ifNoneMatch validator: String?) async throws(ServerError) -> Versioned<CatalogResponse>
    /// `GET /api/prices/latest`, conditional on the day.
    func latestPrices(ifNoneMatch validator: String?) async throws(ServerError) -> Versioned<PriceSheetResponse>
    /// `GET /api/learning/overlay/meta?calibration=`.
    func overlayMeta(calibration: String) async throws(ServerError) -> OverlayMeta
    /// `GET /api/learning/overlay?calibration=`: the full overlay document, conditional on its version.
    func overlay(calibration: String, ifNoneMatch validator: String?) async throws(ServerError) -> Versioned<Data>
    /// `GET /api/learning/overlay/changes?since_version=&calibration=`; 410 surfaces as `.gone`.
    func overlayChanges(calibration: String, sinceVersion: Int) async throws(ServerError) -> OverlayChanges
    /// `GET /api/learning/policy`.
    func policy() async throws(ServerError) -> PolicyDocument
    /// `GET /api/decks`, conditional.
    func decks(ifNoneMatch validator: String?) async throws(ServerError) -> Versioned<[DeckSummary]>
    /// `GET /api/decks/{id}`.
    func deck(id: Int) async throws(ServerError) -> DeckDetail
    /// `PUT /api/decks/{id}/cards`; returns the refreshed deck.
    func setDeckCard(deckID: Int, _ change: DeckCardChange) async throws(ServerError) -> DeckDetail
    /// `POST /api/learning/evaluations`.
    func postEvaluation(_ run: EvaluationRunUpload) async throws(ServerError) -> EvaluationReceipt
}

/// Everything that can go wrong talking to the server, typed so the sync
/// engine can tell "retry later" from "terminal" and Settings can explain it.
nonisolated enum ServerError: Error, Hashable {
    /// No endpoint answered `/health`, or the path is not one the app uses.
    case noEndpoint(EndpointUnavailability)
    /// The request never completed: DNS, connection refused, reset.
    case unreachable(String)
    case timedOut
    /// 401: the write token is missing or wrong.
    case unauthorized
    /// 403: the server refused the write (token set, wrong origin).
    case forbidden
    case notFound
    /// 409: a newer decision on the server, or a hash mismatch on an upload.
    case conflict(detail: String?, serverSeq: Int?)
    /// 410: the delta base is gone; fall back to the full resource.
    case gone
    /// 413: the body exceeds the server's cap for this route.
    case payloadTooLarge
    /// 422: the server rejected the shape of the body.
    case unprocessable(detail: String?)
    /// 507: the server is out of disk; retry later.
    case insufficientStorage
    /// The server answered but its `user_version` is below what the app needs.
    case serverOutdated(HealthReport)
    case unexpectedStatus(Int, detail: String?)
    /// A 2xx whose body did not decode.
    case malformed(String)

    /// Whether a later attempt with the same input could succeed.
    var isRetryable: Bool {
        switch self {
        case .noEndpoint, .unreachable, .timedOut, .insufficientStorage: true
        case .unexpectedStatus(let status, _): status >= 500
        case .unauthorized, .forbidden, .notFound, .conflict, .gone, .payloadTooLarge, .unprocessable, .serverOutdated, .malformed: false
        }
    }

    var message: String {
        switch self {
        case .noEndpoint(let reason): reason.message
        case .unreachable(let detail): String(localized: "The server could not be reached. \(detail)")
        case .timedOut: String(localized: "The server took too long to answer.")
        case .unauthorized: String(localized: "The server needs a write token. Check it in Settings.")
        case .forbidden: String(localized: "The server refused this request.")
        case .notFound: String(localized: "The server does not have that item.")
        case .conflict: String(localized: "The server already has a newer version of this item.")
        case .gone: String(localized: "The server no longer has that version.")
        case .payloadTooLarge: String(localized: "The upload is larger than the server accepts.")
        case .unprocessable(let detail): String(localized: "The server rejected the request. \(detail ?? "")")
        case .insufficientStorage: String(localized: "The server is out of disk space.")
        case .serverOutdated(let report): String(localized: "Server needs updating: schema version \(report.userVersion ?? 0), the app needs \(HealthReport.minimumUserVersion).")
        case .unexpectedStatus(let status, _): String(localized: "The server answered \(status).")
        case .malformed(let detail): String(localized: "The server's answer could not be read. \(detail)")
        }
    }
}

/// Why no endpoint is available right now.
nonisolated enum EndpointUnavailability: Hashable, Sendable {
    /// The device has no usable network path.
    case noPath
    /// Only cellular is up; the server is never probed over it.
    case cellularOnly
    /// Every candidate failed `/health`; probing resumes at `retryAt`.
    case backingOff(retryAt: Date)

    var message: String {
        switch self {
        case .noPath: String(localized: "You're offline.")
        case .cellularOnly: String(localized: "The server is reached over Wi-Fi or your home VPN, not cellular.")
        case .backingOff(let retryAt): String(localized: "No server answered. Trying again at \(retryAt.formatted(date: .omitted, time: .shortened)).")
        }
    }
}
