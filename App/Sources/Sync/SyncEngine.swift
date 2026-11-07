import Foundation

/// One batch's sync picture, for the overview line and the History badges.
nonisolated struct BatchSyncSummary: Hashable, Sendable {
    enum Voiding: Hashable, Sendable {
        /// Undo items are still owed or unanswered.
        case inProgress(remaining: Int)
        /// Every item is acknowledged; the folder goes unless undos were refused.
        case complete(rejectedUndos: Int)
    }

    /// Ledger items in the outbox for this batch.
    var queuedItems = 0
    var appliedItems = 0
    /// Record and asset uploads still wanted (queued or failed).
    var pendingUploads = 0
    var failedUploads = 0
    var attention: [SyncAttention] = []
    var isClosed = false
    var voiding: Voiding?

    /// Nothing left to send for this batch.
    var isSettled: Bool { queuedItems == 0 && pendingUploads == 0 }
}

/// A terminal outcome the user should see (ADR-002, principle 2).
nonisolated struct SyncAttention: Hashable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable {
        case ledgerItem(TerminalStatus, isUndo: Bool)
        case recordConflict(serverSeq: Int?)
    }

    let scanID: ScanRecord.ID
    let reference: String
    let kind: Kind

    var id: String { reference }

    var message: String {
        switch kind {
        case .ledgerItem(let status, let isUndo):
            (isUndo ? String(localized: "Undo: ") : "") + status.message
        case .recordConflict(let serverSeq):
            String(localized: "The server holds a newer decision log for this scan (seq \(serverSeq.map(String.init) ?? "?")).")
        }
    }
}

/// Drains what the phone owes the server, in order: batch metadata, ledger
/// items in pages of 100, scan records, then `photo_small`, canvases and
/// photos (ADR-002, decision 4). Before every drain it reconciles
/// `scans.json` with `sync.json` and rebuilds the outbox, so the outbox is a
/// cache and a decision made while offline is never lost. Transport failures
/// back off from 5 s to 5 min; per-item statuses are recorded as terminal
/// states and shown rather than retried. A refusal of the ledger route as a
/// whole (404, 422: the client's encoding and the server's schema disagree)
/// leaves the items owed and ends the flush `failed` with the server's detail.
///
/// Each flush decodes a batch's records at most once, and not at all for a
/// batch that owes nothing and whose `scans.json` stamp has not moved since
/// its last reconcile; the history grows, the flush does not.
///
/// Main-actor state for the views; the store, outbox and client are actors
/// the engine awaits. Built by `RootView` through `AppDependencies.makeSyncEngine`.
@Observable
final class SyncEngine {
    /// What one flush read from the store: every live batch and, for each
    /// batch reconcile had to look at, its records decoded once and shared
    /// by every drain.
    struct Snapshot {
        var batches: [ScanBatch] = []
        var records: [ScanBatch.ID: [ScanRecord]] = [:]
    }

    nonisolated struct Policy: Hashable, Sendable {
        /// How long after a decision the flush waits, so a run of decisions goes in one request.
        var decisionDelay: Duration = .seconds(2)
        /// How often the Scan tab flushes while visible and the app is active.
        var periodicInterval: Duration = .seconds(60)
        var minimumBackoff: Duration = .seconds(5)
        var maximumBackoff: Duration = .seconds(300)
        var pageSize: Int = LedgerSyncRequest.maximumItems

        init(decisionDelay: Duration = .seconds(2), periodicInterval: Duration = .seconds(60), minimumBackoff: Duration = .seconds(5), maximumBackoff: Duration = .seconds(300), pageSize: Int = LedgerSyncRequest.maximumItems) {
            self.decisionDelay = decisionDelay
            self.periodicInterval = periodicInterval
            self.minimumBackoff = minimumBackoff
            self.maximumBackoff = maximumBackoff
            self.pageSize = pageSize
        }
    }

