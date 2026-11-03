import Accelerate
import CoreGraphics
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
        var data = Data(capacity: elements.count * 4)
        for element in elements {
            var bits = element.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        var container = encoder.singleValueContainer()
        try container.encode(data)
    }
}

/// Produces a ``FeaturePrint`` for an image. The live implementation wraps Vision;
/// tests inject a deterministic fake.
public protocol FeaturePrintGenerating: Sendable {
    func featurePrint(for image: CGImage) async throws -> FeaturePrint
}
