import Foundation
import RiftboundRecognizer
import Testing
@testable import RiftboundScannerApp

@Suite("Camera source")
struct CameraSourceModelTests {
    @Test func opensTheIPhoneInTheEngineAndTurnsItUpright() async {
        let engine = SpyCameraSwitch()
        let model = CameraSourceModel(discovery: ScriptedCameraDiscovery([.builtIn, .iPhone]), camera: engine, preferences: InMemoryCameraPreferenceStore())

        await model.run()

        #expect(model.source == .using(.iPhone))
        #expect(model.devices == [.builtIn, .iPhone])
        #expect(await engine.opened == [CameraDevice.iPhone.id])
        #expect(model.rotation == .clockwise90, "Continuity Camera delivers landscape frames; the iPhone app turns its own camera the same way")
        #expect(await engine.rotations == [.clockwise90])
        #expect(model.frameSize == PixelSize(width: 1920, height: 1080))
        #expect(abs((model.displayAspectRatio ?? 0) - 1080.0 / 1920.0) < 1e-9, "turned upright, the frame is portrait")
        #expect(model.guide == .continuityStand)
    }

    @Test func aBuiltInCameraStartsUnturnedWithTheIPhoneAppsGuide() async {
        let model = CameraSourceModel(discovery: ScriptedCameraDiscovery([.builtIn]), camera: SpyCameraSwitch(), preferences: InMemoryCameraPreferenceStore())

        await model.run()

        #expect(model.source == .using(.builtIn))
        #expect(model.rotation == CameraRotation.none)
        #expect(model.guide == .iPhoneApp)
    }

    @Test func switchesToTheIPhoneWhenItJoinsAfterLaunch() async {
        let engine = SpyCameraSwitch()
        let model = CameraSourceModel(discovery: ScriptedCameraDiscovery([.builtIn], [.builtIn, .iPhone]), camera: engine, preferences: InMemoryCameraPreferenceStore())

        await model.run()

        #expect(model.source == .using(.iPhone))
        #expect(await engine.opened == [CameraDevice.builtIn.id, CameraDevice.iPhone.id])
    }

    @Test func waitsForALostIPhoneAndReopensItWhenItReturns() async {
        let engine = SpyCameraSwitch()
        let model = CameraSourceModel(discovery: ScriptedCameraDiscovery([.iPhone, .builtIn], [.builtIn], [.builtIn, .iPhone]), camera: engine, preferences: InMemoryCameraPreferenceStore())

        await model.run()

        #expect(model.source == .using(.iPhone))
        #expect(await engine.opened == [CameraDevice.iPhone.id, CameraDevice.iPhone.id], "a returning device is a new object and is opened again")
    }

    @Test func staysLostWhileOnlyOtherCamerasAreConnected() async {
        let engine = SpyCameraSwitch()
        let model = CameraSourceModel(discovery: ScriptedCameraDiscovery([.iPhone, .builtIn], [.builtIn]), camera: engine, preferences: InMemoryCameraPreferenceStore())

        await model.run()

        #expect(model.source == .lost(.iPhone))
        #expect(model.selectedID == CameraDevice.iPhone.id, "the picker still shows the camera being waited for")
        #expect(await engine.opened == [CameraDevice.iPhone.id])
    }

    @Test func reportsNoCameraWhenNoneIsConnected() async {
        let engine = SpyCameraSwitch()
        let model = CameraSourceModel(discovery: ScriptedCameraDiscovery([]), camera: engine, preferences: InMemoryCameraPreferenceStore())

        await model.run()

        #expect(model.source == CameraSource.none)
        #expect(await engine.opened.isEmpty)
    }

    @Test func choosingACameraUsesItAndRemembersIt() async {
        let engine = SpyCameraSwitch()
        let store = InMemoryCameraPreferenceStore()
        let model = CameraSourceModel(discovery: ScriptedCameraDiscovery([.iPhone, .webcam]), camera: engine, preferences: store)
        await model.run()

        await model.choose(CameraDevice.webcam.id)

        #expect(model.source == .using(.webcam))
        #expect(await engine.opened == [CameraDevice.iPhone.id, CameraDevice.webcam.id])
        #expect(await store.preferences.cameraID == CameraDevice.webcam.id)
    }

    @Test func usingTheIPhoneAppRemembersItForTheNextLaunch() async {
        let store = InMemoryCameraPreferenceStore()
        let model = CameraSourceModel(discovery: ScriptedCameraDiscovery([.iPhone, .builtIn], [.builtIn], [.builtIn, .phoneApp]), camera: SpyCameraSwitch(), preferences: store)

        await model.run()

        #expect(model.source == .using(.phoneApp))
        #expect(await store.preferences.cameraID == CameraDevice.phoneApp.id)

        let engine = SpyCameraSwitch()
        let relaunched = CameraSourceModel(discovery: ScriptedCameraDiscovery([.iPhone, .builtIn]), camera: engine, preferences: store)
        await relaunched.run()

        #expect(relaunched.source == .using(.builtIn), "waits for the app on the built-in camera, leaving the phone alone")
        #expect(await engine.opened == [CameraDevice.builtIn.id])
    }

