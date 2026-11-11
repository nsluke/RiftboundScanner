import Foundation
import RiftboundRecognizer
import Synchronization
import Testing
@testable import RiftboundScannerApp

// MARK: - Fakes

/// Two connected ends in memory. Every frame goes through the wire codec, so
/// what arrives is what would have survived the network.
nonisolated final class LoopbackChannel: RemoteCameraChannel {
    let incoming: AsyncThrowingStream<RemoteCameraFrame, any Error>
    private let inbox: AsyncThrowingStream<RemoteCameraFrame, any Error>.Continuation
    private let peer = Mutex<LoopbackChannel?>(nil)
    private let decoder = Mutex(RemoteCameraFrameCodec.Decoder())

    private init() {
        (incoming, inbox) = AsyncThrowingStream.makeStream(of: RemoteCameraFrame.self)
    }

    static func pair() -> (LoopbackChannel, LoopbackChannel) {
        let mac = LoopbackChannel()
        let phone = LoopbackChannel()
        mac.peer.withLock { $0 = phone }
        phone.peer.withLock { $0 = mac }
        return (mac, phone)
    }

    func send(_ frame: RemoteCameraFrame) async throws {
        guard let peer = peer.withLock({ $0 }) else { throw RemoteCameraFailure.closed }
        let bytes = try RemoteCameraFrameCodec.encode(frame)
        for received in try peer.decoder.withLock({ try $0.append(bytes) }) {
            peer.inbox.yield(received)
        }
    }

    func close() async {
        let peer = peer.withLock { current in defer { current = nil }; return current }
        inbox.finish()
        peer?.inbox.finish()
    }
}

/// The iPhone's camera, scripted.
actor FakeRemoteSource: RemoteCameraSource {
    private(set) var torch = false
    private(set) var captures = 0
    private(set) var started = 0
    var failsCapture: String?
    private let frames: [Data]

    init(frames: [Data] = [], failsCapture: String? = nil) {
        self.frames = frames
        self.failsCapture = failsCapture
    }

    static let info = RemoteCameraInfo(version: RemoteCameraWire.version, deviceName: "Lukes-iPhone", photoSize: PixelSize(width: 3024, height: 4032), hasTorch: true)

    func start() {
        started += 1
    }

    func info(deviceName: String) -> RemoteCameraInfo {
        Self.info
    }

    func capturePhoto() throws -> Data {
        if let failsCapture { throw RemoteCameraFailure.refused(failsCapture) }
        captures += 1
        return Data("photo-\(captures)".utf8)
    }

    func setTorch(_ isOn: Bool) {
        torch = isOn
    }

    func previewFrames() -> AsyncStream<Data> {
        let frames = frames
        return AsyncStream { continuation in
            for frame in frames { continuation.yield(frame) }
        }
    }
}

/// Collects the host's events.
actor HostEvents {
    private(set) var events: [RemoteCameraHost.Event] = []

    func record(_ event: RemoteCameraHost.Event) {
        events.append(event)
    }
}

/// Waits until `condition` holds, polling briefly; for effects that land on
/// another task.
func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// A phone serving one Mac over a loopback pair: the Mac's session, the host's
/// task and its events.
struct ServedPhone {
    let session: RemoteCameraSession
    let source: FakeRemoteSource
    let events: HostEvents
    let hosting: Task<Void, Never>

    init(source: FakeRemoteSource = FakeRemoteSource(), sleep: @escaping RemoteCameraSession.Sleep = { try await Task.sleep(for: $0) }) {
        let (mac, phone) = LoopbackChannel.pair()
        let events = HostEvents()
        self.events = events
        self.source = source
        session = RemoteCameraSession(channel: mac, sleep: sleep)
        hosting = Task {
            await RemoteCameraHost(source: source, deviceName: "Lukes-iPhone").serve(phone) { await events.record($0) }
        }
    }
}

// MARK: - Wire

