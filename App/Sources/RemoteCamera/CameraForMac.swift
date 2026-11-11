import AVFoundation
import Foundation
import Network
import SwiftUI

#if os(iOS)
/// The iPhone's camera as the Mac sees it (ADR-004): the app's own capture
/// engine, so the Mac gets the dual-wide camera's close-focus lens and 12 MP
/// photos, and small preview frames about eight times a second.
nonisolated struct EngineRemoteCameraSource: RemoteCameraSource {
    let engine: CaptureEngine

    func start() async throws {
        try await engine.start()
    }

    func info(deviceName: String) async throws -> RemoteCameraInfo {
        try await engine.start()
        guard let photoSize = await engine.uprightPhotoSize() else { throw CameraError.notStreaming }
        return RemoteCameraInfo(version: RemoteCameraWire.version, deviceName: deviceName, photoSize: photoSize, hasTorch: await engine.hasTorch())
    }

    func capturePhoto() async throws -> Data {
        try await engine.capturePhoto()
    }

    func setTorch(_ isOn: Bool) async throws {
        try await engine.setTorch(isOn)
    }

    func previewFrames() async -> AsyncStream<Data> {
        await engine.previewFrames(maxPixelSize: 960, interval: .milliseconds(125))
    }
}
#endif

/// What advertising the camera service reports.
nonisolated enum RemoteCameraAdvertisement: Sendable {
    /// Visible to Macs under this name.
    case advertising(name: String)
    case connected(any RemoteCameraChannel)
    case failed(String)
}

/// Makes the camera findable and hands over each Mac that connects. The live
/// one is `RemoteCameraListener`; tests script one.
nonisolated protocol RemoteCameraAdvertising: Sendable {
    func events() -> AsyncStream<RemoteCameraAdvertisement>
}

/// Advertises the Camera for Mac service on the local network over Bonjour.
nonisolated struct RemoteCameraListener: RemoteCameraAdvertising {
    func events() -> AsyncStream<RemoteCameraAdvertisement> {
        AsyncStream { continuation in
            let listener: NWListener
            do {
                listener = try NWListener(service: NWListener.Service(type: RemoteCameraWire.serviceType), using: NetworkRemoteCameraChannel.parameters)
            } catch {
                continuation.yield(.failed(error.localizedDescription))
                continuation.finish()
                return
            }
            listener.serviceRegistrationUpdateHandler = { change in
                if case .add(let endpoint) = change, case .service(let name, _, _, _) = endpoint {
                    continuation.yield(.advertising(name: name))
                }
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .failed(let error):
                    continuation.yield(.failed(Self.problem(error)))
                    continuation.finish()
                case .waiting(let error):
                    // Not advertised yet; it carries on by itself once allowed.
                    continuation.yield(.failed(Self.problem(error)))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { connection in
                continuation.yield(.connected(NetworkRemoteCameraChannel(connection: connection)))
            }
            continuation.onTermination = { _ in listener.cancel() }
            listener.start(queue: DispatchQueue(label: "com.nsluke.RiftboundScanner.remoteCameraListener"))
        }
    }

    /// Why the service is not advertised, in words the screen can show.
    static func problem(_ error: NWError) -> String {
        if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
            return String(localized: "Local Network access is off, so the Mac can't find this iPhone. Turn on Riftbound Scanner in Settings › Privacy & Security › Local Network.")
        }
        return error.localizedDescription
    }
}

/// The Camera for Mac screen's state: advertising, serving one Mac at a time
/// (a second Mac that connects takes over), and how many photos went.
@Observable
final class CameraForMacModel {
    enum Status: Hashable {
        case starting
        /// Advertised, no Mac yet.
        case waiting(name: String)
        case serving(macName: String)
        case failed(String)
    }

    private(set) var status = Status.starting
    private(set) var photosSent = 0
    private var advertisedName = ""
    /// The Mac being served, closed when another takes over.
    private var current: (number: Int, channel: any RemoteCameraChannel)?
    private var connections = 0

