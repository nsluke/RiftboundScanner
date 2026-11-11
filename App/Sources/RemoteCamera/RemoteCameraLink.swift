import Foundation

/// One open link between the apps, from either end. The live one is a TCP
/// connection (`NetworkRemoteCameraChannel`); tests use an in-memory pair.
nonisolated protocol RemoteCameraChannel: Sendable {
    func send(_ frame: RemoteCameraFrame) async throws
    /// The frames the other end sends, until it closes or the link drops.
    var incoming: AsyncThrowingStream<RemoteCameraFrame, any Error> { get }
    func close() async
}

/// Why the iPhone app could not be used as a camera.
nonisolated enum RemoteCameraFailure: Error, Hashable {
    /// The other app speaks another wire version: one of the two needs updating.
    case versionMismatch(theirs: Int)
    /// The link closed or dropped.
    case closed
    /// The iPhone did not answer in time.
    case timedOut
    /// The iPhone answered with an error, e.g. its camera failed.
    case refused(String)

    var message: String {
        switch self {
        case .versionMismatch(let theirs):
            String(localized: "The iPhone app speaks camera version \(theirs) and this Mac speaks \(RemoteCameraWire.version). Update both apps from the same build.")
        case .closed: String(localized: "The iPhone app stopped being a camera. Open Camera for Mac on the iPhone again.")
        case .timedOut: String(localized: "The iPhone app did not answer in time. Check that it is still on Camera for Mac.")
        case .refused(let reason): reason
        }
    }
}

// MARK: - The Mac's end

/// The Mac's end of one link: says hello, waits for `ready`, then asks for
/// photos and works the torch, and passes the preview frames on. Every
/// waiting caller is answered exactly once: by the iPhone, by its timeout or
/// by the link closing.
actor RemoteCameraSession {
    /// Sleeps for a duration; a clock's `sleep` in the app, instant or
    /// never-ending in tests.
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let channel: any RemoteCameraChannel
    private let sleep: Sleep
    private var photoWaiters: [UUID: CheckedContinuation<Data, any Error>] = [:]
    private var readyWaiter: CheckedContinuation<RemoteCameraInfo, any Error>?
    private var reader: Task<Void, Never>?
    private var closedBy: RemoteCameraFailure?
    private(set) var info: RemoteCameraInfo?
    private(set) var isTorchOn = false

    /// The iPhone's live frames as JPEGs, newest only: a slow viewer skips frames.
    nonisolated let previews: AsyncStream<Data>
    private let previewSink: AsyncStream<Data>.Continuation

    init(channel: any RemoteCameraChannel, sleep: @escaping Sleep = { try await ContinuousClock().sleep(for: $0) }) {
        self.channel = channel
        self.sleep = sleep
        (previews, previewSink) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(1))
    }

    var isOpen: Bool {
        info != nil && closedBy == nil
    }

    /// Says hello as `name` and waits for the iPhone's camera to be ready.
    func open(name: String, timeout: Duration = .seconds(10)) async throws -> RemoteCameraInfo {
        if let info { return info }
        startReading()
        try await channel.send(RemoteCameraFrame(.hello(version: RemoteCameraWire.version, name: name)))
        return try await withCheckedThrowingContinuation { continuation in
            if let closedBy {
                continuation.resume(throwing: closedBy)
                return
            }
            readyWaiter = continuation
            expire(after: timeout) { await $0.failReady(.timedOut) }
        }
    }

    /// Asks for a photo and waits for it: the full-size JPEG, upright.
    func capture(timeout: Duration = .seconds(20)) async throws -> Data {
        guard isOpen else { throw closedBy ?? .closed }
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            photoWaiters[id] = continuation
            Task {
                do {
                    try await channel.send(RemoteCameraFrame(.capture(id: id)))
                } catch {
                    answerPhoto(id, with: .failure(RemoteCameraFailure.closed))
                }
            }
            expire(after: timeout) { await $0.answerPhoto(id, with: .failure(RemoteCameraFailure.timedOut)) }
        }
    }

    func setTorch(_ isOn: Bool) async throws {
        guard isOpen else { throw closedBy ?? .closed }
        try await channel.send(RemoteCameraFrame(.setTorch(isOn)))
        self.isTorchOn = isOn
    }

    func close() async {
        await channel.close()
        finish(.closed)
    }

    // MARK: - Reading

    private func startReading() {
        guard reader == nil else { return }
        let incoming = channel.incoming
        reader = Task { [weak self] in
            do {
                for try await frame in incoming {
                    await self?.handle(frame)
                }
                await self?.finish(.closed)
            } catch {
                await self?.finish(.closed)
            }
        }
    }

    private func handle(_ frame: RemoteCameraFrame) {
        switch frame.message {
        case .ready(let info):
            guard info.version == RemoteCameraWire.version else {
                failReady(.versionMismatch(theirs: info.version))
                return
            }
            self.info = info
            readyWaiter?.resume(returning: info)
            readyWaiter = nil
        case .preview:
            previewSink.yield(frame.payload)
        case .photo(let id):
            answerPhoto(id, with: .success(frame.payload))
        case .failed(let id?, let message):
            answerPhoto(id, with: .failure(RemoteCameraFailure.refused(message)))
        case .failed(nil, let message):
            failReady(.refused(message))
            finish(.refused(message))
        case .torch(let isOn):
            isTorchOn = isOn
        case .hello, .capture, .setTorch:
            // The Mac's own messages; an iPhone never sends them.
            break
        }
    }

    private func answerPhoto(_ id: UUID, with result: Result<Data, any Error>) {
        photoWaiters.removeValue(forKey: id)?.resume(with: result)
    }

    private func failReady(_ failure: RemoteCameraFailure) {
        readyWaiter?.resume(throwing: failure)
        readyWaiter = nil
    }

    /// Ends the session: everyone still waiting is answered with `failure`.
    private func finish(_ failure: RemoteCameraFailure) {
        guard closedBy == nil else { return }
        closedBy = failure
        failReady(failure)
        for id in Array(photoWaiters.keys) {
            answerPhoto(id, with: .failure(failure))
        }
        previewSink.finish()
        reader?.cancel()
    }

    /// Runs `action` after `timeout` unless the session is gone; a no-op when
    /// the waiter it targets was already answered.
    private func expire(after timeout: Duration, _ action: @escaping @Sendable (RemoteCameraSession) async -> Void) {
        let sleep = sleep
        Task { [weak self] in
            guard (try? await sleep(timeout)) != nil, let self else { return }
            await action(self)
        }
    }
}

