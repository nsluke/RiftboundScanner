import Foundation
import RiftboundRecognizer
@testable import RiftboundScannerApp

extension CameraDevice {
    static let iPhone = CameraDevice(id: ID(rawValue: "iphone-a"), name: "Luke's iPhone Camera", kind: .continuity)
    static let otherIPhone = CameraDevice(id: ID(rawValue: "iphone-b"), name: "Spare iPhone Camera", kind: .continuity)
    static let webcam = CameraDevice(id: ID(rawValue: "usb-1"), name: "USB Camera", kind: .external)
    static let builtIn = CameraDevice(id: ID(rawValue: "builtin"), name: "MacBook Pro Camera", kind: .builtIn)
}

/// Reports a fixed sequence of connected-camera lists, then finishes, so
/// `CameraSourceModel.run()` returns once it has followed every change.
nonisolated struct ScriptedCameraDiscovery: CameraDiscovering {
    let steps: [[CameraDevice]]

    init(_ steps: [CameraDevice]...) {
        self.steps = steps
    }

    func devices() -> AsyncStream<[CameraDevice]> {
        AsyncStream { continuation in
            for step in steps {
                continuation.yield(step)
            }
            continuation.finish()
        }
    }
}

/// Records which cameras the source opened and how it turned them.
actor SpyCameraSwitch: CameraSwitching {
    private(set) var opened: [CameraDevice.ID] = []
    private(set) var rotations: [CameraRotation] = []
    private let frame: PixelSize
    private let unopenable: Set<CameraDevice.ID>

    init(frame: PixelSize = PixelSize(width: 1920, height: 1080), unopenable: Set<CameraDevice.ID> = []) {
        self.frame = frame
        self.unopenable = unopenable
    }

    func use(_ device: CameraDevice.ID) -> PixelSize? {
        opened.append(device)
        return unopenable.contains(device) ? nil : frame
    }

    func setRotation(_ rotation: CameraRotation) {
        rotations.append(rotation)
    }
}

actor InMemoryCameraPreferenceStore: CameraPreferenceStoring {
    private(set) var preferences: CameraPreferences
    private(set) var saveCount = 0

    init(_ preferences: CameraPreferences = CameraPreferences()) {
        self.preferences = preferences
    }

    func load() -> CameraPreferences {
        preferences
    }

    func save(_ preferences: CameraPreferences) {
        self.preferences = preferences
        saveCount += 1
    }
}

/// A camera that counts starts and stops, for following a camera source.
actor RecordingCamera: CameraOperating {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private let access: Bool

    init(access: Bool = true) {
        self.access = access
    }

    func requestAccess() -> Bool { access }

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func setTorch(_ isOn: Bool) throws {}

    func capturePhoto() -> Data { Fixtures.jpeg() }
}
