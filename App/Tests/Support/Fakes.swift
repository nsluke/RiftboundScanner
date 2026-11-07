import CoreGraphics
import Foundation
import RiftboundRecognizer
@testable import RiftboundScannerApp

nonisolated struct StubCamera: CameraOperating {
    var access = true
    var photo = Fixtures.jpeg()
    var startFailure: CameraError?

    func requestAccess() async -> Bool { access }

    func start() async throws {
        if let startFailure { throw startFailure }
    }

    func stop() async {}

    func setTorch(_ isOn: Bool) async throws {}

    func capturePhoto() async throws -> Data { photo }
}

nonisolated struct StubFailure: Error {}

nonisolated struct StubIdentifier: CardIdentifying {
    let outcome: Result<IdentifiedCard, StubFailure>

    init(identified: Result<IdentifiedCard, StubFailure>) {
        outcome = identified
    }

    /// Stamps a canned result with the fixture engine.
    init(outcome: Result<RecognitionResult, StubFailure>) {
        self.outcome = outcome.map { IdentifiedCard(result: $0, engine: Fixtures.engineStamp) }
    }

    func identify(_ photo: CGImage) async throws -> IdentifiedCard {
        try outcome.get()
    }
}

/// A behaviourally real store with no disk: the same staleness rule and
/// decision numbering as `FileScanStore`, with an injected clock and ids.
actor InMemoryScanStore: ScanStoring {
    private var batchesByID: [ScanBatch.ID: ScanBatch] = [:]
    private var recordsByBatch: [ScanBatch.ID: [ScanRecord]] = [:]
    private(set) var photos: [ScanRecord.ID: Data] = [:]
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID

    init(now: @escaping @Sendable () -> Date = { Fixtures.epoch }, makeID: @escaping @Sendable () -> UUID = { UUID() }) {
        self.now = now
        self.makeID = makeID
    }

    func batches() -> [ScanBatch] {
        batchesByID.values.sorted { $0.startedAt > $1.startedAt }
    }

    func records(in batch: ScanBatch.ID) -> [ScanRecord] {
        recordsByBatch[batch] ?? []
    }

    func save(_ batch: ScanBatch) {
        batchesByID[batch.id] = batch
    }

    func append(_ record: ScanRecord, photo: Data, rectified: Data?) throws {
        guard batchesByID[record.batchID] != nil else { throw ScanStoreError.batchMissing(record.batchID) }
        photos[record.id] = photo
        recordsByBatch[record.batchID, default: []].append(record)
    }

    func update(_ record: ScanRecord) throws {
        guard var list = recordsByBatch[record.batchID], let position = list.firstIndex(where: { $0.id == record.id }) else {
            throw ScanStoreError.recordMissing(record.id)
        }
        guard list[position].isExtended(by: record) else { throw ScanStoreError.staleRecord(record.id) }
        list[position] = record
        recordsByBatch[record.batchID] = list
    }

    func update(_ changes: [ScanRecord]) throws {
        for change in changes {
            try update(change)
        }
    }

    func decide(_ id: ScanRecord.ID, in batch: ScanBatch.ID, _ input: DecisionInput) throws -> ScanRecord {
        guard input.verdict != .pending else { throw ScanStoreError.invalidDecision(id) }
        guard var list = recordsByBatch[batch], let position = list.firstIndex(where: { $0.id == id }) else {
            throw ScanStoreError.recordMissing(id)
        }
        let decided = list[position].deciding(input, id: Decision.ID(rawValue: makeID()), at: now())
        list[position] = decided
        recordsByBatch[batch] = list
        return decided
    }

    func deleteBatch(_ id: ScanBatch.ID) {
        batchesByID[id] = nil
        recordsByBatch[id] = nil
    }

    nonisolated func batchDirectory(for id: ScanBatch.ID) -> URL {
        URL.temporaryDirectory.appending(path: id.rawValue.uuidString)
    }

    nonisolated func photoURL(for record: ScanRecord) -> URL {
        batchDirectory(for: record.batchID).appending(path: record.photoFileName)
    }

    nonisolated func rectifiedURL(for record: ScanRecord) -> URL? { nil }
}