@Suite("Remote camera wire")
struct RemoteCameraWireTests {
    @Test func aFrameAndItsPayloadSurviveTheWire() throws {
        let frame = RemoteCameraFrame(.photo(id: UUID()), payload: Data([0xFF, 0xD8, 0x00, 0xFF, 0xD9]))
        var decoder = RemoteCameraFrameCodec.Decoder()
        #expect(try decoder.append(RemoteCameraFrameCodec.encode(frame)) == [frame])
    }

    @Test func framesArriveWhateverTheChunking() throws {
        let frames = [
            RemoteCameraFrame(.hello(version: 1, name: "Luke's MacBook Pro")),
            RemoteCameraFrame(.preview, payload: Data(repeating: 7, count: 3000)),
            RemoteCameraFrame(.torch(true)),
        ]
        let bytes = try frames.reduce(into: Data()) { $0.append(try RemoteCameraFrameCodec.encode($1)) }

        var whole = RemoteCameraFrameCodec.Decoder()
        #expect(try whole.append(bytes) == frames, "several frames in one chunk")

        var trickle = RemoteCameraFrameCodec.Decoder()
        var received: [RemoteCameraFrame] = []
        for byte in bytes {
            received += try trickle.append(Data([byte]))
        }
        #expect(received == frames, "one byte at a time")
    }

    @Test func everyMessageRoundTrips() throws {
        let id = UUID()
        let messages: [RemoteCameraMessage] = [
            .hello(version: 1, name: "Mac"), .capture(id: id), .setTorch(false), .ready(FakeRemoteSource.info),
            .preview, .photo(id: id), .failed(id: id, message: "No camera"), .failed(id: nil, message: "Gone"), .torch(true),
        ]
        for message in messages {
            var decoder = RemoteCameraFrameCodec.Decoder()
            #expect(try decoder.append(RemoteCameraFrameCodec.encode(RemoteCameraFrame(message))).map(\.message) == [message])
        }
    }

    @Test func aLengthBeyondTheCapIsRefused() {
        var decoder = RemoteCameraFrameCodec.Decoder()
        #expect(throws: RemoteCameraFrameCodec.Failure.oversize(0x7FFF_FFFF)) {
            try decoder.append(Data([0x7F, 0xFF, 0xFF, 0xFF]))
        }
    }
}

// MARK: - Session and host

@Suite("Remote camera link")
struct RemoteCameraLinkTests {
    @Test func theMacSaysHelloAndLearnsWhatTheCameraGives() async throws {
        let phone = ServedPhone()

        let info = try await phone.session.open(name: "Luke's MacBook Pro")

        #expect(info == FakeRemoteSource.info)
        #expect(await phone.session.isOpen)
        #expect(await eventually { await phone.events.events.first == .connected(macName: "Luke's MacBook Pro") })
    }

    @Test func aCaptureBringsBackThePhoneSPhoto() async throws {
        let phone = ServedPhone()
        _ = try await phone.session.open(name: "Mac")

        #expect(try await phone.session.capture() == Data("photo-1".utf8))
        #expect(try await phone.session.capture() == Data("photo-2".utf8))
        #expect(await eventually { await phone.events.events.filter { $0 == .photoSent }.count == 2 })
    }

