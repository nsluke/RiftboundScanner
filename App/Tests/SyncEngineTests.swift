import Foundation
import Testing
@testable import RiftboundScannerApp

/// Fixed bytes for every asset, so the drain's requests can be counted.
nonisolated struct StubAssetProvider: ScanAssetProviding {
    var bytes = Data(repeating: 0xAB, count: 16)

    func asset(_ kind: AssetKind, for record: ScanRecord) async throws -> Data? { bytes }
}

/// An in-memory store that stamps its records the way `FileScanStore` stamps
/// `scans.json` (every write moves the stamp) and counts every decode, so a
/// test can see when the engine reads a batch's records and when it skips them.
actor StampedScanStore: ScanStoring, ScanRecordStamping {
    private let inner: InMemoryScanStore
    private var versions: [ScanBatch.ID: Int] = [:]
    private(set) var recordReads: [ScanBatch.ID: Int] = [:]

    init(inner: InMemoryScanStore) {
        self.inner = inner
    }

    func recordsStamp(for batch: ScanBatch.ID) -> String? { "v\(versions[batch, default: 0])" }

    private func touch(_ batch: ScanBatch.ID) { versions[batch, default: 0] += 1 }

    func batches() async -> [ScanBatch] { await inner.batches() }

    func records(in batch: ScanBatch.ID) async throws -> [ScanRecord] {
        recordReads[batch, default: 0] += 1
        return await inner.records(in: batch)
    }

    func save(_ batch: ScanBatch) async { await inner.save(batch) }

    func append(_ record: ScanRecord, photo: Data, rectified: Data?) async throws {
        try await inner.append(record, photo: photo, rectified: rectified)
        touch(record.batchID)
    }

    func update(_ record: ScanRecord) async throws {
        try await inner.update(record)
        touch(record.batchID)
    }

    func update(_ records: [ScanRecord]) async throws {
        try await inner.update(records)
        for record in records { touch(record.batchID) }
    }

    func decide(_ id: ScanRecord.ID, in batch: ScanBatch.ID, _ input: DecisionInput) async throws -> ScanRecord {
        let decided = try await inner.decide(id, in: batch, input)
        touch(batch)
        return decided
    }

    func deleteBatch(_ id: ScanBatch.ID) async {
        await inner.deleteBatch(id)
        versions[id] = nil
    }

    nonisolated func batchDirectory(for id: ScanBatch.ID) -> URL { inner.batchDirectory(for: id) }
    nonisolated func photoURL(for record: ScanRecord) -> URL { inner.photoURL(for: record) }
    nonisolated func rectifiedURL(for record: ScanRecord) -> URL? { inner.rectifiedURL(for: record) }
}

/// The engine against an in-memory scan store, a scripted server and a
/// hand-advanced clock; only `sync.json` and `outbox.json` touch the disk.
@MainActor
@Suite("Sync engine")
struct SyncEngineTests {
    /// Everything one test needs, built the way the composition root builds it.
    @MainActor
    final class World {
        let directory: URL
        let inner: InMemoryScanStore
        let store: SyncingScanStore
        let outbox: Outbox
        let manual: ManualItemStore
        let client: StubCollectionClient
        let endpoints: FixedEndpoints
        let paths: ScriptedPaths
        let clock: TestClock
        let batch: ScanBatch
        let engine: SyncEngine

        /// What `SyncingScanStore` wraps: the in-memory store itself, or a
        /// test's wrapper around it (`wrapping`).
        let wrapped: any ScanStoring

