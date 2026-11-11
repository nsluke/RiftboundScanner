import Foundation
import RiftboundRecognizer

/// The iPhone app as the Mac's camera (ADR-004). Continuity Camera only gives
/// a Mac the iPhone's main lens, which cannot focus on a card that close to
/// the stand; the iPhone app's dual-wide camera drops to the 0.5× lens and
/// takes 12 MP photos. So the iPhone app serves its camera on the local
/// network and the Mac's scan page uses it like any other camera: a live
/// preview, a photo on request and the torch.
nonisolated enum RemoteCameraWire {
    /// The Bonjour service the iPhone advertises while its Camera for Mac
    /// screen is open. Listed in both apps' `NSBonjourServices`.
    static let serviceType = "_riftcam._tcp"
    /// Both sides send theirs first; a mismatch ends the link with a message.
    static let version = 1
}

/// What the apps say to each other. A JPEG travels as the frame's payload,
/// next to the message rather than inside it.
nonisolated enum RemoteCameraMessage: Hashable, Sendable, Codable {
    // The Mac to the iPhone.
    /// The first message: who is asking, and which wire version it speaks.
    case hello(version: Int, name: String)
    /// Take a photo; answered with `photo` or `failed` under the same id.
    case capture(id: UUID)
    case setTorch(Bool)

    // The iPhone to the Mac.
    /// The answer to `hello`: the camera is running and this is what it gives.
    case ready(RemoteCameraInfo)
    /// A small live frame for the Mac's viewfinder; the payload is a JPEG.
    case preview
    /// The photo `capture(id)` asked for; the payload is the JPEG.
    case photo(id: UUID)
    /// Why a capture (or, with no id, the link) failed.
    case failed(id: UUID?, message: String)
    /// The torch as it now is.
    case torch(Bool)
}

/// What the iPhone's camera gives, sent once in `ready`.
nonisolated struct RemoteCameraInfo: Hashable, Sendable, Codable {
    let version: Int
    /// The phone's name as it advertises itself.
    let deviceName: String
    /// The photo's size, upright: the phone turns its photos before sending.
    let photoSize: PixelSize
    let hasTorch: Bool
}

/// One message and its payload, as framed on the wire.
nonisolated struct RemoteCameraFrame: Hashable, Sendable {
    let message: RemoteCameraMessage
    let payload: Data

    init(_ message: RemoteCameraMessage, payload: Data = Data()) {
        self.message = message
        self.payload = payload
    }
}

/// Frames on a byte stream: a 4-byte big-endian length, the message as JSON,
/// a 4-byte big-endian length, then the payload. Pure, so the framing is
/// tested without a network.
nonisolated enum RemoteCameraFrameCodec {
    enum Failure: Error, Hashable {
        /// A length beyond the caps: the other side is not this app, or the
        /// stream lost its place.
        case oversize(Int)
        case unreadableMessage(String)
    }

    /// A message is a few hundred bytes; 64 KB is a corrupt length, not a message.
    static let maximumMessageBytes = 64 * 1024
    /// A 48 MP HEIC-sized JPEG fits with room to spare.
    static let maximumPayloadBytes = 32 * 1024 * 1024

    static func encode(_ frame: RemoteCameraFrame) throws -> Data {
        let message = try JSONEncoder().encode(frame.message)
        var data = Data(capacity: 8 + message.count + frame.payload.count)
        data.append(bigEndian: UInt32(message.count))
        data.append(message)
        data.append(bigEndian: UInt32(frame.payload.count))
        data.append(frame.payload)
        return data
    }

    /// Turns the bytes as they arrive, in whatever chunks, back into frames.
    struct Decoder: Sendable {
        private var buffer = Data()

        init() {}

        /// Every frame the bytes so far complete; a partial frame waits for more.
        mutating func append(_ bytes: Data) throws(Failure) -> [RemoteCameraFrame] {
            buffer.append(bytes)
            var frames: [RemoteCameraFrame] = []
            while let frame = try nextFrame() {
                frames.append(frame)
            }
            return frames
        }

        private mutating func nextFrame() throws(Failure) -> RemoteCameraFrame? {
            guard let messageLength = buffer.bigEndianUInt32(at: 0) else { return nil }
            guard messageLength <= maximumMessageBytes else { throw .oversize(messageLength) }
            guard let payloadLength = buffer.bigEndianUInt32(at: 4 + messageLength) else { return nil }
            guard payloadLength <= maximumPayloadBytes else { throw .oversize(payloadLength) }
            let total = 8 + messageLength + payloadLength
            guard buffer.count >= total else { return nil }
            let start = buffer.startIndex
            let messageBytes = buffer[(start + 4)..<(start + 4 + messageLength)]
            let payload = Data(buffer[(start + 8 + messageLength)..<(start + total)])
            buffer = Data(buffer[(start + total)...])
            do {
                return RemoteCameraFrame(try JSONDecoder().decode(RemoteCameraMessage.self, from: messageBytes), payload: payload)
            } catch {
                throw .unreadableMessage(String(describing: error))
            }
        }
    }
}

private extension Data {
    nonisolated mutating func append(bigEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    /// The 4-byte big-endian length at `offset` from the start, once it has arrived.
    nonisolated func bigEndianUInt32(at offset: Int) -> Int? {
        guard count >= offset + 4 else { return nil }
        let start = startIndex + offset
        return self[start..<(start + 4)].reduce(0) { $0 << 8 | Int($1) }
    }
}