    private let listener: any RemoteCameraAdvertising
    private let host: RemoteCameraHost

    init(listener: any RemoteCameraAdvertising, host: RemoteCameraHost) {
        self.listener = listener
        self.host = host
    }

    /// Runs until the screen goes: advertises, serves each Mac that connects,
    /// and turns the torch off on the way out.
    func run() async {
        do {
            try await host.source.start()
        } catch {
            status = .failed(ScanProblem(error).message)
            return
        }
        await withTaskGroup(of: Void.self) { group in
            for await event in listener.events() {
                switch event {
                case .advertising(let name):
                    advertisedName = name
                    if case .serving = status {} else { status = .waiting(name: name) }
                case .connected(let channel):
                    // Closing the old link ends its serving task; cancelling
                    // the group would cancel the new one too.
                    await current?.channel.close()
                    connections += 1
                    let number = connections
                    current = (number, channel)
                    group.addTask { await self.serve(channel, number: number) }
                case .failed(let message):
                    status = .failed(message)
                }
            }
            await current?.channel.close()
        }
        try? await host.source.setTorch(false)
    }

    private func serve(_ channel: any RemoteCameraChannel, number: Int) async {
        await host.serve(channel) { event in
            await self.apply(event)
        }
        await channel.close()
        // A link replaced by a newer Mac leaves the screen to that one.
        if current?.number == number {
            current = nil
            status = .waiting(name: advertisedName)
        }
    }

    private func apply(_ event: RemoteCameraHost.Event) {
        switch event {
        case .connected(let macName): status = .serving(macName: macName)
        case .photoSent: photosSent += 1
        case .failed(let message): status = .failed(message)
        }
    }
}

#if os(iOS)
/// The iPhone as the Mac's camera: the camera's picture, where the Mac can
/// find it, and how many photos went. The screen stays awake while it is up,
/// since iOS stops the camera of an app that leaves the screen.
struct CameraForMacView: View {
    @State private var model: CameraForMacModel
    let session: AVCaptureSession

    @Environment(\.dismiss) private var dismiss

    init(model: @autoclosure @escaping () -> CameraForMacModel, session: AVCaptureSession) {
        _model = State(wrappedValue: model())
        self.session = session
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            CameraPreview(session: session)
                .ignoresSafeArea()
                .accessibilityLabel("The camera's picture, as the Mac sees it")
            VStack(alignment: .leading, spacing: 12) {
                Label(headline, systemImage: symbol)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                if model.photosSent > 0 {
                    Text("\(model.photosSent) photos sent")
                        .font(.subheadline.monospacedDigit())
                }
                Button("Done") { dismiss() }
                    .prominentAction(Theme.amber)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding()
            .background(Theme.ground.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
            .padding()
            .foregroundStyle(Theme.text)
            .accessibilityElement(children: .contain)
        }
        .background(Color.black)
        .task { await model.run() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var headline: String {
        switch model.status {
        case .starting: String(localized: "Starting the camera…")
        case .waiting: String(localized: "Waiting for your Mac")
        case .serving(let macName): String(localized: "Camera for \(macName)")
        case .failed: String(localized: "Can't be the Mac's camera")
        }
    }

    private var detail: String {
        switch model.status {
        case .starting:
            String(localized: "The Mac will find this iPhone once the camera is running.")
        case .waiting(let name):
            String(localized: "The Mac switches to \(name) (Riftbound app) on its own and connects to the feeder, which this phone has let go of. Keep this screen open and the phone on the stand.")
        case .serving:
            String(localized: "The Mac takes the photos and drives the feeder. Keep this screen open until the run is done; connect the feeder here again afterwards.")
        case .failed(let message):
            message
        }
    }

    private var symbol: String {
        switch model.status {
        case .starting: "hourglass"
        case .waiting: "dot.radiowaves.left.and.right"
        case .serving: "macbook.and.iphone"
        case .failed: "exclamationmark.triangle"
        }
    }
}
#endif