        init(
            purpose: BatchPurpose = .collection,
            health: HealthReport = HealthReport(userVersion: 5, catalogVersion: "cat-1"),
            policy: SyncEngine.Policy = SyncEngine.Policy(),
            wrapping: ((InMemoryScanStore) -> any ScanStoring)? = nil
        ) async throws {
            directory = URL.temporaryDirectory.appending(path: "SyncEngineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            inner = InMemoryScanStore()
            wrapped = wrapping?(inner) ?? inner
            store = SyncingScanStore(inner: wrapped, directory: directory, now: { Fixtures.epoch })
            outbox = Outbox(fileURL: directory.appending(path: "outbox.json"))
            manual = ManualItemStore(fileURL: directory.appending(path: "manual.json"))
            client = StubCollectionClient()
            endpoints = FixedEndpoints(.available(.lan, health: health))
            paths = ScriptedPaths(.wifi)
            clock = TestClock()
            batch = Fixtures.batch(purpose: purpose, defaultFinish: .normal)
            engine = World.makeEngine(store: store, outbox: outbox, manual: manual, client: client, endpoints: endpoints, paths: paths, clock: clock, policy: policy)
            try await store.save(batch)
        }

        static func makeEngine(store: SyncingScanStore, outbox: Outbox, manual: ManualItemStore, client: StubCollectionClient, endpoints: FixedEndpoints, paths: ScriptedPaths, clock: TestClock, policy: SyncEngine.Policy = SyncEngine.Policy()) -> SyncEngine {
            SyncEngine(
                store: store,
                outbox: outbox,
                manual: manual,
                client: client,
                endpoints: endpoints,
                paths: paths,
                vault: Fixtures.vault,
                device: "iPhone17,1",
                uploads: RecordUploadComposer(),
                assets: StubAssetProvider(),
                now: { Fixtures.epoch },
                sleep: { try await clock.sleep(for: $0) },
                policy: policy
            )
        }

        /// A fresh engine, store and outbox over the same files and records: a relaunch.
        func relaunched() -> World {
            World(copying: self)
        }

        private init(copying other: World) {
            directory = other.directory
            inner = other.inner
            wrapped = other.wrapped
            store = SyncingScanStore(inner: other.wrapped, directory: other.directory, now: { Fixtures.epoch })
            outbox = Outbox(fileURL: other.directory.appending(path: "outbox.json"))
            manual = ManualItemStore(fileURL: other.directory.appending(path: "manual.json"))
            client = other.client
            endpoints = other.endpoints
            paths = other.paths
            clock = other.clock
            batch = other.batch
            engine = World.makeEngine(store: store, outbox: outbox, manual: manual, client: client, endpoints: endpoints, paths: paths, clock: clock)
        }

        @discardableResult
        func decide(_ record: ScanRecord, _ verdict: Verdict, source: DecisionSource = .human, finish: Override<Finish> = .inherit) async throws -> ScanRecord {
            try await store.decide(record.id, in: batch.id, DecisionInput(verdict, source: source, finish: finish))
        }

        /// A new pending scan appended to the batch.
        func scan() async throws -> ScanRecord {
            let record = Fixtures.record(batch: batch.id, analysis: Fixtures.analysis(for: Fixtures.result(cards: [Fixtures.vi, Fixtures.jinx])), engine: Fixtures.engineStamp)
            try await store.append(record, photo: Data(), rectified: nil)
            return record
        }

        func state(of record: ScanRecord) async -> ScanSyncState {
            await store.syncState(for: batch.id)[record.id]
        }

        func sentRefs() async -> [[String]] {
            await client.recording.syncRequests.map { $0.items.map(\.clientRef) }
        }

        /// The `undo_of` of every undo in the last request sent.
        func lastUndoTargets() async -> [String] {
            await client.recording.syncRequests.last?.items.compactMap { item in
                if case .undo(let undo) = item { return undo.undoOf }
                return nil
            } ?? []
        }
    }

    /// Polls until `condition` holds or a second of real time passes.
    private func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<2000 {
            if await condition() { return true }
            try? await Task.sleep(for: .microseconds(500))
        }
        return await condition()
    }

    // MARK: - Reconcile and the rebuildable outbox

    @Test func deletingTheOutboxBetweenDecisionsAndAFlushSendsIdenticalItems() async throws {
        let world = try await World()
        for _ in 0..<3 {
            try await world.decide(try await world.scan(), .correct)
        }
        try await world.engine.reconcile()
        let expected = await world.outbox.allEntries().map(\.item)
        #expect(expected.count == 3)
        #expect(FileManager.default.fileExists(atPath: world.directory.appending(path: "outbox.json").path(percentEncoded: false)))

        try FileManager.default.removeItem(at: world.directory.appending(path: "outbox.json"))
        let relaunched = world.relaunched()
        #expect(await relaunched.outbox.isEmpty)
        await relaunched.engine.flush()

        let requests = await relaunched.client.recording.syncRequests
        #expect(requests.count == 1)
        #expect(Set(requests.first?.items ?? []) == Set(expected), "the same items, rebuilt from scans.json and sync.json")
        #expect(requests.first?.device == "iPhone17,1")
        #expect(relaunched.engine.status == .idle)
        #expect(relaunched.engine.queuedItems == 0)
        #expect(await relaunched.outbox.isEmpty)
    }

    @Test func truncatingSyncJSONReDerivesAndADuplicateAnswerDoesNotDoubleCount() async throws {
        let world = try await World()
        let record = try await world.scan()
        try await world.decide(record, .correct)
        await world.engine.flush()
        let ref = ClientRef.plusOne(record.id, seq: 1)
        #expect(await world.state(of: record)[ref] == .applied(ledgerID: 1, cardID: "OGN-001", finish: nil))
        #expect(world.engine.ledgerGeneration == 1)
        #expect(world.engine.summary(for: world.batch.id)?.appliedItems == 1)

        try Data().write(to: world.store.syncFileURL(for: world.batch.id))
        let relaunched = world.relaunched()
        await relaunched.client.update { $0.defaultItemStatus = .duplicate }
        await relaunched.engine.flush()

        let sent = await relaunched.sentRefs()
        #expect(sent == [[ref.description], [ref.description]], "the same reference again, never a new one")
        #expect(await relaunched.state(of: record)[ref] == .applied(ledgerID: 1, cardID: "OGN-001", finish: nil), "the server's row, as live as the first time it was reported")
        #expect(relaunched.engine.ledgerGeneration == 0, "a duplicate changed no holding")
        #expect(relaunched.engine.summary(for: world.batch.id)?.attention.isEmpty == true, "a clean replay needs no attention")
        #expect(relaunched.engine.summary(for: world.batch.id)?.appliedItems == 1)
        #expect(await relaunched.outbox.isEmpty)

        // The row the server holds under the replayed reference is undone by it.
        await relaunched.client.update { $0.defaultItemStatus = .applied }
        try await relaunched.store.voidBatch(world.batch.id)
        await relaunched.engine.flush()
        #expect(await relaunched.sentRefs().last == [ClientRef.undo(record.id, seq: 2).description])
        #expect(await relaunched.lastUndoTargets() == [ref.description])
        #expect(try await relaunched.store.batches().isEmpty, "the undo landed; the folder goes")
    }