    @Test func aFailedCaptureSaysWhy() async throws {
        let phone = ServedPhone(source: FakeRemoteSource(failsCapture: "The camera is busy"))
        _ = try await phone.session.open(name: "Mac")

        await #expect(throws: RemoteCameraFailure.refused("The camera is busy")) {
            try await phone.session.capture()
        }
        #expect(await phone.session.isOpen, "one failed photo does not end the link")
    }

    @Test func theTorchFollowsTheMac() async throws {
        let phone = ServedPhone()
        _ = try await phone.session.open(name: "Mac")

        try await phone.session.setTorch(true)

        #expect(await eventually { await phone.source.torch })
        #expect(await phone.session.isTorchOn)
    }

    @Test func previewFramesReachTheMac() async throws {
        let frame = Data("frame".utf8)
        let phone = ServedPhone(source: FakeRemoteSource(frames: [frame]))
        _ = try await phone.session.open(name: "Mac")

        var iterator = phone.session.previews.makeAsyncIterator()
        #expect(await iterator.next() == frame)
    }

    @Test func aPhoneThatNeverAnswersTimesOut() async throws {
        let (mac, _) = LoopbackChannel.pair()
        let session = RemoteCameraSession(channel: mac, sleep: { _ in })

        await #expect(throws: RemoteCameraFailure.timedOut) {
            try await session.open(name: "Mac")
        }
    }

    @Test func aDroppedLinkAnswersTheWaitingCapture() async throws {
        let (mac, phone) = LoopbackChannel.pair()
        let session = RemoteCameraSession(channel: mac, sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        let answering = Task {
            for try await frame in phone.incoming {
                if case .hello = frame.message {
                    try await phone.send(RemoteCameraFrame(.ready(FakeRemoteSource.info)))
                } else if case .capture = frame.message {
                    await phone.close()
                }
            }
        }
        _ = try await session.open(name: "Mac")

        await #expect(throws: RemoteCameraFailure.closed) {
            try await session.capture()
        }
        #expect(await !session.isOpen)
        answering.cancel()
    }

    @Test func aPhoneOnAnotherVersionIsRefused() async throws {
        let (mac, phone) = LoopbackChannel.pair()
        let session = RemoteCameraSession(channel: mac, sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        let answering = Task {
            for try await frame in phone.incoming {
                if case .hello = frame.message {
                    try await phone.send(RemoteCameraFrame(.ready(RemoteCameraInfo(version: 99, deviceName: "Future", photoSize: PixelSize(width: 1, height: 1), hasTorch: false))))
                }
            }
        }

        await #expect(throws: RemoteCameraFailure.versionMismatch(theirs: 99)) {
            try await session.open(name: "Mac")
        }
        answering.cancel()
    }

    @Test func thePhoneRefusesAMacOnAnotherVersion() async throws {
        let (mac, phone) = LoopbackChannel.pair()
        let events = HostEvents()
        let hosting = Task {
            await RemoteCameraHost(source: FakeRemoteSource(), deviceName: "Phone").serve(phone) { await events.record($0) }
        }

        try await mac.send(RemoteCameraFrame(.hello(version: 99, name: "Old Mac")))

        var iterator = mac.incoming.makeAsyncIterator()
        let answer = try await iterator.next()
        guard case .failed(nil, let message)? = answer?.message else {
            Issue.record("expected a failure, got \(String(describing: answer))")
            return
        }
        #expect(message.contains("99"))
        await hosting.value
        #expect(await events.events.count == 1)
    }
}

// MARK: - The Mac's camera

/// The Mac's own capture engine, scripted.
actor FakeLocalCamera: CameraOperating, CameraSwitching {
    private(set) var calls: [String] = []

    func requestAccess() -> Bool {
        calls.append("requestAccess")
        return true
    }

    func start() {
        calls.append("start")
    }

    func stop() {
        calls.append("stop")
    }

    func setTorch(_ isOn: Bool) {
        calls.append("torch \(isOn)")
    }

    func capturePhoto() -> Data {
        calls.append("capture")
        return Data("local".utf8)
    }

    func use(_ device: CameraDevice.ID) -> PixelSize? {
        calls.append("use \(device.rawValue)")
        return PixelSize(width: 1920, height: 1080)
    }

    func setRotation(_ rotation: CameraRotation) {
        calls.append("rotation")
    }
}

#if os(macOS)
/// Connects to phones served in memory.
nonisolated struct FakePhoneConnector: RemoteCameraConnecting {
    let source: FakeRemoteSource
    var reachable = true

    func handles(_ id: CameraDevice.ID) -> Bool {
        id.rawValue.hasPrefix(RemoteCameraBrowser.idPrefix)
    }

    func connect(_ id: CameraDevice.ID) async throws -> any RemoteCameraChannel {
        guard reachable else { throw RemoteCameraFailure.timedOut }
        let (mac, phone) = LoopbackChannel.pair()
        let source = source
        Task {
            await RemoteCameraHost(source: source, deviceName: "Lukes-iPhone").serve(phone) { _ in }
        }
        return mac
    }
}

