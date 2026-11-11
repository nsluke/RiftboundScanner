import Foundation
import Synchronization
#if os(macOS)
import Network
import os

/// Opens a link to an iPhone app the picker lists as a camera.
nonisolated protocol RemoteCameraConnecting: Sendable {
    /// Whether `id` names an iPhone app rather than a camera on this Mac.
    func handles(_ id: CameraDevice.ID) -> Bool
    func connect(_ id: CameraDevice.ID) async throws -> any RemoteCameraChannel
}

/// Finds iPhones whose Camera for Mac screen is open (their Bonjour service,
/// `RemoteCameraWire.serviceType`) and lists each as a camera; connects to
/// the one the picker chooses. A phone that closes the screen drops off the
/// list, which the camera source treats as a camera that went away.
nonisolated final class RemoteCameraBrowser: CameraDiscovering, RemoteCameraConnecting {
    static let idPrefix = "riftcam:"

    private let endpoints = Mutex<[CameraDevice.ID: NWEndpoint]>([:])
    private let logger = Logger(subsystem: "com.nsluke.RiftboundScanner", category: "remoteCamera")

    init() {}

    func handles(_ id: CameraDevice.ID) -> Bool {
        id.rawValue.hasPrefix(Self.idPrefix)
    }

    func devices() -> AsyncStream<[CameraDevice]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let loop = BrowseLoop()
            continuation.onTermination = { _ in loop.stop() }
            browse(into: continuation, loop: loop)
        }
    }

    /// Starts one browser. A failed browse is replaced after a pause rather
    /// than left failed: a Local Network permission granted while the app
    /// runs, or a network that comes back, only counts for a new browse.
    private func browse(into continuation: AsyncStream<[CameraDevice]>.Continuation, loop: BrowseLoop) {
        guard !loop.isStopped else { return }
        let browser = NWBrowser(for: .bonjour(type: RemoteCameraWire.serviceType, domain: nil), using: NetworkRemoteCameraChannel.parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            var found: [CameraDevice.ID: NWEndpoint] = [:]
            var devices: [CameraDevice] = []
            for result in results {
                guard case .service(let name, _, _, _) = result.endpoint else { continue }
                let device = Self.device(named: name)
                found[device.id] = result.endpoint
                devices.append(device)
            }
            self?.endpoints.withLock { $0 = found }
            self?.logger.notice("iPhone apps found: \(devices.map(\.name), privacy: .public)")
            continuation.yield(devices.sorted { $0.name < $1.name })
        }
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                continuation.yield([])
            case .waiting(let error):
                self?.logger.error("Looking for iPhone apps is waiting: \(String(describing: error), privacy: .public)")
                continuation.yield([])
            case .failed(let error):
                self?.logger.error("Looking for iPhone apps failed, trying again: \(String(describing: error), privacy: .public)")
                continuation.yield([])
                browser.cancel()
                loop.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.browse(into: continuation, loop: loop)
                }
            case .cancelled, .setup:
                break
            @unknown default:
                break
            }
        }
        loop.run(browser)
    }

    func connect(_ id: CameraDevice.ID) async throws -> any RemoteCameraChannel {
        guard let endpoint = endpoints.withLock({ $0[id] }) else { throw RemoteCameraFailure.closed }
        return try await NetworkRemoteCameraChannel.connect(to: endpoint)
    }

    /// How a phone's service appears in the picker; the torch is always there.
    static func device(named service: String) -> CameraDevice {
        CameraDevice(
            id: CameraDevice.ID(rawValue: idPrefix + service),
            name: String(localized: "\(service) (Riftbound app)"),
            kind: .iPhoneApp,
            hasTorch: true
        )
    }
}

/// The browser a discovery stream is running, and whether the stream ended.
nonisolated private final class BrowseLoop: Sendable {
    let queue = DispatchQueue(label: "com.nsluke.RiftboundScanner.remoteCameraBrowser")
    private let current = Mutex<NWBrowser?>(nil)
    private let stopped = Mutex(false)

    var isStopped: Bool {
        stopped.withLock { $0 }
    }

    func run(_ browser: NWBrowser) {
        current.withLock { $0 = browser }
        browser.start(queue: queue)
    }

    func stop() {
        stopped.withLock { $0 = true }
        current.withLock { $0?.cancel() }
    }
}
#endif

/// Several discoveries as one list: the Mac's own cameras beside the iPhone
/// apps on the network. Each source's latest list is kept, so one changing
/// never hides the other's, and nothing is announced until every source has
/// reported once: an early empty list would read as "no camera".
nonisolated struct MergedCameraDiscovery: CameraDiscovering {
    let sources: [any CameraDiscovering]

    func devices() -> AsyncStream<[CameraDevice]> {
        let sources = sources
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let latest = Mutex([[CameraDevice]?](repeating: nil, count: sources.count))
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    for (index, source) in sources.enumerated() {
                        group.addTask {
                            for await list in source.devices() {
                                let merged: [CameraDevice]? = latest.withLock { lists in
                                    lists[index] = list
                                    return lists.contains(nil) ? nil : lists.flatMap { $0 ?? [] }
                                }
                                if let merged {
                                    continuation.yield(merged)
                                }
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