    @Test func aFlushDecodesABatchOnceAndASettledUnchangedBatchNotAtAll() async throws {
        let world = try await World(wrapping: { StampedScanStore(inner: $0) })
        let stamped = try #require(world.wrapped as? StampedScanStore)
        let accepted = try await world.scan()
        let corrected = try await world.scan()
        try await world.decide(accepted, .correct, source: .autoAccepted)
        try await world.decide(corrected, .corrected(Fixtures.jinx.id))
        await world.engine.flush()
        let recording = await world.client.recording
        #expect(recording.syncRequests.count == 1 && recording.scans.count == 2 && recording.assets.count == 4, "everything drained")
        #expect(await stamped.recordReads[world.batch.id] == 1, "reconcile, the meta, record and three asset drains share one decode")
        #expect(world.engine.summary(for: world.batch.id)?.isSettled == true)

        await world.engine.flush()
        await world.engine.flush()
        #expect(await stamped.recordReads[world.batch.id] == 1, "a settled batch with an unchanged stamp is not decoded again")
        #expect(world.engine.status == .idle)

        // A decision moves the stamp (and re-queues the record), so the batch is read again, once.
        try await world.decide(accepted, .correct, source: .spotCheck)
        await world.engine.flush()
        #expect(await stamped.recordReads[world.batch.id] == 2)
        #expect(await world.client.recording.scans.count == 3, "the longer log went up")

        // Written behind the seam, as a file edit would be: the stamp still moves, so it is seen.
        _ = try await stamped.decide(corrected.id, in: world.batch.id, DecisionInput(.correct, source: .spotCheck))
        await world.engine.flush()
        #expect(await stamped.recordReads[world.batch.id] == 3)
        #expect(await world.client.recording.scans.count == 4)
    }

    @Test func aDecisionWrittenBehindTheStoreIsSentAfterReconcile() async throws {
        let world = try await World()
        let record = try await world.scan()
        // Decided through the wrapped store: no sync.json update, no event, no outbox item.
        _ = try await world.inner.decide(record.id, in: world.batch.id, DecisionInput(.correct, source: .human))
        #expect(await world.state(of: record).items.isEmpty)
        #expect(await world.outbox.isEmpty)

        await world.engine.flush()
        #expect(await world.sentRefs() == [[ClientRef.plusOne(record.id, seq: 1).description]])
        let state = await world.state(of: record)
        #expect(state[.plusOne(record.id, seq: 1)]?.isApplied == true)
        #expect(state.record.isUploaded, "the record goes up too")
        #expect(state.uploadedSeq == 1)
    }

    @Test func reconcileDropsEntriesForDeletedScansAndBatches() async throws {
        let world = try await World()
        let record = try await world.scan()
        try await world.decide(record, .correct)
        await world.endpoints.set(.unavailable(.noPath))
        await world.engine.flush()
        #expect(await world.outbox.count == 1)
        #expect(world.engine.status == .offline(.noPath))

        try await world.inner.deleteBatch(world.batch.id)
        await world.engine.flush()
        #expect(await world.outbox.isEmpty)
    }

    // MARK: - Per-item outcomes

    @Test func aMixedPageIsRecordedPerItem() async throws {
        let world = try await World()
        let record = try await world.scan()
        try await world.decide(record, .correct, source: .autoAccepted)
        await world.engine.flush()
        let undo = ClientRef.undo(record.id, seq: 2)
        let plus = ClientRef.plusOne(record.id, seq: 2)
        await world.client.update { $0.itemStatuses[undo.description] = .nothingToUndo }

        try await world.decide(record, .corrected(Fixtures.jinx.id))
        await world.engine.flush()

        #expect(await world.sentRefs().last == [undo.description, plus.description], "the undo goes before the +1")
        let state = await world.state(of: record)
        #expect(state[undo] == .terminal(.nothingToUndo))
        #expect(state[plus] == .applied(ledgerID: 2, cardID: "OGN-002", finish: nil))
        let summary = try #require(world.engine.summary(for: world.batch.id))
        #expect(summary.attention.map(\.reference) == [undo.description])
        #expect(summary.attention.first?.kind == .ledgerItem(.nothingToUndo, isUndo: true))
        #expect(summary.appliedItems == 2)
        #expect(summary.queuedItems == 0)
        #expect(summary.isSettled)
    }