    enum Status: Hashable {
        /// Nothing in flight; `lastSyncedAt` says when the last drain finished.
        case idle
        case syncing
        /// No usable endpoint: offline, cellular only, or discovery backing off.
        case offline(EndpointUnavailability)
        /// A transport failure; the next attempt is scheduled.
        case waiting(retryAt: Date, error: ServerError)
        /// Something retrying alone will not fix: a local store error, a
        /// rejected token, an outdated server.
        case failed(String)

        var message: String {
            switch self {
            case .idle: String(localized: "Synced")
            case .syncing: String(localized: "Syncing…")
            case .offline(let reason): reason.message
            case .waiting(let retryAt, let error): String(localized: "\(error.message) Retrying at \(retryAt.formatted(date: .omitted, time: .shortened)).")
            case .failed(let detail): detail
            }
        }
    }

    private(set) var status: Status = .idle
    private(set) var lastSyncedAt: Date?
    /// Ledger items in the outbox across every batch.
    private(set) var queuedItems = 0
    private(set) var summaries: [ScanBatch.ID: BatchSyncSummary] = [:]
    /// The server's `catalog_version` at the last successful resolution.
    private(set) var catalogVersion: String?
    /// Every manual add and where it stands, newest first; the Add card
    /// sheet shows them.
    private(set) var manualItems: [ManualItem] = []
    /// Bumps each time the server applied an item: holdings changed.
    private(set) var ledgerGeneration = 0
    /// Completed flushes, for tests.
    private(set) var flushCount = 0
    /// Whether the Scan tab is on screen; the periodic flush runs only then.
    var isScanTabVisible = true
    var isActive = true

    private let store: SyncingScanStore
    private let outbox: Outbox
    /// Cards added by hand; their items ride the same outbox (ADR-002, decision 13).
    private let manual: ManualItemStore
    private let client: any CollectionServing
    private let endpoints: any EndpointResolving
    private let paths: any NetworkPathObserving
    private let vault: CardVault
    private let device: String
    private let uploads: any ScanUploadComposing
    private let assets: any ScanAssetProviding
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let policy: Policy

    private var isFlushing = false
    private var flushRequested = false
    /// The `scans.json` stamp each batch had when it was last reconciled.
    private var reconciledStamps: [ScanBatch.ID: String] = [:]
    private var backoff: Duration?
    private var retryTask: Task<Void, Never>?
    private var delayedFlush: Task<Void, Never>?

    init(
        store: SyncingScanStore,
        outbox: Outbox,
        manual: ManualItemStore,
        client: any CollectionServing,
        endpoints: any EndpointResolving,
        paths: any NetworkPathObserving,
        vault: CardVault,
        device: String,
        uploads: any ScanUploadComposing,
        assets: any ScanAssetProviding,
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        policy: Policy = Policy()
    ) {
        self.store = store
        self.outbox = outbox
        self.manual = manual
        self.client = client
        self.endpoints = endpoints
        self.paths = paths
        self.vault = vault
        self.device = device
        self.uploads = uploads
        self.assets = assets
        self.now = now
        self.sleep = sleep
        self.policy = policy
    }

    func summary(for batch: ScanBatch.ID) -> BatchSyncSummary? {
        summaries[batch]
    }

    // MARK: - Triggers

    /// Runs until cancelled: flushes at launch, 2 s after a decision, when a
    /// path to the home network appears, and every minute on the Scan tab.
    func start() async {
        await flush()
        async let events: Void = consumeStoreEvents()
        async let pathChanges: Void = consumePathUpdates()
        async let periodic: Void = runPeriodicFlush()
        _ = await (events, pathChanges, periodic)
        retryTask?.cancel()
        delayedFlush?.cancel()
    }

    /// The app came to the foreground.
    func appDidBecomeActive() async {
        isActive = true
        await flush()
    }

    func appDidResignActive() {
        isActive = false
    }

    /// "Retry now": forgets discovery's cache and backoff, then flushes.
    func retryNow() async {
        await endpoints.invalidate()
        backoff = nil
        await flush()
    }

    /// Marks the batch closed and refreshes its summary.
    func closeBatch(_ id: ScanBatch.ID) async {
        do {
            try await store.closeBatch(id)
            await refreshSummaries()
        } catch {
            status = .failed(String(describing: error))
        }
    }

