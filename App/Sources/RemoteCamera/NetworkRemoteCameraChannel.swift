import Foundation
import Network
import Synchronization

/// A `RemoteCameraChannel` over one TCP connection, from either end: the Mac
/// opens it to the iPhone's Bonjour service, the iPhone accepts it.
///
/// `NWConnection` delivers its callbacks on the queue it was started on and
/// is documented as safe to send on from any thread; the decoder is touched
/// only from the receive callbacks, which run one at a time on that queue.
/// That is the justification for `@unchecked Sendable`.
nonisolated final class NetworkRemoteCameraChannel: RemoteCameraChannel, @unchecked Sendable {
    let incoming: AsyncThrowingStream<RemoteCameraFrame, any Error>

    private let connection: NWConnection
    private let continuation: AsyncThrowingStream<RemoteCameraFrame, any Error>.Continuation
    private var decoder = RemoteCameraFrameCodec.Decoder()

    /// Both ends use plain TCP on a network they share (Wi-Fi, or the USB
    /// link when the phone is plugged into the Mac); peer-to-peer Wi-Fi is off.
    static var parameters: NWParameters {
        NWParameters.tcp
    }

    /// Takes over `connection`, which may not be started yet.
    init(connection: NWConnection, queue: DispatchQueue = DispatchQueue(label: "com.nsluke.RiftboundScanner.remoteCamera")) {
        self.connection = connection
        (incoming, continuation) = AsyncThrowingStream.makeStream(of: RemoteCameraFrame.self)
        continuation.onTermination = { [connection] _ in connection.cancel() }
        connection.stateUpdateHandler = { [continuation] state in
            switch state {
            case .failed(let error): continuation.finish(throwing: error)
            case .cancelled: continuation.finish()
            default: break
            }
        }
        if connection.state == .setup {
            connection.start(queue: queue)
        }
        receive()
    }

    /// Opens a connection to `endpoint` and waits until it is ready.
    static func connect(to endpoint: NWEndpoint, timeout: Duration = .seconds(5)) async throws -> NetworkRemoteCameraChannel {
        let connection = NWConnection(to: endpoint, using: parameters)
        let ready = Mutex(false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let answered = Mutex(false)
            let answer: @Sendable (Result<Void, any Error>) -> Void = { result in
                guard answered.withLock({ was in defer { was = true }; return !was }) else { return }
                continuation.resume(with: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    ready.withLock { $0 = true }
                    answer(.success(()))
                case .failed(let error), .waiting(let error):
                    answer(.failure(error))
                case .cancelled:
                    answer(.failure(RemoteCameraFailure.closed))
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "com.nsluke.RiftboundScanner.remoteCamera"))
            Task {
                try? await ContinuousClock().sleep(for: timeout)
                answer(.failure(RemoteCameraFailure.timedOut))
            }
        }
        guard ready.withLock({ $0 }) else {
            connection.cancel()
            throw RemoteCameraFailure.timedOut
        }
        return NetworkRemoteCameraChannel(connection: connection)
    }

    func send(_ frame: RemoteCameraFrame) async throws {
        let data = try RemoteCameraFrameCodec.encode(frame)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func close() async {
        connection.cancel()
        continuation.finish()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    for frame in try decoder.append(data) {
                        continuation.yield(frame)
                    }
                } catch {
                    continuation.finish(throwing: error)
                    connection.cancel()
                    return
                }
            }
            if let error {
                continuation.finish(throwing: error)
            } else if isComplete {
                continuation.finish()
            } else {
                receive()
            }
        }
    }
}