    @Test func unknownCardReQueuesWhenTheCatalogChangesAndInvalidNeverDoes() async throws {
        let world = try await World()
        let unknown = try await world.scan()
        let invalid = try await world.scan()
        try await world.decide(unknown, .correct)
        try await world.decide(invalid, .correct)
        let unknownRef = ClientRef.plusOne(unknown.id, seq: 1).description
        let invalidRef = ClientRef.plusOne(invalid.id, seq: 1).description
        await world.client.update {
            $0.itemStatuses[unknownRef] = .unknownCard
            $0.itemStatuses[invalidRef] = .invalid
        }
        await world.engine.flush()
        #expect(await world.state(of: unknown)[.plusOne(unknown.id, seq: 1)] == .terminal(.unknownCard(catalogVersion: "cat-1")))
        #expect(await world.state(of: invalid)[.plusOne(invalid.id, seq: 1)] == .terminal(.invalid))
        #expect(world.engine.catalogVersion == "cat-1")
        #expect(world.engine.summary(for: world.batch.id)?.attention.count == 2)

        // Same catalog: nothing to resend.
        await world.engine.flush()
        #expect(await world.client.recording.syncRequests.count == 1)

        await world.endpoints.set(.available(.lan, health: HealthReport(userVersion: 5, catalogVersion: "cat-2")))
        await world.client.update { $0.itemStatuses = [:] }
        await world.engine.flush()
        let sent = await world.sentRefs()
        #expect(sent.count == 2)
        #expect(sent.last == [unknownRef], "only the unknown card is retried, unchanged")
        #expect(await world.state(of: unknown)[.plusOne(unknown.id, seq: 1)]?.isApplied == true)
        #expect(await world.state(of: invalid)[.plusOne(invalid.id, seq: 1)] == .terminal(.invalid))
        #expect(world.engine.catalogVersion == "cat-2")
    }

    @Test func aRecordConflictIsTerminal() async throws {
        let world = try await World()
        let record = try await world.scan()
        try await world.decide(record, .correct)
        await world.client.update { $0.scan = .failure(.conflict(detail: "seq_conflict", serverSeq: 3)) }
        await world.engine.flush()
        #expect(await world.state(of: record).record == .conflict(serverSeq: 3))
        #expect(await world.state(of: record).photoSmall == .queued, "assets wait for a record the server accepted")
        #expect(world.engine.status == .idle, "a conflict is this scan's problem, not the sync's")
        let summary = try #require(world.engine.summary(for: world.batch.id))
        #expect(summary.attention.map(\.kind) == [.recordConflict(serverSeq: 3)])

        await world.client.update { $0.scan = .success(ScanUploadReceipt(outcome: .updated)) }
        try await world.decide(record, .correct, source: .spotCheck)
        await world.engine.flush()
        #expect(await world.client.recording.scans.count == 1, "never retried, even after another decision")
        #expect(await world.state(of: record).record == .conflict(serverSeq: 3))
    }

    @Test func voidingCompletesWithARefusedUndoCountedAsRejected() async throws {
        let world = try await World()
        let kept = try await world.scan()
        let emptied = try await world.scan()
        try await world.decide(kept, .correct)
        try await world.decide(emptied, .correct)
        await world.engine.flush()
        #expect(world.engine.summary(for: world.batch.id)?.appliedItems == 2)

        await world.client.update { $0.itemStatuses[ClientRef.undo(emptied.id, seq: 2).description] = .wouldGoNegative }
        try await world.store.voidBatch(world.batch.id)
        #expect(try await world.store.records(in: world.batch.id).allSatisfy { $0.verdict == .voided })
        await world.engine.flush()

        let sent = await world.sentRefs()
        #expect(Set(sent.last ?? []) == [ClientRef.undo(kept.id, seq: 2).description, ClientRef.undo(emptied.id, seq: 2).description])
        let summary = try #require(world.engine.summary(for: world.batch.id))
        #expect(summary.voiding == .complete(rejectedUndos: 1))
        #expect(summary.attention.map(\.kind) == [.ledgerItem(.wouldGoNegative, isUndo: true)])
        #expect(try await world.store.batches().count == 1, "a refused undo keeps the folder so the count stays visible")
        #expect(await world.state(of: emptied).rejectedUndos == 1)
        #expect(await world.state(of: kept).rejectedUndos == 0)
    }

    @Test func voidingRemovesTheFolderOnceEveryUndoIsAcknowledged() async throws {
        let world = try await World()
        let first = try await world.scan()
        let unsent = try await world.scan()
        try await world.decide(first, .correct)
        await world.engine.flush()
        try await world.decide(unsent, .correct)
        #expect(await world.outbox.isEmpty, "the second +1 is derived at the next flush")

        try await world.store.voidBatch(world.batch.id)
        await world.engine.flush()
        let sent = await world.sentRefs()
        #expect(sent.last == [ClientRef.undo(first.id, seq: 2).description], "the never-sent +1 is withdrawn, not undone")
        #expect(try await world.store.batches().isEmpty, "every item acknowledged, no refusals: the folder is gone")
        #expect(!FileManager.default.fileExists(atPath: world.store.batchSyncDirectory(for: world.batch.id).path(percentEncoded: false)))
        #expect(world.engine.summary(for: world.batch.id) == nil)
    }