    @Test func choosingACameraThatIsNotConnectedDoesNothing() async {
        let engine = SpyCameraSwitch()
        let model = CameraSourceModel(discovery: ScriptedCameraDiscovery([.iPhone]), camera: engine, preferences: InMemoryCameraPreferenceStore())
        await model.run()

        await model.choose(CameraDevice.webcam.id)

        #expect(model.source == .using(.iPhone))
        #expect(await engine.opened == [CameraDevice.iPhone.id])
    }

    @Test func startsWithTheSavedCameraAndItsSavedTurnAndGuide() async {
        let engine = SpyCameraSwitch()
        let saved = CameraPreferences(
            cameraID: CameraDevice.webcam.id,
            rotations: [CameraDevice.webcam.id.rawValue: .clockwise180],
            guideWidths: [CameraDevice.webcam.id.rawValue: 0.6]
        )
        let model = CameraSourceModel(discovery: ScriptedCameraDiscovery([.iPhone, .webcam]), camera: engine, preferences: InMemoryCameraPreferenceStore(saved))

        await model.run()

        #expect(model.source == .using(.webcam))
        #expect(model.rotation == .clockwise180)
        #expect(await engine.rotations == [.clockwise180])
        #expect(model.guide == FrameGuide.iPhoneApp.resized(to: 0.6))
        #expect(abs((model.displayAspectRatio ?? 0) - 1920.0 / 1080.0) < 1e-9, "a half-turn keeps the frame landscape")
    }

    @Test func rotatingTurnsTheEngineAndIsRememberedPerCamera() async {
        let engine = SpyCameraSwitch()
        let store = InMemoryCameraPreferenceStore()
        let model = CameraSourceModel(discovery: ScriptedCameraDiscovery([.iPhone]), camera: engine, preferences: store)
        await model.run()

        await model.rotateClockwise()

        #expect(model.rotation == .clockwise180)
        #expect(await engine.rotations == [.clockwise90, .clockwise180])
        #expect(await store.preferences.rotations == [CameraDevice.iPhone.id.rawValue: .clockwise180])
    }

    @Test func resizingTheGuideMovesTheCropAndIsRememberedOnceSettled() async {
        let store = InMemoryCameraPreferenceStore()
        let model = CameraSourceModel(discovery: ScriptedCameraDiscovery([.iPhone]), camera: SpyCameraSwitch(), preferences: store)
        await model.run()

        model.resizeGuide(to: 0.62)
        model.resizeGuide(to: 0.64)
        #expect(model.guide == FrameGuide.continuityStand.resized(to: 0.64))
        #expect(await store.saveCount == 0, "dragging does not write on every step")

        await model.rememberGuide()
        #expect(await store.preferences.guideWidths == [CameraDevice.iPhone.id.rawValue: 0.64])
    }

    @Test func aCameraThatWillNotOpenHasNoFrameSize() async {
        let model = CameraSourceModel(discovery: ScriptedCameraDiscovery([.iPhone]), camera: SpyCameraSwitch(unopenable: [CameraDevice.iPhone.id]), preferences: InMemoryCameraPreferenceStore())

        await model.run()

        #expect(model.source == .using(.iPhone), "the scanner's start reports why it cannot open")
        #expect(model.frameSize == nil)
        #expect(model.displayAspectRatio == nil)
    }

    @Test func modelDeallocatesAfterRunning() async {
        weak var weakModel: CameraSourceModel?
        do {
            let model = CameraSourceModel(discovery: ScriptedCameraDiscovery([.iPhone], []), camera: SpyCameraSwitch(), preferences: InMemoryCameraPreferenceStore())
            weakModel = model
            await model.run()
        }
        #expect(weakModel == nil)
    }
}

@Suite("Camera preferences")
struct CameraPreferencesTests {
    @Test func preferencesSavedBeforeGuideSizesStillLoad() throws {
        // What the first Mac build wrote on Luke's Mac.
        let json = #"{"cameraID":"D836D3EC-8D56-4E40-8D14-DA0F00000001","rotations":{}}"#
        let preferences = try JSONDecoder().decode(CameraPreferences.self, from: Data(json.utf8))
        #expect(preferences.cameraID == CameraDevice.ID(rawValue: "D836D3EC-8D56-4E40-8D14-DA0F00000001"))
        #expect(preferences.guideWidths.isEmpty)
    }

    @Test func roundTripsThroughUserDefaults() async throws {
        let suite = "CameraPreferencesTests-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        // UserDefaults is not Sendable: the store gets its own instance.
        let store = DefaultsCameraPreferenceStore(defaults: UserDefaults(suiteName: suite)!)
        let preferences = CameraPreferences(cameraID: CameraDevice.iPhone.id, rotations: ["iphone-a": .clockwise270], guideWidths: ["iphone-a": 0.5])

        await store.save(preferences)

        #expect(await store.load() == preferences)
    }

    @Test func eachKindOfCameraHasItsOwnStartingTurnAndGuide() {
        let empty = CameraPreferences()
        #expect(empty.rotation(for: .iPhone) == .clockwise90)
        #expect(empty.rotation(for: .webcam) == CameraRotation.none)
        #expect(empty.guide(for: .iPhone) == .continuityStand)
        #expect(empty.guide(for: .builtIn) == .iPhoneApp)
    }
}
