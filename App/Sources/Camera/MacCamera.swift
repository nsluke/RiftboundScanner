#if os(macOS)
import Foundation
import RiftboundRecognizer

/// The camera the Mac's scan page photographs through: the Mac's own capture
/// engine (Continuity Camera, USB, built-in) or the iPhone app over the
/// network (ADR-004), whichever the picker chose. The scanner and the camera
/// source talk only to this, so neither knows which it is.
actor MacCamera: CameraOperating, CameraSwitching {
    typealias LocalCamera = CameraOperating & CameraSwitching

    private enum Route {
        case local
        case remote(RemoteCameraSession)
        /// The iPhone app was chosen but could not be reached.
        case remoteUnavailable(RemoteCameraFailure)
    }

    private let local: any LocalCamera
    private let remote: any RemoteCameraConnecting
    private let hostName: String
    private let makeSession: @Sendable (any RemoteCameraChannel) -> RemoteCameraSession
    private var route = Route.local
    private var forwarding: Task<Void, Never>?

    /// The iPhone app's live frames as JPEGs, for the viewfinder; empty while
    /// a camera on this Mac is in use, whose preview is the capture session's.
    nonisolated let previews: AsyncStream<Data>
    private let previewSink: AsyncStream<Data>.Continuation

    init(
        local: any LocalCamera,
        remote: any RemoteCameraConnecting,
        hostName: String,
        makeSession: @escaping @Sendable (any RemoteCameraChannel) -> RemoteCameraSession = { RemoteCameraSession(channel: $0) }
    ) {
        self.local = local
        self.remote = remote
        self.hostName = hostName
        self.makeSession = makeSession
        (previews, previewSink) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(1))
    }

    // MARK: - CameraSwitching

    func use(_ device: CameraDevice.ID) async -> PixelSize? {
        await closeRemote()
        guard remote.handles(device) else {
            route = .local
            return await local.use(device)
        }
        // The phone's app cannot share its camera with Continuity Camera, and
        // a Mac camera left running would only hold the device.
        await local.stop()
        do {
            let session = makeSession(try await remote.connect(device))
            let info = try await session.open(name: hostName)
            route = .remote(session)
            forward(session.previews)
            return info.photoSize
        } catch {
            route = .remoteUnavailable(error as? RemoteCameraFailure ?? .closed)
            return nil
        }
    }

    /// The iPhone app turns its photos upright itself; only the Mac's own
    /// cameras need turning.
    func setRotation(_ rotation: CameraRotation) async {
        await local.setRotation(rotation)
    }

    // MARK: - CameraOperating

    /// The iPhone app needs no camera access on this Mac.
    func requestAccess() async -> Bool {
        switch route {
        case .local: await local.requestAccess()
        case .remote, .remoteUnavailable: true
        }
    }

    func start() async throws {
        switch route {
        case .local:
            try await local.start()
        case .remote(let session):
            guard await session.isOpen else { throw RemoteCameraFailure.closed }
        case .remoteUnavailable(let failure):
            throw failure
        }
    }

    /// Leaving the Scan tab stops a Mac camera; the iPhone app's link stays
    /// up, so coming back shows its picture at once.
    func stop() async {
        if case .local = route {
            await local.stop()
        }
    }

    func setTorch(_ isOn: Bool) async throws {
        switch route {
        case .local: try await local.setTorch(isOn)
        case .remote(let session): try await session.setTorch(isOn)
        case .remoteUnavailable(let failure): throw failure
        }
    }

    func capturePhoto() async throws -> Data {
        switch route {
        case .local: try await local.capturePhoto()
        case .remote(let session): try await session.capture()
        case .remoteUnavailable(let failure): throw failure
        }
    }

    // MARK: - Remote link

    private func forward(_ frames: AsyncStream<Data>) {
        let sink = previewSink
        forwarding = Task {
            for await frame in frames {
                sink.yield(frame)
            }
        }
    }

    private func closeRemote() async {
        forwarding?.cancel()
        forwarding = nil
        if case .remote(let session) = route {
            await session.close()
        }
    }
}
#endif