    @Test func aVoidedBatchIsKeptUntilTheServerHoldsItsRecords() async throws {
        let world = try await World()
        let record = try await world.scan()
        try await world.decide(record, .correct)
        await world.engine.flush()
        #expect(await world.state(of: record).record.isUploaded)

        await world.client.update { $0.scan = .failure(.payloadTooLarge) }
        try await world.store.voidBatch(world.batch.id)
        await world.engine.flush()
        #expect(await world.sentRefs().last == [ClientRef.undo(record.id, seq: 2).description])
        #expect(await world.state(of: record)[.undo(record.id, seq: 2)]?.isApplied == true, "the holding is right")
        #expect(await world.state(of: record).record == .failed(ServerError.payloadTooLarge.message))
        #expect(try await world.store.batches().count == 1, "the voided decision exists only here until the server has it")
        #expect(world.engine.summary(for: world.batch.id)?.voiding == .inProgress(remaining: 1))
        #expect(world.engine.summary(for: world.batch.id)?.failedUploads == 1)

        await world.client.update { $0.scan = .success(ScanUploadReceipt(outcome: .updated)) }
        await world.engine.flush()
        #expect(await world.client.recording.scans.count == 3, "the voided record was tried again and accepted")
        #expect(try await world.store.batches().isEmpty, "now the server knows about the void")
    }

    @Test func aVoidNotYetDrainedReadsAsInProgress() async throws {
        let world = try await World()
        let record = try await world.scan()
        try await world.decide(record, .correct)
        await world.engine.flush()
        try await world.store.voidBatch(world.batch.id)
        await world.engine.refreshSummaries()
        #expect(world.engine.summary(for: world.batch.id)?.voiding == .inProgress(remaining: 2), "the undo not yet derived and the voided record not yet up")

        await world.engine.flush()
        #expect(try await world.store.batches().isEmpty)
    }

    @Test func voidingACalibrationBatchRemovesItAtOnce() async throws {
        let world = try await World(purpose: .calibration)
        let record = try await world.scan()
        try await world.decide(record, .correct)
        try await world.store.voidBatch(world.batch.id)
        await world.engine.flush()
        #expect(await world.client.recording.syncRequests.isEmpty)
        #expect(try await world.store.batches().isEmpty)
    }

    @Test func aVoidWrittenDuringADrainIsNotClobbered() async throws {
        let world = try await World()
        let record = try await world.scan()
        try await world.decide(record, .correct)
        await world.client.holdScans(true)
        let flushing = Task { await world.engine.flush() }
        #expect(await eventually { await world.client.heldScans == 1 }, "the record upload is in flight")

        try await world.store.voidBatch(world.batch.id)
        try await world.store.closeBatch(world.batch.id)
        await world.client.holdScans(false)
        await flushing.value

        let state = await world.store.syncState(for: world.batch.id)
        #expect(state.isVoided, "the void written mid-drain survives the drain's own write")
        #expect(state.isClosed)
        #expect(state[record.id].record.isUploaded)
        #expect(state[record.id].uploadedSeq == 1, "the server saw one decision; the voided one is still owed")
        #expect(try await world.store.batches().count == 1, "the undo has not been derived yet, so the folder stays")
        #expect(await world.client.recording.assets.isEmpty, "a voided scan's assets are not worth sending")

        await world.engine.flush()
        #expect(await world.sentRefs().last == [ClientRef.undo(record.id, seq: 2).description])
        #expect(await world.client.recording.scans.count == 2, "the voided record goes up")
        #expect(try await world.store.batches().isEmpty, "every item acknowledged: the folder goes")
    }

    @Test func aPlusOneSentWithoutAnAnswerIsReplayedAndUndoneAfterARejection() async throws {
        let world = try await World()
        let record = try await world.scan()
        try await world.decide(record, .correct, source: .autoAccepted)
        await world.client.update { $0.syncFailure = .timedOut }
        await world.engine.flush()
        let plus = ClientRef.plusOne(record.id, seq: 1)
        #expect(await world.state(of: record)[plus] == .sent, "handed to the server, no answer")
        #expect(world.engine.summary(for: world.batch.id)?.queuedItems == 1)

        // The server did commit it; only the answer was lost.
        await world.client.update {
            $0.syncFailure = nil
            $0.itemStatuses[plus.description] = .duplicate
        }
        try await world.decide(record, .rejected(.notACard))
        await world.engine.flush()
        let undo = ClientRef.undo(record.id, seq: 2)
        #expect(await world.sentRefs().last == [plus.description, undo.description], "replay first, then reverse by reference")
        #expect(await world.state(of: record)[plus] == .applied(ledgerID: 1, cardID: "OGN-001", finish: nil), "the row the first request committed")
        #expect(await world.state(of: record)[undo]?.isApplied == true, "the stale row is gone from the holding")
        #expect(world.engine.ledgerGeneration == 1, "the undo changed a holding; the duplicate did not")
        #expect(world.engine.summary(for: world.batch.id)?.attention.isEmpty == true)
        #expect(world.engine.status == .idle)
    }

