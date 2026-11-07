import Accelerate
import CoreGraphics
import CryptoKit
import Foundation

/// Vision's image feature print (768 floats on current systems), stored
/// unit-normalised so that similarity is a single dot product.
///
/// Encodes as little-endian Float32 bytes (base64 in JSON) to keep index files small.
public struct FeaturePrint: Hashable, Sendable, Codable {
    public let elements: [Float]

    public init(elements: [Float]) {
        let norm = sqrt(vDSP.sumOfSquares(elements))
        self.elements = norm > 0 ? vDSP.divide(elements, norm) : elements
    }

    /// Stores values that were normalised already, so decoding is bit-exact.
    private init(normalized elements: [Float]) {
        self.elements = elements
    }

    /// Cosine similarity clamped to 0...1; 1 means identical.
    public func similarity(to other: FeaturePrint) -> Double {
        guard !elements.isEmpty, elements.count == other.elements.count else { return 0 }
        return Double(min(max(vDSP.dot(elements, other.elements), 0), 1))
    }

    /// Reads packed little-endian Float32 values, which is both Vision's native
    /// layout on Apple silicon and the index file's encoding.
    public init(float32Data data: Data) {
        self.init(elements: Self.floats(from: data))
    }

    private static func floats(from data: Data) -> [Float] {
        data.withUnsafeBytes { raw -> [Float] in
            (0..<(raw.count / 4)).map { index in
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)))
            }
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let data = try container.decode(Data.self)
        guard data.count % 4 == 0 else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "feature print byte count is not a multiple of 4")
        }
        self.init(normalized: Self.floats(from: data))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(float32Data)
    }

    /// The elements as packed little-endian Float32 bytes: the index file's
    /// encoding, and the bytes the ``digest`` is computed over.
    public var float32Data: Data {
        var data = Data(capacity: elements.count * 4)
        for element in elements {
            var bits = element.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// A short, stable identifier for this exact print: the first 16 bytes of
    /// SHA-256 over ``float32Data``. Two prints share a digest only when every
    /// element is bit-identical, which is what makes it usable as the key that
    /// groups artefacts computed in the same embedding space.
    public var digest: Digest {
        Digest(bytes: Array(SHA256.hash(data: float32Data).prefix(Digest.byteCount)))
    }

    /// Sixteen bytes identifying one feature print; see ``FeaturePrint/digest``.
    /// Encodes as 32 lowercase hexadecimal characters.
    public struct Digest: Hashable, Sendable, Codable, CustomStringConvertible {
        public static let byteCount = 16

        public let bytes: [UInt8]

        /// `bytes` must hold exactly ``byteCount`` values.
        public init(bytes: [UInt8]) {
            precondition(bytes.count == Self.byteCount, "a digest is \(Self.byteCount) bytes")
            self.bytes = bytes
        }

        /// Parses the hexadecimal form; `nil` for anything but 32 hex digits.
        public init?(hex: String) {
            guard hex.count == Self.byteCount * 2 else { return nil }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(Self.byteCount)
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
                bytes.append(byte)
                index = next
            }
            self.bytes = bytes
        }

        public var hex: String {
            bytes.map { String(format: "%02x", $0) }.joined()
        }

        public var description: String { hex }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let digest = Digest(hex: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "'\(text)' is not a 16-byte hex digest")
            }
            self = digest
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(hex)
        }
    }
}

/// Produces a ``FeaturePrint`` for an image. The live implementation wraps Vision;
/// tests inject a deterministic fake.
public protocol FeaturePrintGenerating: Sendable {
    func featurePrint(for image: CGImage) async throws -> FeaturePrint
}

extension FeaturePrintGenerating {
    /// The print of the procedural ``CalibrationCanvas``, which identifies the
    /// embedding this generator produces: compare it (or its ``FeaturePrint/digest``)
    /// with the one stored in an index or overlay to know whether the two were
    /// computed in the same space.
    public func calibrationPrint() async throws -> FeaturePrint {
        try await featurePrint(for: CalibrationCanvas.render())
    }
}
