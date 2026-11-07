import Foundation
import Testing
@testable import RiftboundScannerApp

/// The live store seam: every write goes to the wrapped store first and to
/// `sync.json` second, and the file says exactly what the server still owes.
@Suite("Syncing scan store")
struct SyncingScanStoreTests {
    private let directory = URL.temporaryDirectory.appending(path: "SyncingScanStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    private let batch = Fixtures.batch(purpose: .collection, defaultFinish: .normal)

    private func makeStore(inner: InMemoryScanStore = InMemoryScanStore(), now: @escaping @Sendable () -> Date = { Fixtures.epoch }) -> SyncingScanStore {
        SyncingScanStore(inner: inner, directory: directory, now: now)
    }

    private func syncJSON(for batch: ScanBatch.ID, store: SyncingScanStore) throws -> BatchSyncState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BatchSyncState.self, from: Data(contentsOf: store.syncFileURL(for: batch)))
    }

    @Test func aDecisionWritesScansThenSyncJSON() async throws {
        let inner = InMemoryScanStore()
        let store = makeStore(inner: inner)
        try await store.save(batch)
        let record = Fixtures.record(batch: batch.id)
        try await store.append(record, photo: Data(), rectified: nil)
        #expect(try syncJSON(for: batch.id, store: store)[record.id].record == .notEligible, "a pending scan uploads nothing yet")

        let decided = try await store.decide(record.id, in: batch.id, DecisionInput(.correct, source: .autoAccepted))
        #expect(decided.decisions.map(\.seq) == [1])
        #expect(await inner.records(in: batch.id) == [decided], "scans.json holds the decision")
        let onDisk = try syncJSON(for: batch.id, store: store)
        #expect(onDisk.batchID == batch.id)
        #expect(onDisk.batchMeta == .queued)
        let scan = onDisk[record.id]
        #expect(scan.record == .queued)
        #expect(scan.photoSmall == .queued, "every decided scan sends photo_small")
        #expect(scan.canvas == .notEligible, "a machine decision earns no canvas")
        #expect(scan.photo == .notEligible)
        #expect(scan.items.isEmpty, "items are derived by the engine's reconcile, not written on decide")
        #expect(scan.uploadedSeq == 0)
    }

    @Test func humanAndCorrectedDecisionsUnlockTheirTiers() async throws {
        let store = makeStore()
        try await store.save(batch)
        let confirmed = Fixtures.record(batch: batch.id)
        let corrected = Fixtures.record(batch: batch.id)
        try await store.append(confirmed, photo: Data(), rectified: nil)
        try await store.append(corrected, photo: Data(), rectified: nil)
        _ = try await store.decide(confirmed.id, in: batch.id, DecisionInput(.correct, source: .human))
        _ = try await store.decide(corrected.id, in: batch.id, DecisionInput(.corrected(Fixtures.jinx.id), source: .human))
        let state = await store.syncState(for: batch.id)
        #expect(state[confirmed.id].canvas == .queued)
        #expect(state[confirmed.id].photo == .notEligible, "a right answer needs no full photo")
        #expect(state[corrected.id].canvas == .queued)
        #expect(state[corrected.id].photo == .queued, "a wrong recogniser answer keeps the evidence")
    }

    @Test func aLongerLogReQueuesAnUploadedRecord() async throws {
        let store = makeStore()
        try await store.save(batch)
        let record = Fixtures.record(batch: batch.id)
        try await store.append(record, photo: Data(), rectified: nil)
        _ = try await store.decide(record.id, in: batch.id, DecisionInput(.correct, source: .autoAccepted))
        try await store.updateSyncState(for: batch.id) { state in
            state[record.id].record = .uploaded(Fixtures.epoch)
            state[record.id].uploadedSeq = 1
        }
        _ = try await store.decide(record.id, in: batch.id, DecisionInput(.correct, source: .spotCheck))
        #expect(await store.syncState(for: batch.id)[record.id].record == .queued)

        try await store.updateSyncState(for: batch.id) { $0[record.id].record = .conflict(serverSeq: 5) }
        _ = try await store.decide(record.id, in: batch.id, DecisionInput(.rejected(.notACard), source: .human))
        #expect(await store.syncState(for: batch.id)[record.id].record == .conflict(serverSeq: 5), "a conflict is terminal")
    }

    @Test func thePurposeIsImmutableOnceAnyScanHasADecision() async throws {
        let store = makeStore()
        try await store.save(batch)
        let record = Fixtures.record(batch: batch.id)
        try await store.append(record, photo: Data(), rectified: nil)
        let calibration = ScanBatch(id: batch.id, startedAt: batch.startedAt, label: "renamed", device: batch.device, index: batch.index, purpose: .calibration, trainingQuality: .standard)
        try await store.save(calibration)
        #expect(try await store.batches().first?.purpose == .calibration, "before a decision the purpose may still change")

        try await store.save(batch)
        _ = try await store.decide(record.id, in: batch.id, DecisionInput(.correct, source: .human))
        await #expect(throws: ScanStoreError.purposeImmutable(batch.id)) {
            try await store.save(calibration)
        }
        var relabelled = batch
        relabelled.label = "box 1, evening"
        try await store.save(relabelled)
        #expect(try await store.batches().first?.label == "box 1, evening", "other fields still change")
        #expect(try await store.batches().first?.purpose == .collection)
    }

    @Test func theStalenessRuleStillHolds() async throws {
        let store = makeStore()
        try await store.save(batch)
        let record = Fixtures.record(batch: batch.id)
        try await store.append(record, photo: Data(), rectified: nil)
        let decided = try await store.decide(record.id, in: batch.id, DecisionInput(.correct, source: .human))
        await #expect(throws: ScanStoreError.staleRecord(record.id)) {
            try await store.update(record)
        }
        try await store.update(decided)
        await #expect(throws: ScanStoreError.invalidDecision(record.id)) {
            try await store.decide(record.id, in: batch.id, DecisionInput(.pending, source: .human))
        }
    }

    @Test func voidingAppendsAVoidedDecisionToEveryScanAndMarksTheBatch() async throws {
        let clock = TickingClock()
        let store = makeStore(now: { clock.now() })
        try await store.save(batch)
        let judged = Fixtures.record(batch: batch.id, verdict: .correct)
        let pending = Fixtures.record(batch: batch.id)
        let alreadyVoided = Fixtures.record(batch: batch.id, verdict: .voided)
        for record in [judged, pending, alreadyVoided] {
            try await store.append(record, photo: Data(), rectified: nil)
        }
        var events: [SyncingScanStore.Event] = []
        let collector = Task {
            for await event in store.events {
                events.append(event)
                if case .voided = event { break }
            }
        }

        let voided = try await store.voidBatch(batch.id)
        #expect(voided == 2)
        let records = try await store.records(in: batch.id)
        #expect(records.allSatisfy { $0.verdict == .voided })
        #expect(records.first { $0.id == judged.id }?.decisions.map(\.seq) == [1, 2])
        #expect(records.first { $0.id == judged.id }?.decisions.last?.source == .human)
        #expect(records.first { $0.id == alreadyVoided.id }?.decisions.count == 1)
        let state = try syncJSON(for: batch.id, store: store)
        #expect(state.isVoided)
        #expect(state[judged.id].record == .queued, "the server must learn the scan was voided")
        #expect(state[pending.id].record == .queued)
        #expect(state[judged.id].photoSmall == .notEligible, "a voided scan's assets are not worth the bytes")
        #expect(state[judged.id].canvas == .notEligible)
        await collector.value
        #expect(events.contains(.voided(batch.id)))

        try await store.voidBatch(batch.id)
        #expect(try await store.records(in: batch.id).allSatisfy { $0.decisions.count <= 2 }, "voiding twice adds nothing")
    }

    @Test func closingRecordsTheTimeOnce() async throws {
        let clock = TickingClock()
        let store = makeStore(now: { clock.now() })
        try await store.save(batch)
        try await store.closeBatch(batch.id)
        let first = try #require(try syncJSON(for: batch.id, store: store).closedAt)
        try await store.closeBatch(batch.id)
        #expect(try syncJSON(for: batch.id, store: store).closedAt == first)
    }

    @Test func deletingABatchRemovesItsSyncFolder() async throws {
        let store = makeStore()
        try await store.save(batch)
        let folder = store.batchSyncDirectory(for: batch.id)
        #expect(FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
        try await store.deleteBatch(batch.id)
        #expect(!FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
        #expect(try await store.batches().isEmpty)
    }

    @Test func syncStateSurvivesARelaunch() async throws {
        let inner = InMemoryScanStore()
        let store = makeStore(inner: inner)
        try await store.save(batch)
        let record = Fixtures.record(batch: batch.id)
        try await store.append(record, photo: Data(), rectified: nil)
        _ = try await store.decide(record.id, in: batch.id, DecisionInput(.corrected(Fixtures.jinx.id), source: .human))
        let ref = ClientRef.plusOne(record.id, seq: 1)
        try await store.updateSyncState(for: batch.id) { state in
            state[record.id][ref] = .applied(ledgerID: 7, cardID: "OGN-002", finish: .foil)
            state[record.id][.undo(record.id, seq: 2)] = .terminal(.unknownCard(catalogVersion: "cat-1"))
            state[record.id][.plusOne(record.id, seq: 3)] = .sent
            state[record.id].record = .uploaded(Fixtures.epoch)
            state[record.id].uploadedSeq = 1
            state[record.id].photoSmall = .failed("too large")
            state[record.id].canvas = .conflict(serverSeq: 2)
            state.batchMeta = .uploaded(Fixtures.epoch)
            state.closedAt = Fixtures.epoch
        }
        let relaunched = makeStore(inner: inner)
        let state = await relaunched.syncState(for: batch.id)
        #expect(state[record.id][ref] == .applied(ledgerID: 7, cardID: "OGN-002", finish: .foil))
        #expect(state[record.id][.undo(record.id, seq: 2)] == .terminal(.unknownCard(catalogVersion: "cat-1")))
        #expect(state[record.id][.plusOne(record.id, seq: 3)] == .sent)
        #expect(state[record.id].allItemsAcknowledged == false, "a sent item has no answer yet")
        #expect(state[record.id].record == .uploaded(Fixtures.epoch))
        #expect(state[record.id].uploadedSeq == 1)
        #expect(state[record.id].photoSmall == .failed("too large"))
        #expect(state[record.id].canvas == .conflict(serverSeq: 2))
        #expect(state.batchMeta == .uploaded(Fixtures.epoch))
        #expect(state.closedAt == Fixtures.epoch)
        #expect(state.rejectedUndos == 1)
    }

    @Test func aMissingOrTruncatedSyncFileIsAFreshState() async throws {
        let store = makeStore()
        try await store.save(batch)
        try Data().write(to: store.syncFileURL(for: batch.id))
        let relaunched = makeStore()
        let state = await relaunched.syncState(for: batch.id)
        #expect(state == BatchSyncState(batchID: batch.id))
        #expect(await relaunched.syncState(for: ScanBatch.ID(rawValue: UUID())).scans.isEmpty)
    }

    /// The scanner model's auto-scan loop runs through the live seam
    /// unchanged: records land in the wrapped store and the sync state follows.
    @Test func theAutoScanLoopRunsThroughTheSyncingStore() async throws {
        let inner = InMemoryScanStore()
        let store = makeStore(inner: inner)
        let feeder = StubFeeder(script: [.fed, .fed])
        let model = ScannerModel(
            camera: StubCamera(),
            feeder: feeder,
            identifier: StubIdentifier(outcome: .success(Fixtures.result(cards: [Fixtures.vi, Fixtures.jinx], codeReading: Fixtures.viCodeReading))),
            store: store,
            vault: Fixtures.vault,
            directory: Fixtures.directory,
            makeBatch: { _ in batch },
            now: { Fixtures.epoch },
            // Never audit samples: every confident scan is accepted (ADR-002, decision 9).
            makeID: Fixtures.unsampledIDs,
            duplicateGuard: .off,
            settleDelay: .zero
        )
        await model.start()
        model.connectFeeder()
        model.startAutoScan()
        await model.autoScanTask?.value
        #expect(model.records.count == 2)
        await model.acceptConfidentScans()
        #expect(model.acceptedCount == 2)
        let stored = await inner.records(in: batch.id)
        #expect(stored.allSatisfy { $0.decisions.map(\.source) == [.autoAccepted] })
        let state = await store.syncState(for: batch.id)
        #expect(state.scans.count == 2)
        #expect(state.scans.values.allSatisfy { $0.record == .queued && $0.photoSmall == .queued })
    }
}