/// Counts how many links were opened.
nonisolated final class CountingConnector: RemoteCameraConnecting {
    let inner: FakePhoneConnector
    private let count = Mutex(0)

    init(inner: FakePhoneConnector) {
        self.inner = inner
    }

    var connections: Int { count.withLock { $0 } }

    func handles(_ id: CameraDevice.ID) -> Bool {
        inner.handles(id)
    }

    func connect(_ id: CameraDevice.ID) async throws -> any RemoteCameraChannel {
        count.withLock { $0 += 1 }
        return try await inner.connect(id)
    }
}

@Suite("The Mac's camera")
struct MacCameraTests {
    private let phone = RemoteCameraBrowser.device(named: "Lukes-iPhone")

    @Test func theIPhoneAppIsUsedOverTheNetworkAndTheMacCameraIsFreed() async throws {
        let local = FakeLocalCamera()
        let source = FakeRemoteSource()
        let camera = MacCamera(local: local, remote: FakePhoneConnector(source: source), hostName: "Mac")

        let size = await camera.use(phone.id)

        #expect(size == PixelSize(width: 3024, height: 4032), "the phone's upright photo size")
        #expect(await local.calls == ["stop"])
        #expect(await camera.requestAccess(), "no camera access is asked of the Mac")
        try await camera.start()
        #expect(try await camera.capturePhoto() == Data("photo-1".utf8))
        try await camera.setTorch(true)
        #expect(await eventually { await source.torch })
        #expect(await local.calls == ["stop"], "the Mac's own camera was never asked")
    }

    @Test func aMacCameraIsUsedDirectly() async throws {
        let local = FakeLocalCamera()
        let camera = MacCamera(local: local, remote: FakePhoneConnector(source: FakeRemoteSource()), hostName: "Mac")

        #expect(await camera.use(CameraDevice.iPhone.id) == PixelSize(width: 1920, height: 1080))
        #expect(await camera.requestAccess())
        try await camera.start()
        #expect(try await camera.capturePhoto() == Data("local".utf8))
        #expect(await local.calls == ["use iphone-a", "requestAccess", "start", "capture"])
    }

    @Test func switchesRunOneAtATimeAndAnOpenLinkIsKept() async throws {
        let connector = CountingConnector(inner: FakePhoneConnector(source: FakeRemoteSource()))
        let camera = MacCamera(local: FakeLocalCamera(), remote: connector, hostName: "Mac")

        async let first = camera.use(phone.id)
        async let second = camera.use(phone.id)
        let sizes = await [first, second]

        #expect(sizes == [PixelSize(width: 3024, height: 4032), PixelSize(width: 3024, height: 4032)])
        #expect(connector.connections == 1, "the second switch found the link open and kept it")
        #expect(try await camera.capturePhoto() == Data("photo-1".utf8))
    }

    @Test func anUnreachablePhoneIsReportedWhenTheScannerStarts() async throws {
        var connector = FakePhoneConnector(source: FakeRemoteSource())
        connector.reachable = false
        let camera = MacCamera(local: FakeLocalCamera(), remote: connector, hostName: "Mac")

        #expect(await camera.use(phone.id) == nil)
        await #expect(throws: RemoteCameraFailure.timedOut) {
            try await camera.start()
        }
    }

    @Test func theIPhoneAppIsListedAsTheBestCamera() {
        #expect(phone.kind == .iPhoneApp)
        #expect(phone.hasTorch)
        #expect(phone.name.contains("Lukes-iPhone"))
        #expect(CameraSelection.preferred(among: [.builtIn, .iPhone, phone], saved: nil) == phone)
        #expect(CameraSelection.source(after: .using(.iPhone), devices: [.iPhone, phone], saved: nil) == .using(phone), "it takes over from Continuity Camera when it appears")
        #expect(CameraSelection.source(after: .lost(.iPhone), devices: [.builtIn, phone], saved: CameraDevice.iPhone.id) == .using(phone), "Continuity Camera drops out when the app takes the phone's camera; the app takes over")
        #expect(CameraSelection.source(after: .using(.builtIn), devices: [.builtIn, phone], saved: CameraDevice.builtIn.id) == .using(.builtIn), "a camera picked by hand and still there is kept")
        #expect(CameraSelection.source(after: .lost(phone), devices: [.iPhone], saved: nil) == .lost(phone), "closing Camera for Mac waits for it rather than switching lenses mid-run")
    }
}
#endif