    private func consumeStoreEvents() async {
        for await event in store.events {
            switch event {
            case .decided, .batchSaved:
                scheduleFlush(after: policy.decisionDelay)
            case .voided:
                await flush()
            case .deleted(let id):
                // Reconcile would drop these at the next flush; the summaries
                // should not count them until then.
                try? await outbox.removeAll { $0.batchID == id }
                await refreshSummaries()
            }
        }
    }

    private func consumePathUpdates() async {
        var wasReachable = await paths.currentPath().reachesHomeNetwork
        for await path in await paths.pathUpdates() {
            let reachable = path.reachesHomeNetwork
            if reachable, !wasReachable {
                await retryNow()
            }
            wasReachable = reachable
        }
    }

    private func runPeriodicFlush() async {
        while !Task.isCancelled {
            guard (try? await sleep(policy.periodicInterval)) != nil else { return }
            if isScanTabVisible, isActive {
                await flush()
            }
        }
    }

    private func scheduleFlush(after delay: Duration) {
        delayedFlush?.cancel()
        delayedFlush = Task {
            guard (try? await sleep(delay)) != nil, !Task.isCancelled else { return }
            await flush()
        }
    }

    private func scheduleRetry(after error: ServerError) {
        let next = min(max((backoff ?? .zero) * 2, policy.minimumBackoff), policy.maximumBackoff)
        backoff = next
        let retryAt = now().addingTimeInterval(next.seconds)
        status = .waiting(retryAt: retryAt, error: error)
        retryTask?.cancel()
        retryTask = Task {
            guard (try? await sleep(next)) != nil, !Task.isCancelled else { return }
            await flush()
        }
    }

    // MARK: - Flush

    /// Reconciles, then drains everything owed. Calls while a flush is running
    /// queue one more pass, so nothing decided mid-flush waits for a trigger.
    func flush() async {
        if isFlushing {
            flushRequested = true
            return
        }
        isFlushing = true
        defer { isFlushing = false }
        repeat {
            flushRequested = false
            await performFlush()
        } while flushRequested
    }

    private func performFlush() async {
        retryTask?.cancel()
        retryTask = nil
        status = .syncing
        defer { flushCount += 1 }
        var snapshot: Snapshot
        do {
            snapshot = try await reconcile()
        } catch {
            status = .failed(String(localized: "The scan store could not be read. \(String(describing: error))"))
            await refreshSummaries()
            return
        }
        let health: HealthReport
        switch await endpoints.resolve() {
        case .available(_, let report):
            health = report
        case .unavailable(let reason):
            status = .offline(reason)
            await refreshSummaries()
            return
        }
        do {
            if try await adoptCatalogVersion(health.catalogVersion) {
                snapshot = try await reconcile()
            }
            try await drainBatchMeta(snapshot)
            let ledgerRefusal = try await drainLedger()
            try await drainRecords(snapshot)
            for kind in [AssetKind.photoSmall, .canvas, .photo] {
                try await drainAssets(kind, in: snapshot)
            }
            try await completeVoidedBatches(snapshot)
            backoff = nil
            if let ledgerRefusal {
                status = .failed(ledgerRefusal.message)
            } else {
                lastSyncedAt = now()
                status = .idle
            }
        } catch let error as ServerError {
            if error.isRetryable {
                scheduleRetry(after: error)
            } else {
                status = .failed(error.message)
            }
        } catch {
            status = .failed(String(describing: error))
        }
        await refreshSummaries()
    }

    // MARK: - Reconcile

