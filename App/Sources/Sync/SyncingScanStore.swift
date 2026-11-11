import Foundation

/// The live `ScanStoring`: wraps the file store at the one seam every model
/// uses and keeps, beside it, what the server has acknowledged (ADR-002,
/// decision 4). Writes go `scans.json` first, then
/// `<sync directory>/<batch id>/sync.json`, so a crash between the two leaves
/// a decision the next `SyncEngine.reconcile()` picks up, never an
/// acknowledgement for a decision that does not exist.
///
/// The wrapped store is `any ScanStoring` rather than `FileScanStore` so the
/// tests can wrap `InMemoryScanStore` and the engine tests need no disk for
/// the scans themselves; only `sync.json` and the outbox touch the file system.
actor SyncingScanStore: ScanStoring, ScanRecordStamping {
    /// What changed, for the engine's triggers.
    nonisolated enum Event: Hashable, Sendable {
        case decided(ScanBatch.ID)
        case batchSaved(ScanBatch.ID)
        case voided(ScanBatch.ID)
        case deleted(ScanBatch.ID)
    }

    private let inner: any ScanStoring
    private let directory: URL
    private let now: @Sendable () -> Date
    private let fileManager = FileManager()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var states: [ScanBatch.ID: BatchSyncState] = [:]
    private let continuation: AsyncStream<Event>.Continuation
    /// Every change, in order; the sync engine is the one consumer.
    nonisolated let events: AsyncStream<Event>

    init(inner: any ScanStoring, directory: URL, now: @escaping @Sendable () -> Date) {
        self.inner = inner
        self.directory = directory
        self.now = now
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        (events, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
    }

    // MARK: - ScanStoring

    func batches() async throws -> [ScanBatch] {
        try await inner.batches()
    }

    func records(in batch: ScanBatch.ID) async throws -> [ScanRecord] {
        try await inner.records(in: batch)
    }

    /// The wrapped store's stamp, or `nil` for a store that has none (every
    /// flush then decodes the records, as the in-memory test store does).
    func recordsStamp(for batch: ScanBatch.ID) async -> String? {
        await (inner as? any ScanRecordStamping)?.recordsStamp(for: batch)
    }

    /// Saves the batch. Its purpose is fixed once any scan in it has a
    /// decision: the items already derived from those decisions must stay
    /// true (ADR-002, decision 2).
    func save(_ batch: ScanBatch) async throws {
        if let stored = try await inner.batches().first(where: { $0.id == batch.id }), stored.purpose != batch.purpose {
            let records = try await inner.records(in: batch.id)
            if records.contains(where: { !$0.decisions.isEmpty }) {
                throw ScanStoreError.purposeImmutable(batch.id)
            }
        }
        try await inner.save(batch)
        var state = syncState(for: batch.id)
        state.batchMeta = state.batchMeta.isUploaded ? .queued : state.batchMeta
        try write(state)
        continuation.yield(.batchSaved(batch.id))
    }

    func append(_ record: ScanRecord, photo: Data, rectified: Data?) async throws {
        try await inner.append(record, photo: photo, rectified: rectified)
        try refreshScan(record)
    }

    func update(_ record: ScanRecord) async throws {
        try await inner.update(record)
        try refreshScan(record)
    }

    func update(_ records: [ScanRecord]) async throws {
        try await inner.update(records)
        for record in records {
            try refreshScan(record)
        }
    }

    func decide(_ id: ScanRecord.ID, in batch: ScanBatch.ID, _ input: DecisionInput) async throws -> ScanRecord {
        let decided = try await inner.decide(id, in: batch, input)
        try refreshScan(decided)
        continuation.yield(.decided(batch))
        return decided
    }

    func deleteBatch(_ id: ScanBatch.ID) async throws {
        try await inner.deleteBatch(id)
        states[id] = nil
        let folder = batchSyncDirectory(for: id)
        if fileManager.fileExists(atPath: folder.path(percentEncoded: false)) {
            try fileManager.removeItem(at: folder)
        }
        continuation.yield(.deleted(id))
    }

    /// Appends a `voided` decision to every scan not already voided and marks
    /// the batch; the engine removes the folder once every ledger item is
    /// acknowledged (ADR-002, §5.5).
    @discardableResult
    func voidBatch(_ id: ScanBatch.ID) async throws -> Int {
        var voided = 0
        for record in try await inner.records(in: id) where record.verdict != .voided {
            let decided = try await inner.decide(record.id, in: id, DecisionInput(.voided, source: .human))
            try refreshScan(decided)
            voided += 1
        }
        var state = syncState(for: id)
        if state.voidedAt == nil {
            state.voidedAt = now()
        }
        try write(state)
        continuation.yield(.voided(id))
        return voided
    }

    nonisolated func batchDirectory(for id: ScanBatch.ID) -> URL {
        inner.batchDirectory(for: id)
    }

    nonisolated func photoURL(for record: ScanRecord) -> URL {
        inner.photoURL(for: record)
    }

    nonisolated func rectifiedURL(for record: ScanRecord) -> URL? {
        inner.rectifiedURL(for: record)
    }

    // MARK: - Sync state

    nonisolated func batchSyncDirectory(for id: ScanBatch.ID) -> URL {
        directory.appending(path: id.rawValue.uuidString, directoryHint: .isDirectory)
    }

    nonisolated func syncFileURL(for id: ScanBatch.ID) -> URL {
        batchSyncDirectory(for: id).appending(path: "sync.json")
    }

    /// What `sync.json` says, or a fresh state when there is none yet.
    func syncState(for id: ScanBatch.ID) -> BatchSyncState {
        if let cached = states[id] { return cached }
        let url = syncFileURL(for: id)
        let loaded = (try? decoder.decode(BatchSyncState.self, from: Data(contentsOf: url))) ?? BatchSyncState(batchID: id)
        states[id] = loaded
        return loaded
    }

    /// Changes one batch's state and writes it, after `scans.json`.
    func updateSyncState(for id: ScanBatch.ID, _ change: @Sendable (inout BatchSyncState) -> Void) throws {
        var state = syncState(for: id)
        change(&state)
        try write(state)
    }

    /// Marks the batch closed: no more scans belong in it, and A5's pruner
    /// may start deleting acknowledged photos.
    func closeBatch(_ id: ScanBatch.ID) throws {
        try updateSyncState(for: id) { state in
            if state.closedAt == nil {
                state.closedAt = now()
            }
        }
    }

    /// Brings a scan's upload states in line with its decisions: a longer log
    /// re-queues the record, and the tiers it now qualifies for are queued.
    private func refreshScan(_ record: ScanRecord) throws {
        try updateSyncState(for: record.batchID) { state in
            state[record.id] = Self.refreshed(state[record.id], for: record)
        }
    }

    /// The pure part of `refreshScan`, shared with the engine's reconcile.
    nonisolated static func refreshed(_ scan: ScanSyncState, for record: ScanRecord) -> ScanSyncState {
        var scan = scan
        if UploadTiers.wantsRecord(record) {
            switch scan.record {
            case .conflict: break
            case .notEligible: scan.record = .queued
            case .uploaded, .queued, .failed:
                if record.decisions.count > scan.uploadedSeq { scan.record = .queued }
            }
        }
        let eligible = UploadTiers.eligibleAssets(for: record)
        for kind in eligible where scan[kind] == .notEligible {
            scan[kind] = .queued
        }
        // A full photo queued only so another device could review the scan
        // (ADR-003) is not worth sending once a decision made here first
        // earns none.
        if !record.decisions.isEmpty, !eligible.contains(.photo), scan.photo == .queued {
            scan.photo = .notEligible
        }
        if record.verdict == .voided {
            // Whatever was still owed for this scan is no longer worth the bytes.
            for kind in AssetKind.allCases where scan[kind].wantsUpload {
                scan[kind] = .notEligible
            }
        }
        return scan
    }

    private func write(_ state: BatchSyncState) throws {
        if states[state.batchID] == state, fileManager.fileExists(atPath: syncFileURL(for: state.batchID).path(percentEncoded: false)) {
            return
        }
        states[state.batchID] = state
        let folder = batchSyncDirectory(for: state.batchID)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(state).write(to: syncFileURL(for: state.batchID), options: .atomic)
    }
}

extension SyncingScanStore: ServerHeldMarking {
    /// The batch came from the server, so it is already there.
    func markBatchHeldByServer(_ id: ScanBatch.ID) throws {
        let at = now()
        try updateSyncState(for: id) { state in
            if !state.batchMeta.isUploaded {
                state.batchMeta = .uploaded(at)
            }
        }
    }

    /// The record and the assets came from the server: nothing is owed until
    /// a decision made here extends the log.
    func markHeldByServer(_ record: ScanRecord, assets: Set<AssetKind>) throws {
        let at = now()
        try updateSyncState(for: record.batchID) { state in
            state[record.id].record = .uploaded(at)
            state[record.id].uploadedSeq = record.decisions.count
            for kind in assets {
                state[record.id][kind] = .uploaded(at)
            }
        }
    }
}
