import AVFoundation
import Foundation
import RiftboundRecognizer
import Synchronization
import os

/// The camera as the scanner model sees it. The live implementation drives the
/// iPhone's back camera, or on the Mac the camera `CameraSourceModel` picked;
/// tests inject a stub that returns a canned JPEG.
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
    /// The session has no live picture to photograph: stopped, or the
    /// camera behind it went away between frames.
    case notStreaming
    case captureFailed(String)
    case noImageData

    var message: String {
        switch self {
        case .noCamera:
            #if os(macOS)
            String(localized: "No camera is connected to this Mac.")
            #else
            String(localized: "No back camera is available on this device.")
            #endif
        case .cannotAddInput, .cannotAddOutput: String(localized: "The camera could not be configured.")
        case .torchUnavailable: String(localized: "This camera has no torch.")
        case .notStreaming: String(localized: "The camera isn't sending a picture. Check that it is still connected, then try again.")
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
    private let logger = Logger(subsystem: "com.nsluke.RiftboundScanner", category: "camera")
    private let photoOutput = AVCapturePhotoOutput()
    // Touched only on `queue`.
    private var input: AVCaptureDeviceInput?
    private var inFlight: [ObjectIdentifier: PhotoCaptureDelegate] = [:]
    #if os(macOS)
    private var chosenDeviceID: CameraDevice.ID?
    #endif
    /// How photos are turned to match the preview and brightened for the
    /// camera in use; read when a photo arrives.
    private let adjustment = Mutex(PhotoAdjustment())

    private struct PhotoAdjustment {
        var rotation = CameraRotation.none
        var exposureBoost = 0.0
    }

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
                        if let device = self.input?.device {
                            let frame = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                            self.logger.info("Started \(device.localizedName, privacy: .public) at \(frame.width)×\(frame.height)")
                        }
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
                    guard let device = self.input?.device, device.hasTorch, device.isTorchAvailable else { throw CameraError.torchUnavailable }
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
        let photo = try await takePhoto()
        let adjustment = self.adjustment.withLock { $0 }
        do {
            return try PhotoDecoder.adjusted(photo, turnedBy: adjustment.rotation, brightenedBy: adjustment.exposureBoost)
        } catch {
            throw CameraError.captureFailed(String(localized: "The photo could not be turned to match the preview."))
        }
    }

    private func takePhoto() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            queue.async {
                // AVFoundation raises an Objective-C exception, which no Swift
                // code can catch, when asked for a photo without a live video
                // connection; a camera that just went away leaves exactly that.
                guard self.session.isRunning, let connection = self.photoOutput.connection(with: .video), connection.isEnabled, connection.isActive else {
                    let connection = self.photoOutput.connection(with: .video)
                    self.logger.error("No photo: running \(self.session.isRunning), connection \(connection != nil), enabled \(connection?.isEnabled ?? false), active \(connection?.isActive ?? false)")
                    continuation.resume(throwing: CameraError.notStreaming)
                    return
                }
                // JPEG on every camera the iPhone has; a Mac camera that cannot
                // encode it gets its default codec, which ImageIO also reads.
                let settings = self.photoOutput.availablePhotoCodecTypes.contains(.jpeg)
                    ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                    : AVCapturePhotoSettings()
                if self.photoOutput.supportedFlashModes.contains(.off) {
                    settings.flashMode = .off
                }
                settings.photoQualityPrioritization = .balanced
                // Sized from the format active now, not the one at setup:
                // AVFoundation raises if the two disagree, and a camera's
                // format can change under a running session.
                if let device = self.input?.device, let dimensions = Self.photoDimensions(for: device.activeFormat) {
                    if dimensions.width > self.photoOutput.maxPhotoDimensions.width || dimensions.height > self.photoOutput.maxPhotoDimensions.height {
                        self.photoOutput.maxPhotoDimensions = dimensions
                    }
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

    /// Opens the camera on first use. The iPhone always uses its back
    /// camera; the Mac opens the camera last chosen through `use(_:)`.
    private func configureIfNeeded() throws {
        guard input == nil else { return }
        try install(try deviceToOpen())
    }

    #if os(iOS)
    private func deviceToOpen() throws -> AVCaptureDevice {
        // The dual-wide virtual device switches to the ultra-wide lens for close
        // subjects, which is what a card a hand's width from the lens needs.
        guard let device = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        else { throw CameraError.noCamera }
        return device
    }
    #else
    private func deviceToOpen() throws -> AVCaptureDevice {
        guard let chosenDeviceID, let device = AVCaptureDevice(uniqueID: chosenDeviceID.rawValue), device.isConnected else {
            throw CameraError.noCamera
        }
        return device
    }
    #endif

    /// Makes `device` the session's only input, replacing the one before,
    /// then sizes photos from the format the session settled on.
    private func install(_ device: AVCaptureDevice) throws {
        try replaceInput(with: device)
        #if os(macOS)
        // Center Stage reframes as it follows faces; the guide crop needs a fixed frame.
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = false
        #endif

        if let chosen = Self.photoDimensions(for: device.activeFormat) {
            photoOutput.maxPhotoDimensions = chosen
        }
        photoOutput.maxPhotoQualityPrioritization = .balanced
        #if os(iOS)
        if let connection = photoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        #endif

        try device.lockForConfiguration()
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        #if os(iOS)
        if device.isAutoFocusRangeRestrictionSupported {
            device.autoFocusRangeRestriction = .near
        }
        #endif
        device.unlockForConfiguration()
    }

    /// The photo size to ask `format` for. 12 MP is plenty: the recogniser
    /// downsamples to 2048 px anyway, and 48 MP captures are slow.
    private static func photoDimensions(for format: AVCaptureDevice.Format) -> CMVideoDimensions? {
        let supported = format.supportedMaxPhotoDimensions
        return supported.filter { $0.width <= 4100 }.max { $0.width < $1.width } ?? supported.first
    }

    /// One configuration transaction: the preset picks the active format
    /// when it commits, so photo sizes are read only afterwards.
    private func replaceInput(with device: AVCaptureDevice) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if let input {
            session.removeInput(input)
            self.input = nil
        }
        let newInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(newInput) else { throw CameraError.cannotAddInput }
        session.addInput(newInput)
        if !session.outputs.contains(photoOutput) {
            guard session.canAddOutput(photoOutput) else { throw CameraError.cannotAddOutput }
            session.addOutput(photoOutput)
        }
        #if os(iOS)
        session.sessionPreset = .photo
        #else
        // An iPhone over Continuity Camera rejects `.photo`. It does offer a
        // 1920 × 1440 format, but a Mac session re-applies its preset whenever
        // its graph is rebuilt (attaching a preview layer is enough), so a
        // format set by hand does not stay. At `.high` (1920 × 1080) the card
        // keeps every pixel: both formats share the 1920 px side, and only the
        // margin beside the card is narrower.
        session.sessionPreset = .high
        #endif
        input = newInput
    }
}

#if os(macOS)
nonisolated extension CaptureEngine: CameraSwitching {
    func use(_ device: CameraDevice.ID) async -> PixelSize? {
        await withCheckedContinuation { (continuation: CheckedContinuation<PixelSize?, Never>) in
            queue.async {
                self.chosenDeviceID = device
                // A device that reconnected is a new object, so the input is
                // rebuilt every time; that is what makes a returning iPhone work.
                do {
                    let opened = try self.deviceToOpen()
                    try self.install(opened)
                    let boost = CameraDevice(opened).kind.photoExposureBoost
                    self.adjustment.withLock { $0.exposureBoost = boost }
                    let dimensions = CMVideoFormatDescriptionGetDimensions(opened.activeFormat.formatDescription)
                    continuation.resume(returning: PixelSize(width: Int(dimensions.width), height: Int(dimensions.height)))
                } catch {
                    // Left closed: `start()` tries again and reports why.
                    if let input = self.input {
                        self.session.removeInput(input)
                        self.input = nil
                    }
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func setRotation(_ rotation: CameraRotation) async {
        adjustment.withLock { $0.rotation = rotation }
    }
}
#endif

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