    /// Derives the outbox from `scans.json` and `sync.json`: every decision
    /// whose items the server has not acknowledged, every record whose log
    /// grew since its upload, every asset a scan now qualifies for. Entries
    /// for scans or batches that no longer exist are dropped. A batch whose
    /// `sync.json` owes nothing and whose records stamp is unchanged since
    /// its last reconcile is skipped without decoding its records. Returns
    /// what was read, for the drains.
    @discardableResult
    func reconcile() async throws -> Snapshot {
        var snapshot = Snapshot(batches: try await store.batches())
        let liveBatches = Set(snapshot.batches.map(\.id))
        reconciledStamps = reconciledStamps.filter { liveBatches.contains($0.key) }
        for batch in snapshot.batches {
            let state = await store.syncState(for: batch.id)
            let stamp = await store.recordsStamp(for: batch.id)
            if let stamp, reconciledStamps[batch.id] == stamp, state.isSettled, await outbox.count(in: batch.id) == 0 {
                continue
            }
            let records = try await store.records(in: batch.id)
            snapshot.records[batch.id] = records
            let liveScans = Set(records.map(\.id))
            for record in records {
                let previous = state[record.id]
                var scan = SyncingScanStore.refreshed(previous, for: record)
                let items = LedgerDeltaBuilder.items(record: record, previousState: scan, batch: batch, vault: vault)
                try await outbox.replace(itemsFor: record.id, in: batch.id, with: items)
                let owed = Set(items.map(\.clientRef))
                scan.items = Self.reconciledItems(scan.items, owed: owed)
                guard scan != previous else { continue }
                // Applied to the state as it is now, not as it was read above:
                // a decision landing during the outbox write re-queued the
                // record in `sync.json`, and that must survive this write.
                try await store.updateSyncState(for: batch.id) { state in
                    var current = SyncingScanStore.refreshed(state[record.id], for: record)
                    current.items = Self.reconciledItems(current.items, owed: owed)
                    state[record.id] = current
                }
            }
            try await outbox.removeAll { entry in
                guard let batchID = entry.batchID, let scanID = entry.scanID else { return false }
                return batchID == batch.id && !liveScans.contains(scanID)
            }
            reconciledStamps[batch.id] = stamp
        }
        try await outbox.removeAll { entry in
            guard let batchID = entry.batchID else { return false }
            return !liveBatches.contains(batchID)
        }
        // Manual adds the server has not answered ride along, after the scans'.
        try await outbox.replaceManual(with: await manual.pending().map(\.ledgerItem))
        queuedItems = await outbox.count
        return snapshot
    }

    /// The batch's records as the flush read them, or read now for a batch
    /// reconcile skipped (it owed nothing, so this is rare).
    private func records(of batch: ScanBatch, in snapshot: Snapshot) async throws -> [ScanRecord] {
        if let records = snapshot.records[batch.id] { return records }
        return try await store.records(in: batch.id)
    }

    /// The items with every queued entry the builder no longer owes dropped
    /// and every owed reference present, queued.
    nonisolated private static func reconciledItems(_ items: [String: LedgerItemState], owed: Set<String>) -> [String: LedgerItemState] {
        var items = items.filter { $0.value != .queued || owed.contains($0.key) }
        for ref in owed where items[ref] == nil {
            items[ref] = .queued
        }
        return items
    }

    /// Records the server's catalog version. When it changed, every
    /// `unknown_card` item goes back to queued so reconcile re-derives it;
    /// returns whether any did.
    private func adoptCatalogVersion(_ version: String?) async throws -> Bool {
        defer { catalogVersion = version }
        guard let version else { return false }
        var requeued = false
        for batch in try await store.batches() {
            let state = await store.syncState(for: batch.id)
            var changed = false
            var updated = state
            for (scanKey, scan) in state.scans {
                var scan = scan
                for (ref, item) in scan.items {
                    if case .terminal(.unknownCard(let seen)) = item, seen != version {
                        scan.items[ref] = .queued
                        changed = true
                    }
                }
                updated.scans[scanKey] = scan
            }
            if changed {
                let scans = updated.scans
                try await store.updateSyncState(for: batch.id) { $0.scans = scans }
                requeued = true
            }
        }
        for item in await manual.allItems() {
            if case .terminal(.unknownCard(let seen)) = item.state, seen != version {
                try await manual.set(.queued, for: item.clientRef)
                requeued = true
            }
        }
        return requeued
    }

