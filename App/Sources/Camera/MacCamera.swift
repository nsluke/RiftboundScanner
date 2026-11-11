#if os(macOS)
import Foundation
import RiftboundRecognizer
import os

/// The camera the Mac's scan page photographs through: the Mac's own capture
/// engine (Continuity Camera, USB, built-in) or the iPhone app over the
/// network (ADR-004), whichever the picker chose. The scanner and the camera
/// source talk only to this, so neither knows which it is.
actor MacCamera: CameraOperating, CameraSwitching {
    typealias LocalCamera = CameraOperating & CameraSwitching

    private enum Route {
        case local
        case remote(RemoteCameraSession, device: CameraDevice.ID, info: RemoteCameraInfo)
        /// The iPhone app was chosen but could not be reached; starting the
        /// camera again tries it again.
        case remoteUnavailable(RemoteCameraFailure, device: CameraDevice.ID)
    }

    private let local: any LocalCamera
    private let remote: any RemoteCameraConnecting
    private let hostName: String
    private let makeSession: @Sendable (any RemoteCameraChannel) -> RemoteCameraSession
    private let pause: @Sendable (Duration) async throws -> Void
    private var route = Route.local
    private var forwarding: Task<Void, Never>?
    /// Tries a chosen phone that cannot be reached until it answers or
    /// another camera is chosen; `reconnectRound` tells a finished loop from
    /// the one that replaced it.
    private var reconnecting: Task<Void, Never>?
    private var reconnectRound = 0
    /// The switch in progress. Switches run one after another: two at once
    /// would open two links, and the phone keeps only the newer.
    private var switching: Task<PixelSize?, Never>?
    private let logger = Logger(subsystem: "com.nsluke.RiftboundScanner", category: "remoteCamera")

    /// The iPhone app's live frames as JPEGs, for the viewfinder, and `nil`
    /// when its link drops so the viewfinder stops showing the last one.
    /// Quiet while a camera on this Mac is in use, whose preview is the
    /// capture session's.
    nonisolated let previews: AsyncStream<Data?>
    private let previewSink: AsyncStream<Data?>.Continuation

    init(
        local: any LocalCamera,
        remote: any RemoteCameraConnecting,
        hostName: String,
        makeSession: @escaping @Sendable (any RemoteCameraChannel) -> RemoteCameraSession = { RemoteCameraSession(channel: $0) },
        pause: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.local = local
        self.remote = remote
        self.hostName = hostName
        self.makeSession = makeSession
        self.pause = pause
        (previews, previewSink) = AsyncStream.makeStream(of: Data?.self, bufferingPolicy: .bufferingNewest(1))
    }

    // MARK: - CameraSwitching

    func use(_ device: CameraDevice.ID) async -> PixelSize? {
        let previous = switching
        let next = Task {
            _ = await previous?.value
            return await self.switchCamera(to: device)
        }
        switching = next
        return await next.value
    }

    private func switchCamera(to device: CameraDevice.ID) async -> PixelSize? {
        // The same phone, still linked: nothing to reopen.
        if case .remote(let session, let current, let info) = route, current == device, await session.isOpen {
            return info.photoSize
        }
        // Another camera: a loop still trying the phone before it stops.
        if case .remoteUnavailable(_, let waiting) = route, waiting != device {
            reconnecting?.cancel()
            reconnecting = nil
        }
        await closeRemote()
        guard remote.handles(device) else {
            route = .local
            return await local.use(device)
        }
        // The phone's app cannot share its camera with Continuity Camera, and
        // a Mac camera left running would only hold the device.
        await local.stop()
        var failure = RemoteCameraFailure.closed
        for attempt in 1...Self.connectAttempts {
            do {
                let session = makeSession(try await remote.connect(device))
                let info = try await session.open(name: hostName)
                route = .remote(session, device: device, info: info)
                forward(session, device: device)
                logger.notice("Using \(info.deviceName, privacy: .public)'s Riftbound app: photos \(info.photoSize.width)×\(info.photoSize.height), torch \(info.hasTorch)")
                return info.photoSize
            } catch {
                failure = error as? RemoteCameraFailure ?? .closed
                logger.error("Could not use \(device.rawValue, privacy: .public) (attempt \(attempt)): \(String(describing: error), privacy: .public)")
                // A refusal or a version mismatch will not change on its own.
                guard failure == .timedOut || failure == .closed, attempt < Self.connectAttempts else { break }
                try? await pause(Self.retryPause)
            }
        }
        route = .remoteUnavailable(failure, device: device)
        if failure == .timedOut || failure == .closed {
            keepTrying(device)
        }
        return nil
    }

    /// macOS can take a few seconds to apply an app's Local Network approval
    /// after its first attempt ("Local network prohibited" in the logs), so a
    /// link that will not open is tried again before the picker is told.
    private static let connectAttempts = 3
    private static let retryPause: Duration = .seconds(2)
    /// Between rounds of attempts on a phone whose link dropped.
    private static let reconnectPause: Duration = .seconds(5)

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
        case .remote(let session, _, _):
            guard await session.isOpen else { throw RemoteCameraFailure.closed }
        case .remoteUnavailable(_, let device):
            // "Try again" on the scan page: try the phone again.
            guard await use(device) != nil else {
                if case .remoteUnavailable(let failure, _) = route { throw failure }
                throw RemoteCameraFailure.closed
            }
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
        case .remote(let session, _, _): try await session.setTorch(isOn)
        case .remoteUnavailable(let failure, _): throw failure
        }
    }

    func capturePhoto() async throws -> Data {
        switch route {
        case .local: try await local.capturePhoto()
        case .remote(let session, _, _): try await session.capture()
        case .remoteUnavailable(let failure, _): throw failure
        }
    }

    // MARK: - Remote link

    /// Passes the phone's frames to the viewfinder until the link ends. A link
    /// the Mac did not close dropped: the phone's screen closed, its app was
    /// replaced, or the network went.
    private func forward(_ session: RemoteCameraSession, device: CameraDevice.ID) {
        let sink = previewSink
        forwarding = Task {
            for await frame in session.previews {
                sink.yield(frame)
            }
            guard !Task.isCancelled else { return }
            await self.linkDropped(session, device: device)
        }
    }

    /// Clears the viewfinder and fails photos with `closed` until the phone
    /// is back.
    private func linkDropped(_ session: RemoteCameraSession, device: CameraDevice.ID) {
        guard case .remote(let current, let id, _) = route, current === session, id == device else { return }
        logger.notice("Lost the link to \(device.rawValue, privacy: .public); trying it again")
        route = .remoteUnavailable(.closed, device: device)
        forwarding = nil
        previewSink.yield(nil)
        keepTrying(device)
    }

    /// Tries a chosen phone that cannot be reached every few seconds until it
    /// answers or another camera is chosen, so opening or reopening Camera
    /// for Mac is all it takes: Bonjour may still list a phone whose app
    /// closed, and then no change in the camera list would prompt a retry.
    private func keepTrying(_ device: CameraDevice.ID) {
        guard reconnecting == nil else { return }
        reconnectRound += 1
        let round = reconnectRound
        let pause = pause
        reconnecting = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await pause(Self.reconnectPause)
                } catch {
                    break
                }
                guard let self, await self.isWaiting(for: device) else { break }
                if await self.use(device) != nil { break }
            }
            await self?.stoppedTrying(round)
        }
    }

    private func isWaiting(for device: CameraDevice.ID) -> Bool {
        if case .remoteUnavailable(_, let waiting) = route { return waiting == device }
        return false
    }

    private func stoppedTrying(_ round: Int) {
        if round == reconnectRound {
            reconnecting = nil
        }
    }

    private func closeRemote() async {
        forwarding?.cancel()
        forwarding = nil
        if case .remote(let session, _, _) = route {
            await session.close()
        }
    }
}
#endif
