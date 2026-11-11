import Foundation
import Synchronization
#if os(macOS)
import Network

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

    init() {}

    func handles(_ id: CameraDevice.ID) -> Bool {
        id.rawValue.hasPrefix(Self.idPrefix)
    }

    func devices() -> AsyncStream<[CameraDevice]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
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
                continuation.yield(devices.sorted { $0.name < $1.name })
            }
            browser.stateUpdateHandler = { state in
                switch state {
                case .ready: continuation.yield([])
                case .failed, .cancelled: continuation.yield([])
                default: break
                }
            }
            continuation.onTermination = { _ in browser.cancel() }
            browser.start(queue: DispatchQueue(label: "com.nsluke.RiftboundScanner.remoteCameraBrowser"))
        }
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
