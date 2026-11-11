import Foundation
import Testing
@testable import RiftboundScannerApp

/// How the scanner follows the Mac's camera picker: the camera comes up once
/// one is chosen, and losing it stops feeding at once.
@Suite("Scanner following the camera source")
struct ScannerCameraSourceTests {
    private func makeModel(camera: any CameraOperating, feeder: StubFeeder = StubFeeder(), store: any ScanStoring = InMemoryScanStore()) -> ScannerModel {
        ScannerModel(
            camera: camera,
            feeder: feeder,
            identifier: StubIdentifier(outcome: .success(Fixtures.result(cards: [Fixtures.vi, Fixtures.jinx]))),
            store: store,
            vault: Fixtures.vault,
            directory: Fixtures.directory,
            makeBatch: Fixtures.makeBatch,
            now: { Fixtures.epoch },
            makeID: Fixtures.unsampledIDs,
            duplicateGuard: .off,
            settleDelay: .zero
        )
    }

    @Test func waitsWhileSearchingThenStartsTheChosenCamera() async {
        let camera = RecordingCamera()
        let model = makeModel(camera: camera)

        await model.follow(.searching)
        #expect(model.cameraState == .starting)
        #expect(model.batch != nil, "the batch is ready before any camera is")
        #expect(await camera.startCount == 0)

        await model.follow(.using(.iPhone))
        #expect(model.cameraState == .ready)
        #expect(await camera.startCount == 1)
    }

    /// The screen follows the source with `.task(id:)`, which cancels a call
    /// for an outdated source but cannot stop it. A `.searching` call still
    /// reading the batch when the camera comes up must not set "Starting…"
    /// over a camera that is already running.
    @Test func aStaleSearchingCallCannotPutARunningCameraBackToStarting() async {
        let store = GatedRecordsStore()
        await store.save(Fixtures.batch())
        let camera = RecordingCamera()
        let model = makeModel(camera: camera, store: store)

        let stale = Task { await model.follow(.searching) }
        await store.waitUntilRecordsAreRead()
        await model.follow(.using(.iPhone))
        #expect(model.cameraState == .ready)

        stale.cancel()
        await store.open()
        await stale.value
        #expect(model.cameraState == .ready)
        #expect(await camera.startCount == 1)
    }

    @Test func noCameraAtAllIsItsOwnState() async {
        let model = makeModel(camera: RecordingCamera())

        await model.follow(.none)

        #expect(model.cameraState == .noCamera)
        #expect(model.batch != nil, "past batches stay reachable without a camera")
    }

    @Test func anEngineWithNoCameraReportsNoCameraNotAnError() async {
        let model = makeModel(camera: StubCamera(startFailure: .noCamera))

        await model.start()

        #expect(model.cameraState == .noCamera)
    }

    @Test func losingTheIPhoneStopsFeedingAndWaits() async throws {
        let camera = RecordingCamera()
        let feeder = StubFeeder(script: [.fed, .hangs])
        let model = makeModel(camera: camera, feeder: feeder)
        await model.follow(.using(.iPhone))
        model.connectFeeder()
        model.startAutoScan()
        while feeder.feedCount < 2 {
            await Task.yield()
        }

        await model.follow(.lost(.iPhone))
        await model.autoScanTask?.value

        #expect(model.cameraState == .disconnected("Luke's iPhone Camera"))
        #expect(model.autoScan == .ended(.init(fed: 1, identified: 1), reason: .cameraDisconnected("Luke's iPhone Camera")))
        #expect(model.records.count == 1, "the photo taken before the loss is still identified and saved")
        #expect(feeder.stopCount == 1, "the motor is told to stop")
        #expect(await camera.stopCount == 1)
        #expect(model.canStartAutoScan == false)
    }

    @Test func aReturningIPhoneBringsTheScannerBack() async {
        let camera = RecordingCamera()
        let feeder = StubFeeder()
        let model = makeModel(camera: camera, feeder: feeder)
        await model.follow(.using(.iPhone))
        model.connectFeeder()
        await model.follow(.lost(.iPhone))
        #expect(model.canStartAutoScan == false)

        await model.follow(.using(.iPhone))

        #expect(model.cameraState == .ready)
        #expect(model.canStartAutoScan)
        #expect(await camera.startCount == 2)
    }

    @Test func aLossAfterFeedingStoppedLeavesTheRunsOwnReason() async {
        let feeder = StubFeeder(script: [.fed])
        let model = makeModel(camera: RecordingCamera(), feeder: feeder)
        await model.follow(.using(.iPhone))
        model.connectFeeder()
        model.startAutoScan()
        await model.autoScanTask?.value
        #expect(model.autoScan == .ended(.init(fed: 1, identified: 1), reason: .hopperEmpty))

        await model.follow(.lost(.iPhone))
        #expect(model.autoScan == .ended(.init(fed: 1, identified: 1), reason: .hopperEmpty), "a finished run keeps its reason")

        // The script is spent, so the next run finds the hopper empty at once.
        await model.follow(.using(.iPhone))
        model.startAutoScan()
        await model.autoScanTask?.value
        #expect(model.autoScan == .ended(.init(), reason: .hopperEmpty), "an earlier loss does not leak into the next run")
    }

