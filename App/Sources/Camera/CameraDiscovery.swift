#if os(macOS)
import AVFoundation

/// The Mac's connected cameras: iPhones through Continuity Camera, external
/// cameras and the built-in one. Desk View is left out: it is a dewarped crop
/// of the iPhone's ultra-wide aimed at the desk, not a camera that can sit on
/// the feeder's stand.
nonisolated struct LiveCameraDiscovery: CameraDiscovering {
    func devices() -> AsyncStream<[CameraDevice]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let watcher = DeviceWatcher { continuation.yield($0) }
            continuation.onTermination = { _ in watcher.invalidate() }
        }
    }
}

/// Keeps one discovery session and its key-value observation alive for as
/// long as a stream is listening.
///
/// `AVCaptureDevice.DiscoverySession.devices` is documented as key-value
/// observable and changes as devices connect and disconnect; the observation
/// callback may arrive on any thread and only reads that array. The token is
/// written once in `init` and invalidated once from the stream's termination
/// handler, and `NSKeyValueObservation.invalidate()` is safe to call from any
/// thread. That is the justification for `@unchecked Sendable`.
nonisolated private final class DeviceWatcher: @unchecked Sendable {
    private let session = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.continuityCamera, .external, .builtInWideAngleCamera],
        mediaType: .video,
        position: .unspecified
    )
    private var observation: NSKeyValueObservation?

    init(onChange: @escaping @Sendable ([CameraDevice]) -> Void) {
        observation = session.observe(\.devices, options: [.initial, .new]) { session, _ in
            onChange(session.devices.map(CameraDevice.init))
        }
    }

    func invalidate() {
        observation?.invalidate()
    }
}

nonisolated extension CameraDevice {
    init(_ device: AVCaptureDevice) {
        let kind: Kind = if device.isContinuityCamera || device.deviceType == .continuityCamera {
            .continuity
        } else if device.deviceType == .external {
            .external
        } else {
            .builtIn
        }
        self.init(id: ID(rawValue: device.uniqueID), name: device.localizedName, kind: kind, hasTorch: device.hasTorch)
    }
}
#endif