    // MARK: - Drains

    private func drainBatchMeta(_ snapshot: Snapshot) async throws {
        for batch in snapshot.batches {
            let state = await store.syncState(for: batch.id)
            guard state.batchMeta.wantsUpload else { continue }
            let records = try await records(of: batch, in: snapshot)
            let calibrationHash = records.lazy.compactMap { $0.engine?.calibrationHash }.first
            let outcome: UploadState
            do {
                _ = try await client.putBatch(BatchUpload(batch, calibrationHash: calibrationHash))
                outcome = .uploaded(now())
            } catch {
                outcome = try Self.uploadFailure(error)
            }
            try await store.updateSyncState(for: batch.id) { $0.batchMeta = outcome }
        }
    }

    /// Sends the outbox a page at a time. Returns the refusal that stopped
    /// the ledger early without being the connection's fault (a 404 route,
    /// a 422 the server gives only for a request shape it does not accept,
    /// an unreadable answer): the items stay `sent`, records and assets still
    /// drain, and the flush ends `failed` with the server's detail. Nothing
    /// is marked `invalid` for it, because no single item caused it.
    private func drainLedger() async throws -> ServerError? {
        while true {
            let page = await outbox.nextPage(limit: policy.pageSize)
            guard !page.isEmpty else { return nil }
            try await markSent(page)
            let acknowledged: Set<String>
            do {
                acknowledged = try await send(page)
            } catch let error as ServerError where !error.isRetryable && !Self.stopsEveryRequest(error) {
                return error
            }
            // A page the server answered nothing about would loop forever.
            guard !acknowledged.isEmpty else { return nil }
        }
    }

    /// Records that the page is in the server's hands before the request
    /// goes out, so a lost answer is never mistaken for an item never sent.
    private func markSent(_ page: [OutboxEntry]) async throws {
        for (batchID, entries) in Dictionary(grouping: page, by: \.batchID) {
            guard let batchID else {
                for entry in entries {
                    try await manual.set(.sent, for: entry.id)
                }
                continue
            }
            try await store.updateSyncState(for: batchID) { state in
                for entry in entries {
                    guard let scanID = entry.scanID else { continue }
                    switch state[scanID].items[entry.id] {
                    case nil, .queued, .sent: state[scanID].items[entry.id] = .sent
                    case .applied, .terminal: break
                    }
                }
            }
        }
    }

    /// Sends one page and records every answer; returns the references the
    /// server acknowledged. A +1 answered `duplicate` with the row the
    /// server already holds (a replay after a lost answer, or after
    /// `sync.json` was lost) is recorded `applied`: the row is live and a
    /// later correction, rejection or void must undo it by reference. No
    /// holding changed now, so `ledgerGeneration` stays.
    private func send(_ page: [OutboxEntry]) async throws -> Set<String> {
        let response = try await client.syncLedger(LedgerSyncRequest(device: device, items: page.map(\.item)))
        var outcomes: [(entry: OutboxEntry, state: LedgerItemState)] = []
        var appliedAny = false
        for result in response.results {
            guard let entry = page.first(where: { $0.id == result.clientRef }) else { continue }
            switch result.status {
            case .applied:
                outcomes.append((entry, .applied(ledgerID: result.ledgerID ?? 0, cardID: result.cardID ?? "", finish: result.finish)))
                appliedAny = true
            case .duplicate where entry.item.isPlusOne && result.ledgerID != nil:
                outcomes.append((entry, .applied(ledgerID: result.ledgerID ?? 0, cardID: result.cardID ?? "", finish: result.finish)))
            default:
                if let terminal = TerminalStatus(result.status, catalogVersion: catalogVersion) {
                    outcomes.append((entry, .terminal(terminal)))
                }
            }
        }
        try await acknowledge(outcomes)
        if appliedAny {
            ledgerGeneration += 1
        }
        return Set(outcomes.map(\.entry.id))
    }