    /// The normal outcome of a lost answer: the 5 s retry replays the +1 on its
    /// own, the server says `duplicate`, and only later does the user change
    /// their mind. The undo must still name that row.
    @Test func aPlusOneAnsweredDuplicateOnRetryIsUndoneByALaterRejection() async throws {
        let world = try await World()
        let record = try await world.scan()
        try await world.decide(record, .correct, source: .autoAccepted)
        await world.client.update { $0.syncFailure = .timedOut }
        await world.engine.flush()
        let plus = ClientRef.plusOne(record.id, seq: 1)
        #expect(await world.state(of: record)[plus] == .sent)

        await world.client.update {
            $0.syncFailure = nil
            $0.itemStatuses[plus.description] = .duplicate
        }
        await world.engine.flush()
        #expect(await world.sentRefs() == [[plus.description], [plus.description]], "the retry replays the same reference")
        #expect(await world.state(of: record)[plus] == .applied(ledgerID: 1, cardID: "OGN-001", finish: nil))
        #expect(world.engine.ledgerGeneration == 0, "no holding changed")
        #expect(world.engine.summary(for: world.batch.id)?.attention.isEmpty == true)
        #expect(world.engine.summary(for: world.batch.id)?.appliedItems == 1)
        #expect(world.engine.status == .idle)

        try await world.decide(record, .rejected(.notACard))
        await world.engine.flush()
        let undo = ClientRef.undo(record.id, seq: 2)
        #expect(await world.sentRefs().last == [undo.description], "the row is reversed by reference, nothing replayed")
        #expect(await world.lastUndoTargets() == [plus.description])
        #expect(await world.state(of: record)[undo]?.isApplied == true)
        #expect(world.engine.ledgerGeneration == 1)
        #expect(await world.outbox.isEmpty)
    }

    /// The server gives 422 only for a request shape it does not accept
    /// (too many items, a missing field); a per-item problem is a per-item
    /// `invalid`. So a 422 is never one item's fault: nothing is marked
    /// invalid, the items stay owed, and the detail is shown.
    @Test func aRefusedPageLeavesEveryItemOwedAndSurfacesTheDetail() async throws {
        let world = try await World()
        var records: [ScanRecord] = []
        for _ in 0..<3 {
            let record = try await world.scan()
            try await world.decide(record, .correct, source: .autoAccepted)
            records.append(record)
        }
        let refusal = ServerError.unprocessable(detail: "items: at most 100 items per request")
        await world.client.update { $0.syncFailure = refusal }
        await world.engine.flush()

        for record in records {
            #expect(await world.state(of: record)[.plusOne(record.id, seq: 1)] == .sent, "handed over, unanswered, never invalid")
        }
        #expect(await world.outbox.count == 3, "still owed")
        #expect(await world.client.recording.syncRequests.count == 1, "no bisection: the page was not refused for an item")
        #expect(world.engine.status == .failed(refusal.message))
        #expect(refusal.message.contains("at most 100 items"), "the server's detail reaches the user")
        #expect(await world.client.recording.scans.count == 3, "records still go up")
        let summary = try #require(world.engine.summary(for: world.batch.id))
        #expect(summary.attention.isEmpty, "nothing for the user to act on per item")
        #expect(summary.queuedItems == 3)

        // A server that accepts the shape again receives the same items.
        await world.client.update { $0.syncFailure = nil }
        await world.engine.flush()
        #expect(await world.outbox.isEmpty)
        #expect(await world.sentRefs().last?.count == 3)
        #expect(world.engine.status == .idle)
    }

    @Test func aRefusedLedgerRouteLeavesItemsSentAndStillDrainsRecords() async throws {
        let world = try await World()
        let record = try await world.scan()
        try await world.decide(record, .correct)
        await world.client.update { $0.syncFailure = .notFound }
        await world.engine.flush()
        #expect(await world.state(of: record)[.plusOne(record.id, seq: 1)] == .sent)
        #expect(await world.outbox.count == 1, "still owed")
        #expect(world.engine.status == .failed(ServerError.notFound.message))
        #expect(await world.client.recording.scans.count == 1, "the ledger's trouble does not hold the records")
    }

    // MARK: - Transport

    @Test func transportFailuresBackOffFromFiveSecondsToFiveMinutes() async throws {
        let world = try await World()
        try await world.decide(try await world.scan(), .correct)
        await world.client.update { $0.syncFailure = .timedOut }
        await world.engine.flush()
        #expect(world.engine.status == .waiting(retryAt: Fixtures.epoch.addingTimeInterval(5), error: .timedOut))
        #expect(await world.client.recording.syncRequests.count == 1)
        #expect(await world.outbox.count == 1, "the item stays owed")

        world.clock.advance(by: .seconds(5))
        #expect(await eventually { world.engine.flushCount == 2 })
        #expect(world.engine.status == .waiting(retryAt: Fixtures.epoch.addingTimeInterval(10), error: .timedOut))

        world.clock.advance(by: .seconds(10))
        #expect(await eventually { world.engine.flushCount == 3 })
        #expect(world.engine.status == .waiting(retryAt: Fixtures.epoch.addingTimeInterval(20), error: .timedOut))

        await world.client.update { $0.syncFailure = nil }
        world.clock.advance(by: .seconds(20))
        #expect(await eventually { world.engine.flushCount == 4 })
        #expect(world.engine.status == .idle)
        #expect(world.engine.lastSyncedAt == Fixtures.epoch)
        #expect(await world.outbox.isEmpty)

        // The ladder tops out at five minutes.
        let capped = try await World(policy: SyncEngine.Policy(minimumBackoff: .seconds(200), maximumBackoff: .seconds(300)))
        try await capped.decide(try await capped.scan(), .correct)
        await capped.client.update { $0.syncFailure = .unreachable("refused") }
        await capped.engine.flush()
        #expect(capped.engine.status == .waiting(retryAt: Fixtures.epoch.addingTimeInterval(200), error: .unreachable("refused")))
        capped.clock.advance(by: .seconds(200))
        #expect(await eventually { capped.engine.flushCount == 2 })
        #expect(capped.engine.status == .waiting(retryAt: Fixtures.epoch.addingTimeInterval(300), error: .unreachable("refused")))
    }