/// An identifier that answers only when released, one answer per release, so
/// a test can hold identification back while feeding carries on.
actor GatedIdentifier: CardIdentifying {
    private let result: IdentifiedCard
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var releases = 0
    private(set) var started = 0

    init(result: RecognitionResult = Fixtures.result(cards: [Fixtures.vi, Fixtures.jinx])) {
        self.result = IdentifiedCard(result: result, engine: Fixtures.engineStamp)
    }

    var waitingCount: Int { waiting.count }

    func identify(_ photo: CGImage) async throws -> IdentifiedCard {
        started += 1
        if releases > 0 {
            releases -= 1
        } else {
            await withCheckedContinuation { waiting.append($0) }
        }
        return result
    }

    func release() {
        if waiting.isEmpty {
            releases += 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}


/// Pending ledger deltas a test sets by hand, standing in for the outbox.
actor StubPendingLedger: PendingLedgerProviding {
    private(set) var deltas: [PendingDelta]

    init(_ deltas: [PendingDelta] = []) {
        self.deltas = deltas
    }

    func pendingDeltas() -> [PendingDelta] { deltas }

    func set(_ deltas: [PendingDelta]) {
        self.deltas = deltas
    }
}

// MARK: - Server fakes

/// Scripted answers for `StubCollectionClient`. Ledger items are answered
/// per `client_ref`; anything unscripted gets `defaultItemStatus`.
nonisolated struct ServerScript: Sendable {
    var health: Result<HealthReport, ServerError> = .success(HealthReport(status: "ok", version: "2.0.0", cards: 1822, userVersion: 5, apiVersion: 2, catalogVersion: "cat-1"))
    var itemStatuses: [String: LedgerItemStatus] = [:]
    var defaultItemStatus: LedgerItemStatus = .applied
    /// When set, every sync fails with this before any item is answered.
    var syncFailure: ServerError?
    var batch: Result<UpsertOutcome, ServerError> = .success(.created)
    var scan: Result<ScanUploadReceipt, ServerError> = .success(ScanUploadReceipt(outcome: .created))
    var asset: Result<UpsertOutcome, ServerError> = .success(.created)
    var resolve: Result<ResolveResponse, ServerError> = .success(ResolveResponse(resolved: [:]))
    var holdings: Result<Versioned<HoldingsResponse>, ServerError> = .success(Versioned(value: HoldingsResponse(summary: HoldingsSummary(distinctCards: 0, totalCards: 0), items: []), validator: "h0"))
    var ledger: Result<LedgerPage, ServerError> = .success(LedgerPage(items: [], head: 0))
    var catalog: Result<Versioned<CatalogResponse>, ServerError> = .failure(.notFound)
    var prices: Result<Versioned<PriceSheetResponse>, ServerError> = .success(Versioned(value: PriceSheetResponse(day: "2026-11-07", items: [:]), validator: "2026-11-07"))
    var overlayMeta: Result<OverlayMeta, ServerError> = .failure(.notFound)
    var overlay: Result<Versioned<Data>, ServerError> = .failure(.notFound)
    var overlayChanges: Result<OverlayChanges, ServerError> = .failure(.gone)
    var policy: Result<PolicyDocument, ServerError> = .failure(.notFound)
    var learningStats: Result<LearningStats, ServerError> = .failure(.notFound)
    var decks: Result<Versioned<[DeckSummary]>, ServerError> = .success(Versioned(value: [], validator: "d0"))
    var deckDetails: [Int: Result<DeckDetail, ServerError>] = [:]
    var setDeckCard: Result<DeckDetail, ServerError>?
    /// Export text per deck id; unscripted decks answer 404.
    var deckExports: [Int: Result<String, ServerError>] = [:]
    var evaluation: Result<EvaluationReceipt, ServerError>?

    init() {}
}

/// Everything a `StubCollectionClient` was asked, in order.
nonisolated struct ServerRecording: Sendable {
    var healthCalls = 0
    var learningStatsCalls = 0
    var syncRequests: [LedgerSyncRequest] = []
    var batches: [BatchUpload] = []
    var scans: [ScanUpload] = []
    var assets: [(scanID: UUID, kind: AssetKind, bytes: Int)] = []
    var holdingsValidators: [String?] = []
    var ledgerSince: [Int] = []
    var deckChanges: [(deckID: Int, change: DeckCardChange)] = []
    var deckRequests: [Int] = []
    var decksValidators: [String?] = []
    var deckExports: [(deckID: Int, style: DeckExportStyle)] = []
    var evaluations: [EvaluationRunUpload] = []
}

/// A `CollectionServing` whose answers are scripted per call and per item.
actor StubCollectionClient: CollectionServing {
    private(set) var script: ServerScript
    private(set) var recording = ServerRecording()
    private var nextLedgerID = 1
    /// The rows the stub holds by client reference, so a `duplicate` answer
    /// carries the row's id and card the way the server's does.
    private var rows: [String: (ledgerID: Int, cardID: String?)] = [:]
    private var holdsScans = false
    private var heldScanWaiters: [CheckedContinuation<Void, Never>] = []

    init(script: ServerScript = ServerScript()) {
        self.script = script
    }

    func update(_ change: @Sendable (inout ServerScript) -> Void) {
        change(&script)
    }

    /// Scan uploads in flight, held until `releaseScans()`.
    var heldScans: Int { heldScanWaiters.count }

    /// While on, `putScan` suspends after recording the upload until released,
    /// so a test can act on the store mid-drain.
    func holdScans(_ holds: Bool) {
        holdsScans = holds
        if !holds { releaseScans() }
    }

    func releaseScans() {
        let waiters = heldScanWaiters
        heldScanWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func health() async throws(ServerError) -> HealthReport {
        recording.healthCalls += 1
        return try script.health.get()
    }

    func resolve(keys: [String]) async throws(ServerError) -> ResolveResponse {
        try script.resolve.get()
    }

    func syncLedger(_ request: LedgerSyncRequest) async throws(ServerError) -> LedgerSyncResponse {
        recording.syncRequests.append(request)
        if let failure = script.syncFailure { throw failure }
        var results: [LedgerItemResult] = []
        for item in request.items {
            let status = script.itemStatuses[item.clientRef] ?? script.defaultItemStatus
            let cardID: String? = if case .delta(let delta) = item { delta.cardKey } else { nil }
            switch status {
            case .applied:
                let row = (ledgerID: nextLedgerID, cardID: cardID)
                nextLedgerID += 1
                rows[item.clientRef] = row
                results.append(LedgerItemResult(clientRef: item.clientRef, status: status, cardID: row.cardID, finish: nil, ledgerID: row.ledgerID))
            case .duplicate:
                // The row an earlier request committed. One the stub never saw
                // applied (a scripted duplicate) gets a fresh id, as the server
                // has one from the request whose answer was lost.
                let row: (ledgerID: Int, cardID: String?)
                if let known = rows[item.clientRef] {
                    row = known
                } else {
                    row = (ledgerID: nextLedgerID, cardID: cardID)
                    nextLedgerID += 1
                    rows[item.clientRef] = row
                }
                results.append(LedgerItemResult(clientRef: item.clientRef, status: status, cardID: row.cardID, finish: nil, ledgerID: row.ledgerID))
            default:
                results.append(LedgerItemResult(clientRef: item.clientRef, status: status, cardID: nil, finish: nil, ledgerID: nil))
            }
        }
        return LedgerSyncResponse(results: results)
    }

    func putBatch(_ batch: BatchUpload) async throws(ServerError) -> UpsertOutcome {
        recording.batches.append(batch)
        return try script.batch.get()
    }

    func putScan(_ scan: ScanUpload) async throws(ServerError) -> ScanUploadReceipt {
        recording.scans.append(scan)
        if holdsScans {
            await withCheckedContinuation { heldScanWaiters.append($0) }
        }
        return try script.scan.get()
    }

    func putAsset(_ data: Data, kind: AssetKind, scanID: UUID) async throws(ServerError) -> AssetReceipt {
        recording.assets.append((scanID, kind, data.count))
        return AssetReceipt(outcome: try script.asset.get(), sha256: "")
    }

    func holdings(ifNoneMatch validator: String?) async throws(ServerError) -> Versioned<HoldingsResponse> {
        recording.holdingsValidators.append(validator)
        return try script.holdings.get()
    }

    func ledger(since id: Int) async throws(ServerError) -> LedgerPage {
        recording.ledgerSince.append(id)
        return try script.ledger.get()
    }

    func catalog(ifNoneMatch validator: String?) async throws(ServerError) -> Versioned<CatalogResponse> {
        try script.catalog.get()
    }

    func latestPrices(ifNoneMatch validator: String?) async throws(ServerError) -> Versioned<PriceSheetResponse> {
        try script.prices.get()
    }

    func overlayMeta(calibration: String) async throws(ServerError) -> OverlayMeta {
        try script.overlayMeta.get()
    }

    func overlay(calibration: String, ifNoneMatch validator: String?) async throws(ServerError) -> Versioned<Data> {
        try script.overlay.get()
    }

    func overlayChanges(calibration: String, sinceVersion: Int) async throws(ServerError) -> OverlayChanges {
        try script.overlayChanges.get()
    }

    func policy() async throws(ServerError) -> PolicyDocument {
        try script.policy.get()
    }

    func learningStats() async throws(ServerError) -> LearningStats {
        recording.learningStatsCalls += 1
        return try script.learningStats.get()
    }

    func decks(ifNoneMatch validator: String?) async throws(ServerError) -> Versioned<[DeckSummary]> {
        recording.decksValidators.append(validator)
        return try script.decks.get()
    }

    func deck(id: Int) async throws(ServerError) -> DeckDetail {
        recording.deckRequests.append(id)
        guard let result = script.deckDetails[id] else { throw .notFound }
        return try result.get()
    }

    func deckExport(id: Int, style: DeckExportStyle) async throws(ServerError) -> String {
        recording.deckExports.append((id, style))
        guard let result = script.deckExports[id] else { throw .notFound }
        return try result.get()
    }

    func setDeckCard(deckID: Int, _ change: DeckCardChange) async throws(ServerError) -> DeckDetail {
        recording.deckChanges.append((deckID, change))
        guard let result = script.setDeckCard ?? script.deckDetails[deckID] else { throw .notFound }
        return try result.get()
    }

    func postEvaluation(_ run: EvaluationRunUpload) async throws(ServerError) -> EvaluationReceipt {
        recording.evaluations.append(run)
        return try (script.evaluation ?? .success(EvaluationReceipt(id: run.id))).get()
    }
}

/// Settings that live in memory for one test.
actor InMemoryServerSettingsStore: ServerSettingsStoring {
    private(set) var settings: ServerSettings
    private(set) var saveCount = 0
    var failure: (any Error)?

    init(_ settings: ServerSettings = ServerSettings()) {
        self.settings = settings
    }

    func load() -> ServerSettings { settings }

    func save(_ settings: ServerSettings) throws {
        if let failure { throw failure }
        self.settings = settings
        saveCount += 1
    }
}

actor InMemorySecretStore: SecretStoring {
    private(set) var values: [String: String] = [:]

    func read(_ key: String) -> String? { values[key] }

    func write(_ value: String?, for key: String) {
        values[key] = value
    }
}

/// A probe whose answers are scripted per endpoint kind, counting calls.
actor ScriptedProbe: EndpointProbing {
    var outcomes: [ServerEndpoint.Kind: ProbeOutcome]
    private(set) var probed: [ServerEndpoint.Kind] = []

    init(_ outcomes: [ServerEndpoint.Kind: ProbeOutcome]) {
        self.outcomes = outcomes
    }

    func probe(_ endpoint: ServerEndpoint, timeout: Duration) async -> ProbeOutcome {
        probed.append(endpoint.kind)
        return outcomes[endpoint.kind] ?? .unhealthy("unscripted")
    }

    func set(_ kind: ServerEndpoint.Kind, _ outcome: ProbeOutcome) {
        outcomes[kind] = outcome
    }
}

/// A path the test moves by hand; every `set` reaches every open `pathUpdates()` stream.
actor ScriptedPaths: NetworkPathObserving {
    var path: NetworkPathSummary
    private var subscribers: [UUID: AsyncStream<NetworkPathSummary>.Continuation] = [:]

    init(_ path: NetworkPathSummary) {
        self.path = path
    }

    func currentPath() -> NetworkPathSummary { path }

    var subscriberCount: Int { subscribers.count }

    func pathUpdates() -> AsyncStream<NetworkPathSummary> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<NetworkPathSummary>.makeStream(bufferingPolicy: .unbounded)
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    func set(_ path: NetworkPathSummary) {
        self.path = path
        for continuation in subscribers.values {
            continuation.yield(path)
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }
}

/// A deck cache that lives in memory for one test, counting saves.
actor InMemoryDeckCacheStore: DeckCacheStoring {
    private(set) var cache: DeckCache
    private(set) var saveCount = 0
    var failure: (any Error)?

    init(_ cache: DeckCache = .empty) {
        self.cache = cache
    }

    func load() -> DeckCache { cache }

    func save(_ cache: DeckCache) throws {
        if let failure { throw failure }
        self.cache = cache
        saveCount += 1
    }
}
