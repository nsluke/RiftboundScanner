import Testing
@testable import RiftboundScannerApp

@Suite("Camera selection")
struct CameraSelectionTests {
    @Test func prefersTheIPhoneThenExternalThenBuiltIn() {
        #expect(CameraSelection.preferred(among: [.builtIn, .webcam, .iPhone], saved: nil) == .iPhone)
        #expect(CameraSelection.preferred(among: [.builtIn, .webcam], saved: nil) == .webcam)
        #expect(CameraSelection.preferred(among: [.builtIn], saved: nil) == .builtIn)
        #expect(CameraSelection.preferred(among: [], saved: nil) == nil)
    }

    @Test func keepsDiscoveryOrderBetweenCamerasOfOneKind() {
        #expect(CameraSelection.preferred(among: [.otherIPhone, .iPhone], saved: nil) == .otherIPhone)
    }

    @Test func theSavedCameraWinsWhileItIsConnected() {
        #expect(CameraSelection.preferred(among: [.iPhone, .builtIn], saved: CameraDevice.builtIn.id) == .builtIn)
        #expect(CameraSelection.preferred(among: [.iPhone, .webcam], saved: CameraDevice.builtIn.id) == .iPhone, "a saved camera that is gone falls back to preference order")
    }

    @Test func aSavedIPhoneAppIsWaitedForWithoutTakingAnIPhoneThroughContinuity() {
        let app = CameraDevice.phoneApp
        #expect(CameraSelection.preferred(among: [.iPhone, .builtIn], saved: app.id) == .builtIn, "Continuity Camera would push the app off the phone's screen")
        #expect(CameraSelection.source(after: .searching, devices: [.iPhone, .builtIn], saved: app.id) == .using(.builtIn))
        #expect(CameraSelection.source(after: .using(.builtIn), devices: [.iPhone, .builtIn, app], saved: app.id) == .using(app), "the app takes over once it advertises")
        #expect(CameraSelection.preferred(among: [.iPhone, .builtIn], saved: CameraDevice.webcam.id) == .iPhone, "only a saved iPhone app holds Continuity Camera back")
    }

    @Test func startsWithThePreferredCameraOrNone() {
        #expect(CameraSelection.source(after: .searching, devices: [.builtIn, .iPhone], saved: nil) == .using(.iPhone))
        #expect(CameraSelection.source(after: .searching, devices: [], saved: nil) == CameraSource.none)
        #expect(CameraSelection.source(after: .none, devices: [.webcam], saved: nil) == .using(.webcam))
    }

    @Test func aDisconnectedCameraIsLostNotReplaced() {
        let source = CameraSelection.source(after: .using(.iPhone), devices: [.builtIn, .webcam], saved: nil)
        #expect(source == .lost(.iPhone), "the next photo must not come from a camera aimed elsewhere")
    }

    @Test func aLostCameraWaitsForItselfAndResumesWhenBack() {
        #expect(CameraSelection.source(after: .lost(.iPhone), devices: [.builtIn, .otherIPhone], saved: nil) == .lost(.iPhone))
        #expect(CameraSelection.source(after: .lost(.iPhone), devices: [], saved: nil) == .lost(.iPhone))
        #expect(CameraSelection.source(after: .lost(.iPhone), devices: [.builtIn, .iPhone], saved: nil) == .using(.iPhone))
    }

    @Test func anIPhoneJoiningLaterReplacesTheBuiltInCamera() {
        // Continuity Camera devices appear a few seconds after launch.
        #expect(CameraSelection.source(after: .using(.builtIn), devices: [.builtIn, .iPhone], saved: nil) == .using(.iPhone))
    }

    @Test func theSavedCameraReplacesAFallbackWhenItAppears() {
        let source = CameraSelection.source(after: .using(.iPhone), devices: [.iPhone, .otherIPhone], saved: CameraDevice.otherIPhone.id)
        #expect(source == .using(.otherIPhone))
    }

    @Test func aCameraTheUserSavedIsNeverReplaced() {
        let source = CameraSelection.source(after: .using(.builtIn), devices: [.builtIn, .iPhone], saved: CameraDevice.builtIn.id)
        #expect(source == .using(.builtIn))
    }

    @Test func aCameraOfTheSameKindDoesNotTakeOver() {
        #expect(CameraSelection.source(after: .using(.iPhone), devices: [.otherIPhone, .iPhone], saved: nil) == .using(.iPhone))
    }

    @Test func picksUpANewNameForTheSameCamera() {
        let renamed = CameraDevice(id: CameraDevice.iPhone.id, name: "Luke's iPhone 17 Camera", kind: .continuity)
        #expect(CameraSelection.source(after: .using(.iPhone), devices: [renamed], saved: nil) == .using(renamed))
    }
}