    @Test func aRefusedPermissionOutlastsCamerasComingAndGoing() async {
        let model = makeModel(camera: RecordingCamera(access: false))

        await model.follow(.using(.iPhone))
        #expect(model.cameraState == .denied)

        await model.follow(.lost(.iPhone))
        #expect(model.cameraState == .denied)
        await model.follow(.searching)
        #expect(model.cameraState == .denied)
    }
}

/// A store whose record reads wait until `open()`, to hold a batch load
/// half-done while the camera source moves on.
private actor GatedRecordsStore: ScanStoring {
    private let base = InMemoryScanStore()
    private var isOpen = false
    private var hasBeenRead = false
    private var waitingReads: [CheckedContinuation<Void, Never>] = []
    private var readWatchers: [CheckedContinuation<Void, Never>] = []

    func records(in batch: ScanBatch.ID) async throws -> [ScanRecord] {
        if !isOpen {
            hasBeenRead = true
            readWatchers.forEach { $0.resume() }
            readWatchers = []
            await withCheckedContinuation { waitingReads.append($0) }
        }
        return await base.records(in: batch)
    }

    /// Returns once a read is waiting.
    func waitUntilRecordsAreRead() async {
        guard !hasBeenRead else { return }
        await withCheckedContinuation { readWatchers.append($0) }
    }

    func open() {
        isOpen = true
        waitingReads.forEach { $0.resume() }
        waitingReads = []
    }

    func batches() async throws -> [ScanBatch] { await base.batches() }
    func save(_ batch: ScanBatch) async { await base.save(batch) }
    func append(_ record: ScanRecord, photo: Data, rectified: Data?) async throws { try await base.append(record, photo: photo, rectified: rectified) }
    func update(_ record: ScanRecord) async throws { try await base.update(record) }
    func update(_ records: [ScanRecord]) async throws { try await base.update(records) }
    func decide(_ id: ScanRecord.ID, in batch: ScanBatch.ID, _ input: DecisionInput) async throws -> ScanRecord { try await base.decide(id, in: batch, input) }
    func deleteBatch(_ id: ScanBatch.ID) async { await base.deleteBatch(id) }
    nonisolated func batchDirectory(for id: ScanBatch.ID) -> URL { base.batchDirectory(for: id) }
    nonisolated func photoURL(for record: ScanRecord) -> URL { base.photoURL(for: record) }
    nonisolated func rectifiedURL(for record: ScanRecord) -> URL? { base.rectifiedURL(for: record) }
}

/// The feeder takes one Bluetooth connection at a time, so it changes hands
/// with the camera (ADR-004): the phone lets go when it becomes the Mac's
/// camera, and the Mac picks it up.
@Suite("Feeder hand-off to the Mac")
struct FeederHandOffTests {
    private let phoneApp = CameraDevice(id: CameraDevice.ID(rawValue: "riftcam:Lukes-iPhone"), name: "Lukes-iPhone (Riftbound app)", kind: .iPhoneApp, hasTorch: true)

    private func makeModel(feeder: StubFeeder) -> ScannerModel {
        ScannerModel(
            camera: RecordingCamera(),
            feeder: feeder,
            identifier: StubIdentifier(outcome: .success(Fixtures.result(cards: [Fixtures.vi, Fixtures.jinx]))),
            store: InMemoryScanStore(),
            vault: Fixtures.vault,
            directory: Fixtures.directory,
            makeBatch: Fixtures.makeBatch,
            now: { Fixtures.epoch },
            makeID: Fixtures.unsampledIDs,
            duplicateGuard: .off,
            settleDelay: .zero
        )
    }

    @Test func thePhoneLetsGoOfTheFeederForTheMac() {
        let feeder = StubFeeder(state: .ready(firmwareVersion: "0.1.5"))
        let model = makeModel(feeder: feeder)

        model.handFeederToMac()

        #expect(feeder.disconnectCount == 1)
        #expect(feeder.state == .idle)
    }

    @Test func theMacConnectsTheFeederWhenTheIPhoneAppBecomesItsCamera() async {
        let feeder = StubFeeder()
        let model = makeModel(feeder: feeder)

        await model.follow(.using(phoneApp))

        #expect(model.cameraState == .ready)
        #expect(feeder.connectCount == 1)
        await model.follow(.using(phoneApp))
        #expect(feeder.connectCount == 1, "a feeder already connected is left alone")
    }

    @Test func anotherCameraLeavesTheFeederToTheUser() async {
        let feeder = StubFeeder()
        let model = makeModel(feeder: feeder)

        await model.follow(.using(.iPhone))

        #expect(feeder.connectCount == 0)
    }
}