    /// Writes each item's final state through the store, touching nothing
    /// else in `sync.json`, and drops the items from the outbox.
    private func acknowledge(_ outcomes: [(entry: OutboxEntry, state: LedgerItemState)]) async throws {
        for (batchID, changes) in Dictionary(grouping: outcomes, by: \.entry.batchID) {
            guard let batchID else {
                for change in changes {
                    try await manual.set(change.state, for: change.entry.id)
                }
                continue
            }
            let changes = changes.compactMap { change in change.entry.scanID.map { ($0, change.entry.id, change.state) } }
            try await store.updateSyncState(for: batchID) { state in
                for (scanID, ref, itemState) in changes {
                    state[scanID].items[ref] = itemState
                }
            }
        }
        try await outbox.remove(refs: Set(outcomes.map(\.entry.id)))
        queuedItems = await outbox.count
    }

    /// Every write below changes only the fields this drain owns, through the
    /// store's closure: a void, a close or a newer decision written while a
    /// request was in flight is never overwritten with a stale snapshot.
    private func drainRecords(_ snapshot: Snapshot) async throws {
        for batch in snapshot.batches {
            guard let records = snapshot.records[batch.id] else { continue }
            // Without the batch on the server every record would be deferred.
            guard await store.syncState(for: batch.id).batchMeta.isUploaded else { continue }
            for record in records {
                guard await store.syncState(for: batch.id)[record.id].record.wantsUpload else { continue }
                let outcome: UploadState
                var acceptedSeq: Int?
                do {
                    let receipt = try await client.putScan(try uploads.upload(for: record, in: batch))
                    if receipt.isDeferred {
                        try await store.updateSyncState(for: batch.id) { $0.batchMeta = .queued }
                        break
                    }
                    outcome = .uploaded(now())
                    acceptedSeq = record.decisions.count
                } catch ServerError.conflict(_, let serverSeq) {
                    outcome = .conflict(serverSeq: serverSeq)
                } catch {
                    outcome = try Self.uploadFailure(error)
                }
                // A decision made meanwhile leaves `uploadedSeq` behind the log,
                // which is exactly what re-queues the record at the next reconcile.
                let seq = acceptedSeq
                try await store.updateSyncState(for: batch.id) { state in
                    state[record.id].record = outcome
                    if let seq {
                        state[record.id].uploadedSeq = seq
                    }
                }
            }
        }
    }

    private func drainAssets(_ kind: AssetKind, in snapshot: Snapshot) async throws {
        for batch in snapshot.batches {
            for record in snapshot.records[batch.id] ?? [] {
                let scan = await store.syncState(for: batch.id)[record.id]
                guard scan[kind].wantsUpload, scan.record.isUploaded else { continue }
                let outcome: UploadState
                do {
                    if let data = try await assets.asset(kind, for: record) {
                        _ = try await client.putAsset(data, kind: kind, scanID: record.id.rawValue)
                        outcome = .uploaded(now())
                    } else {
                        outcome = .failed(String(localized: "The file could not be prepared within the server's size limit."))
                    }
                } catch {
                    outcome = try Self.uploadFailure(error)
                }
                try await store.updateSyncState(for: batch.id) { $0[record.id][kind] = outcome }
            }
        }
    }

    /// A voided batch's folder goes once every ledger item is acknowledged
    /// and the server holds every voided record (the folder is the only copy
    /// of those decisions until then). Refused undos keep the folder so their
    /// count stays visible with "Resolve on the web"; the user removes it
    /// from History.
    private func completeVoidedBatches(_ snapshot: Snapshot) async throws {
        for batch in snapshot.batches {
            let state = await store.syncState(for: batch.id)
            guard state.isVoided, state.allItemsAcknowledged, await outbox.count(in: batch.id) == 0, state.rejectedUndos == 0 else { continue }
            // Read afresh, not from the snapshot: a void written during this
            // flush is in `scans.json` now, and deleting is the one step that
            // cannot be undone by the next reconcile.
            let records = try await store.records(in: batch.id)
            guard voidRemaining(state, records: records, batch: batch) == 0 else { continue }
            try await store.deleteBatch(batch.id)
        }
    }

