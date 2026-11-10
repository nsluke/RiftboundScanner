import Foundation
import Testing
@testable import RiftboundScannerApp

/// How the scanner follows the Mac's camera picker: the camera comes up once
/// one is chosen, and losing it stops feeding at once.
@Suite("Scanner following the camera source")
struct ScannerCameraSourceTests {
    private func makeModel(camera: any CameraOperating, feeder: StubFeeder = StubFeeder()) -> ScannerModel {
        ScannerModel(
            camera: camera,
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