// MARK: - Discovery

@Suite("Merged camera discovery")
struct MergedCameraDiscoveryTests {
    @Test func listsEverySourceOnceAllHaveReported() async {
        let phone = CameraDevice(id: CameraDevice.ID(rawValue: "riftcam:Lukes-iPhone"), name: "Lukes-iPhone (Riftbound app)", kind: .iPhoneApp, hasTorch: true)
        let merged = MergedCameraDiscovery(sources: [
            ScriptedCameraDiscovery([.builtIn], [.builtIn, .iPhone]),
            ScriptedCameraDiscovery([], [phone]),
        ])

        var lists: [[CameraDevice]] = []
        for await list in merged.devices() {
            lists.append(list)
        }

        #expect(lists.last.map { Set($0.map(\.id)) } == Set([CameraDevice.builtIn.id, CameraDevice.iPhone.id, phone.id]))
        #expect(lists.allSatisfy { $0.contains(.builtIn) }, "nothing is announced before the Mac's own cameras have reported")
    }
}

// MARK: - The iPhone's screen

/// Advertising, scripted: the name, then the Macs that connect.
nonisolated struct ScriptedAdvertiser: RemoteCameraAdvertising {
    let channels: [any RemoteCameraChannel]

    func events() -> AsyncStream<RemoteCameraAdvertisement> {
        let channels = channels
        return AsyncStream { continuation in
            continuation.yield(.advertising(name: "Lukes-iPhone"))
            for channel in channels {
                continuation.yield(.connected(channel))
            }
        }
    }
}

@Suite("Camera for Mac screen")
struct CameraForMacModelTests {
    @Test func waitsThenServesAMacAndCountsItsPhotos() async throws {
        let (mac, phone) = LoopbackChannel.pair()
        let source = FakeRemoteSource()
        let model = CameraForMacModel(listener: ScriptedAdvertiser(channels: [phone]), host: RemoteCameraHost(source: source, deviceName: "Lukes-iPhone"))
        let running = Task { await model.run() }

        let session = RemoteCameraSession(channel: mac)
        _ = try await session.open(name: "Luke's MacBook Pro")
        #expect(await eventually { await model.status == .serving(macName: "Luke's MacBook Pro") })
        _ = try await session.capture()
        #expect(await eventually { await model.photosSent == 1 })
        #expect(await source.started == 1, "the camera starts with the screen")

        await session.close()
        #expect(await eventually { await model.status == .waiting(name: "Lukes-iPhone") }, "back to waiting when the Mac goes")
        running.cancel()
    }

    @Test func aSecondMacTakesOverFromTheFirst() async throws {
        let (firstMac, firstPhone) = LoopbackChannel.pair()
        let (secondMac, secondPhone) = LoopbackChannel.pair()
        let model = CameraForMacModel(listener: ScriptedAdvertiser(channels: [firstPhone, secondPhone]), host: RemoteCameraHost(source: FakeRemoteSource(), deviceName: "Lukes-iPhone"))
        let running = Task { await model.run() }

        let second = RemoteCameraSession(channel: secondMac)
        _ = try await second.open(name: "Second Mac")

        #expect(await eventually { await model.status == .serving(macName: "Second Mac") })
        await #expect(throws: RemoteCameraFailure.closed) {
            try await RemoteCameraSession(channel: firstMac).open(name: "First Mac")
        }
        #expect(try await second.capture() == Data("photo-1".utf8), "the newer link keeps working")
        running.cancel()
    }
}