    /// What a voided batch still has to send before its folder can go: items
    /// without an answer, undos reconcile has not derived yet (a void written
    /// during a flush), and the records that tell the server about the void.
    private func voidRemaining(_ state: BatchSyncState, records: [ScanRecord], batch: ScanBatch) -> Int {
        var remaining = state.scans.values.reduce(0) { $0 + $1.items.values.count { !$0.isAcknowledged } }
        for record in records {
            let scan = state[record.id]
            remaining += LedgerDeltaBuilder.items(record: record, previousState: scan, batch: batch, vault: vault).count { scan.items[$0.clientRef] == nil }
            if !record.decisions.isEmpty, scan.record.wantsUpload {
                remaining += 1
            }
        }
        return remaining
    }

    /// Turns an upload error into a state, or rethrows what should stop the
    /// whole flush: transport failures (to back off) and refusals that apply
    /// to every request alike.
    private static func uploadFailure(_ error: any Error) throws -> UploadState {
        guard let serverError = error as? ServerError else { return .failed(String(describing: error)) }
        switch serverError {
        case _ where serverError.isRetryable || stopsEveryRequest(serverError): throw serverError
        case .conflict(_, let serverSeq): return .conflict(serverSeq: serverSeq)
        default: return .failed(serverError.message)
        }
    }

    /// A refusal no other request would survive either: a rejected token or
    /// a server behind the app. Nothing is gained by trying the next item.
    private static func stopsEveryRequest(_ error: ServerError) -> Bool {
        switch error {
        case .unauthorized, .forbidden, .serverOutdated: true
        default: false
        }
    }

    // MARK: - Summaries

    func refreshSummaries() async {
        manualItems = await manual.allItems().sorted { $0.createdAt > $1.createdAt }
        guard let batches = try? await store.batches() else { return }
        var updated: [ScanBatch.ID: BatchSyncSummary] = [:]
        for batch in batches {
            let state = await store.syncState(for: batch.id)
            var summary = BatchSyncSummary()
            summary.queuedItems = await outbox.count(in: batch.id)
            summary.isClosed = state.isClosed
            if state.batchMeta.wantsUpload { summary.pendingUploads += 1 }
            if case .failed = state.batchMeta { summary.failedUploads += 1 }
            for (scanKey, scan) in state.scans {
                guard let uuid = UUID(uuidString: scanKey) else { continue }
                let scanID = ScanRecord.ID(rawValue: uuid)
                for (ref, item) in scan.items.sorted(by: { $0.key < $1.key }) {
                    switch item {
                    case .applied: summary.appliedItems += 1
                    case .terminal(let status) where status.needsAttention:
                        summary.attention.append(SyncAttention(scanID: scanID, reference: ref, kind: .ledgerItem(status, isUndo: ClientRef(ref)?.isUndo == true)))
                    case .queued, .sent, .terminal: break
                    }
                }
                for upload in [scan.record, scan.photoSmall, scan.canvas, scan.photo] {
                    if upload.wantsUpload { summary.pendingUploads += 1 }
                    if case .failed = upload { summary.failedUploads += 1 }
                }
                if case .conflict(let serverSeq) = scan.record {
                    summary.attention.append(SyncAttention(scanID: scanID, reference: "record:\(scanKey)", kind: .recordConflict(serverSeq: serverSeq)))
                }
            }
            if state.isVoided {
                if state.allItemsAcknowledged, state.rejectedUndos > 0 {
                    summary.voiding = .complete(rejectedUndos: state.rejectedUndos)
                } else {
                    // The same count that lets `completeVoidedBatches` delete
                    // the folder, so a void that is not yet derived or whose
                    // records are not yet up never reads as complete.
                    let records = (try? await store.records(in: batch.id)) ?? []
                    let remaining = voidRemaining(state, records: records, batch: batch)
                    summary.voiding = remaining > 0 ? .inProgress(remaining: remaining) : .complete(rejectedUndos: 0)
                }
            }
            updated[batch.id] = summary
        }
        summaries = updated
        queuedItems = await outbox.count
    }
}