// MARK: - The iPhone's end

/// What the iPhone's camera does for the Mac. The live one wraps the app's
/// `CaptureEngine`.
nonisolated protocol RemoteCameraSource: Sendable {
    /// Starts the camera, so the phone shows its picture before a Mac connects.
    func start() async throws
    /// Starts the camera if it is not running and says what it gives.
    func info(deviceName: String) async throws -> RemoteCameraInfo
    func capturePhoto() async throws -> Data
    func setTorch(_ isOn: Bool) async throws
    /// Small JPEG frames for the Mac's viewfinder while the stream is read.
    func previewFrames() async -> AsyncStream<Data>
}

/// The iPhone's end of one link: answers the Mac's hello with what the camera
/// gives, takes a photo when asked, works the torch and streams preview
/// frames until the Mac goes.
nonisolated struct RemoteCameraHost: Sendable {
    /// What happened, for the Camera for Mac screen.
    enum Event: Hashable, Sendable {
        case connected(macName: String)
        case photoSent
        case failed(String)
    }

    let source: any RemoteCameraSource
    let deviceName: String

    /// Serves one Mac until the link closes.
    func serve(_ channel: any RemoteCameraChannel, events: @escaping @Sendable (Event) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            do {
                for try await frame in channel.incoming {
                    switch frame.message {
                    case .hello(let version, let name):
                        guard version == RemoteCameraWire.version else {
                            let failure = RemoteCameraFailure.versionMismatch(theirs: version)
                            try? await channel.send(RemoteCameraFrame(.failed(id: nil, message: failure.message)))
                            await events(.failed(failure.message))
                            await channel.close()
                            group.cancelAll()
                            return
                        }
                        do {
                            let info = try await source.info(deviceName: deviceName)
                            try await channel.send(RemoteCameraFrame(.ready(info)))
                            await events(.connected(macName: name))
                            group.addTask { await streamPreviews(to: channel) }
                        } catch {
                            try? await channel.send(RemoteCameraFrame(.failed(id: nil, message: String(describing: error))))
                            await events(.failed(String(describing: error)))
                        }
                    case .capture(let id):
                        do {
                            let photo = try await source.capturePhoto()
                            try await channel.send(RemoteCameraFrame(.photo(id: id), payload: photo))
                            await events(.photoSent)
                        } catch {
                            try? await channel.send(RemoteCameraFrame(.failed(id: id, message: ScanProblem(error).message)))
                        }
                    case .setTorch(let isOn):
                        do {
                            try await source.setTorch(isOn)
                            try await channel.send(RemoteCameraFrame(.torch(isOn)))
                        } catch {
                            try? await channel.send(RemoteCameraFrame(.torch(!isOn)))
                        }
                    case .ready, .preview, .photo, .failed, .torch:
                        // The iPhone's own messages; a Mac never sends them.
                        break
                    }
                }
            } catch {
                // The link dropped; the Mac will find the camera again.
            }
            group.cancelAll()
        }
    }

    /// Sends the newest frame whenever the last one has gone, so a slow link
    /// shows a lower frame rate, not a growing delay.
    private func streamPreviews(to channel: any RemoteCameraChannel) async {
        for await jpeg in await source.previewFrames() {
            guard !Task.isCancelled else { return }
            do {
                try await channel.send(RemoteCameraFrame(.preview, payload: jpeg))
            } catch {
                return
            }
        }
    }
}