    @Test func noEndpointIsOfflineAndSendsNothing() async throws {
        let world = try await World()
        let record = try await world.scan()
        try await world.decide(record, .correct)
        await world.endpoints.set(.unavailable(.cellularOnly))
        await world.engine.flush()
        #expect(world.engine.status == .offline(.cellularOnly))
        #expect(await world.client.recording.syncRequests.isEmpty)
        #expect(await world.outbox.count == 1)
        #expect(world.engine.summary(for: world.batch.id)?.queuedItems == 1)

        await world.endpoints.set(.available(.lan, health: HealthReport(userVersion: 5, catalogVersion: "cat-1")))
        await world.engine.retryNow()
        #expect(await world.endpoints.invalidations == 1)
        #expect(await world.outbox.isEmpty)
        #expect(world.engine.status == .idle)
    }

    @Test func aRejectedTokenStopsTheFlushWithoutBackoff() async throws {
        let world = try await World()
        try await world.decide(try await world.scan(), .correct)
        await world.client.update { $0.syncFailure = .unauthorized }
        await world.engine.flush()
        #expect(world.engine.status == .failed(ServerError.unauthorized.message))
        #expect(await world.outbox.count == 1)
    }

    // MARK: - Drain order and paging

    @Test func theLedgerGoesInPagesOfOneHundred() async throws {
        let world = try await World()
        for _ in 0..<101 {
            try await world.decide(try await world.scan(), .correct, source: .autoAccepted)
        }
        await world.engine.flush()
        let requests = await world.client.recording.syncRequests
        #expect(requests.map(\.items.count) == [100, 1])
        #expect(world.engine.summary(for: world.batch.id)?.appliedItems == 101)
    }

    @Test func drainOrderIsBatchMetaLedgerRecordsThenAssets() async throws {
        let world = try await World()
        let accepted = try await world.scan()
        let corrected = try await world.scan()
        try await world.decide(accepted, .correct, source: .autoAccepted)
        try await world.decide(corrected, .corrected(Fixtures.jinx.id))
        await world.engine.flush()

        let recording = await world.client.recording
        #expect(recording.batches.map(\.id) == [world.batch.id.rawValue])
        #expect(recording.batches.first?.purpose == "collection")
        #expect(recording.batches.first?.defaultFinish == .normal)
        #expect(recording.batches.first?.calibrationHash == Fixtures.engineStamp.calibrationHash)
        #expect(recording.syncRequests.count == 1)
        #expect(Set(recording.scans.map(\.id)) == [accepted.id.rawValue, corrected.id.rawValue])
        #expect(recording.scans.allSatisfy { $0.descriptor?.calibrationHash == Fixtures.engineStamp.calibrationHash })
        #expect(recording.scans.allSatisfy { !$0.record.containsString("http") }, "no Riot URLs leave the phone")
        let assets = recording.assets.map { ($0.scanID, $0.kind) }
        #expect(assets.filter { $0.0 == accepted.id.rawValue }.map(\.1) == [.photoSmall], "a machine decision sends photo_small only")
        #expect(assets.filter { $0.0 == corrected.id.rawValue }.map(\.1) == [.photoSmall, .canvas, .photo])
        #expect(assets.map(\.1) == [.photoSmall, .photoSmall, .canvas, .photo], "every photo_small before any canvas before any photo")

        let state = await world.store.syncState(for: world.batch.id)
        #expect(state.batchMeta == .uploaded(Fixtures.epoch))
        #expect(state[corrected.id].photo == .uploaded(Fixtures.epoch))
        #expect(state[accepted.id].canvas == .notEligible)
        #expect(world.engine.summary(for: world.batch.id)?.isSettled == true)

        await world.engine.flush()
        let again = await world.client.recording
        #expect(again.batches.count == 1 && again.scans.count == 2 && again.assets.count == 4, "nothing acknowledged is sent twice")
    }

    @Test func aDeferredRecordWaitsForItsBatch() async throws {
        let world = try await World()
        let record = try await world.scan()
        try await world.decide(record, .correct)
        await world.client.update { $0.scan = .success(ScanUploadReceipt(outcome: .updated, isDeferred: true)) }
        await world.engine.flush()
        #expect(await world.state(of: record).record == .queued)
        #expect(await world.store.syncState(for: world.batch.id).batchMeta == .queued, "the batch is sent again first")
        #expect(await world.client.recording.assets.isEmpty)
    }

