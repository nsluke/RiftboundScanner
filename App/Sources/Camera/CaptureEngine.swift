import AVFoundation
import Foundation

/// The camera as the scanner model sees it. The live implementation drives the
/// back camera; tests inject a stub that returns a canned JPEG.
nonisolated protocol CameraOperating: Sendable {
    func requestAccess() async -> Bool
    func start() async throws
    func stop() async
    func setTorch(_ isOn: Bool) async throws
    /// An encoded photo (JPEG with EXIF orientation).
    func capturePhoto() async throws -> Data
}

nonisolated enum CameraError: Error {
    case noCamera
    case cannotAddInput
    case cannotAddOutput
    case torchUnavailable
    case captureFailed(String)
    case noImageData

    var message: String {
        switch self {
        case .noCamera: String(localized: "No back camera is available on this device.")
        case .cannotAddInput, .cannotAddOutput: String(localized: "The camera could not be configured.")
        case .torchUnavailable: String(localized: "This camera has no torch.")
        case .captureFailed(let detail): String(localized: "The photo could not be taken. \(detail)")
        case .noImageData: String(localized: "The camera returned no image.")
        }
    }
}

/// Owns the capture session and the photo output.
///
/// AVFoundation documents `AVCaptureSession` as safe to configure, start and
/// stop from a single serial context and requires `startRunning()` off the main
/// thread, but the SDK does not mark the class `Sendable`. This engine asserts
/// that discipline instead: every call into the session, device or output goes
/// through `queue`, and the only other reader is the preview layer, which
/// AVFoundation synchronises itself. That is the justification for
/// `@unchecked Sendable`; nothing else in the app touches the session.
nonisolated final class CaptureEngine: CameraOperating, @unchecked Sendable {
    /// For the preview layer only; drive the camera through the methods below.
    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "com.nsluke.RiftboundScanner.capture")
    private let photoOutput = AVCapturePhotoOutput()
    // Touched only on `queue`.
    private var device: AVCaptureDevice?
    private var isConfigured = false
    private var inFlight: [ObjectIdentifier: PhotoCaptureDelegate] = [:]

    init() {}

    func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted: return false
        @unknown default: return false
        }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    try self.configureIfNeeded()
                    if !self.session.isRunning {
                        self.session.startRunning()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                continuation.resume()
            }
        }
    }

    func setTorch(_ isOn: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    guard let device = self.device, device.hasTorch, device.isTorchAvailable else { throw CameraError.torchUnavailable }
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    device.torchMode = isOn ? .on : .off
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func capturePhoto() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            queue.async {
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                settings.flashMode = .off
                settings.photoQualityPrioritization = .balanced
                if let dimensions = self.photoOutput.maxPhotoDimensions.width > 0 ? self.photoOutput.maxPhotoDimensions : nil {
                    settings.maxPhotoDimensions = dimensions
                }
                // The output does not retain its delegate, so `inFlight` keeps it
                // alive until AVFoundation reports back; that callback always comes
                // (with a photo or an error), which bounds the engine → delegate →
                // closure → engine cycle to the length of one capture.
                let delegate = PhotoCaptureDelegate(continuation: continuation) { key in
                    self.queue.async { self.inFlight[key] = nil }
                }
                self.inFlight[ObjectIdentifier(delegate)] = delegate
                self.photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    // MARK: - Queue-only

    private func configureIfNeeded() throws {
        guard !isConfigured else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo

        // The dual-wide virtual device switches to the ultra-wide lens for close
        // subjects, which is what a card a hand's width from the lens needs.
        guard let device = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        else { throw CameraError.noCamera }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
        session.addInput(input)
        guard session.canAddOutput(photoOutput) else { throw CameraError.cannotAddOutput }
        session.addOutput(photoOutput)

        // 12 MP is plenty: the recogniser downsamples to 2048 px anyway, and
        // 48 MP captures are slow.
        let supported = device.activeFormat.supportedMaxPhotoDimensions
        if let chosen = supported.filter({ $0.width <= 4100 }).max(by: { $0.width < $1.width }) ?? supported.first {
            photoOutput.maxPhotoDimensions = chosen
        }
        photoOutput.maxPhotoQualityPrioritization = .balanced
        if let connection = photoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }

        try device.lockForConfiguration()
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isAutoFocusRangeRestrictionSupported {
            device.autoFocusRangeRestriction = .near
        }
        device.unlockForConfiguration()

        self.device = device
        isConfigured = true
    }
}

/// Resumes one continuation exactly once, when AVFoundation delivers the photo.
nonisolated private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let continuation: CheckedContinuation<Data, any Error>
    private let finished: @Sendable (ObjectIdentifier) -> Void

    init(continuation: CheckedContinuation<Data, any Error>, finished: @escaping @Sendable (ObjectIdentifier) -> Void) {
        self.continuation = continuation
        self.finished = finished
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        defer { finished(ObjectIdentifier(self)) }
        if let error {
            continuation.resume(throwing: CameraError.captureFailed(error.localizedDescription))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            continuation.resume(throwing: CameraError.noImageData)
            return
        }
        continuation.resume(returning: data)
    }
}