    @Test func aMissingScanRouteFailsTheUploadsWithoutStoppingTheLedger() async throws {
        let world = try await World()
        let record = try await world.scan()
        try await world.decide(record, .correct)
        await world.client.update { $0.batch = .failure(.notFound) }
        await world.engine.flush()
        #expect(await world.state(of: record)[.plusOne(record.id, seq: 1)]?.isApplied == true, "the ledger still lands")
        #expect(await world.store.syncState(for: world.batch.id).batchMeta == .failed(ServerError.notFound.message))
        #expect(await world.client.recording.scans.isEmpty, "records are not tried without their batch")
        #expect(world.engine.status == .idle)
        #expect(world.engine.summary(for: world.batch.id)?.failedUploads == 1)
    }

    @Test func anUnproducibleAssetIsRecordedAsFailed() async throws {
        let world = try await World()
        let record = try await world.scan()
        try await world.decide(record, .correct, source: .autoAccepted)
        await world.client.update { $0.asset = .failure(.payloadTooLarge) }
        await world.engine.flush()
        #expect(await world.state(of: record).photoSmall == .failed(ServerError.payloadTooLarge.message))
        #expect(await world.state(of: record).record.isUploaded)
    }

    // MARK: - Triggers

    @Test func aDecisionFlushesTwoSecondsLater() async throws {
        let world = try await World()
        let running = Task { await world.engine.start() }
        #expect(await eventually { world.engine.flushCount == 1 }, "launch flushes once")

        // The batch saved before the engine started is a buffered event, so a
        // delayed flush is already pending beside the periodic one; let it fire.
        #expect(await eventually { world.clock.sleeperCount == 2 }, "the periodic flush and the buffered save's flush are asleep")
        world.clock.advance(by: .seconds(2))
        #expect(await eventually { world.engine.flushCount == 2 && world.clock.sleeperCount == 1 }, "only the periodic flush is asleep")
        #expect(await world.client.recording.syncRequests.isEmpty, "nothing to send yet")

        let record = try await world.scan()
        try await world.decide(record, .correct)
        // Move time only once the delayed flush has registered its 2 s sleep,
        // or the deadline it registers would be measured from the moved clock.
        #expect(await eventually { world.clock.sleeperCount == 2 }, "the decision scheduled a flush")
        #expect(await world.client.recording.syncRequests.isEmpty)
        world.clock.advance(by: .seconds(1))
        try await Task.sleep(for: .milliseconds(20))
        #expect(await world.client.recording.syncRequests.isEmpty, "not yet")
        world.clock.advance(by: .seconds(1))
        #expect(await eventually { await world.client.recording.syncRequests.count == 1 })
        #expect(await world.sentRefs() == [[ClientRef.plusOne(record.id, seq: 1).description]])
        running.cancel()
    }

    @Test func aPathToTheHomeNetworkTriggersAFlush() async throws {
        let world = try await World()
        await world.paths.set(.cellularOnly)
        await world.endpoints.set(.unavailable(.cellularOnly))
        let running = Task { await world.engine.start() }
        #expect(await eventually { world.engine.flushCount == 1 })
        #expect(await eventually { await world.paths.subscriberCount == 1 }, "the engine is listening for path changes")
        try await world.decide(try await world.scan(), .correct)
        #expect(world.engine.status == .offline(.cellularOnly))

        await world.paths.set(.tunnel)
        #expect(await eventually { await world.endpoints.invalidations == 1 && world.engine.flushCount == 2 }, "a utun path counts as home")
        #expect(await world.client.recording.syncRequests.isEmpty, "discovery still says no endpoint")
        #expect(world.engine.status == .offline(.cellularOnly))

        await world.endpoints.set(.available(.lan, health: HealthReport(userVersion: 5, catalogVersion: "cat-1")))
        await world.paths.set(.cellularOnly)
        #expect(await eventually { await world.paths.currentPath() == .cellularOnly })
        await world.paths.set(.wifi)
        #expect(await eventually { await world.client.recording.syncRequests.count == 1 })
        #expect(await eventually { await world.endpoints.invalidations == 2 }, "a new path forgets discovery's backoff")
        #expect(await eventually { world.engine.status == .idle })
        running.cancel()
    }

    @Test func deletingABatchClearsItsQueuedItemsAtOnce() async throws {
        let world = try await World()
        let running = Task { await world.engine.start() }
        #expect(await eventually { world.engine.flushCount == 1 })
        await world.endpoints.set(.unavailable(.noPath))
        try await world.decide(try await world.scan(), .correct)
        await world.engine.flush()
        #expect(world.engine.queuedItems == 1)
        #expect(world.engine.summary(for: world.batch.id)?.queuedItems == 1)

        try await world.store.deleteBatch(world.batch.id)
        #expect(await eventually { world.engine.queuedItems == 0 && world.engine.summary(for: world.batch.id) == nil })
        #expect(await world.outbox.isEmpty)
        running.cancel()
    }
}
