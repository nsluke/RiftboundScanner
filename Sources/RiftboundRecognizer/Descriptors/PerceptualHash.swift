import CoreGraphics
import Foundation

/// An 8-bit grayscale bitmap, row-major with the top row first.
public struct GrayscaleBitmap: Hashable, Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height, "pixel count must match the bitmap size")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Renders `image` into a `width` × `height` bitmap with Core Graphics' high-quality resampling.
    public init(rendering image: CGImage, width: Int, height: Int) throws(HashingError) {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                    data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
                  )
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw .renderingFailed }
        self.init(width: width, height: height, pixels: pixels)
    }

    public func pixel(x: Int, y: Int) -> UInt8 {
        pixels[y * width + x]
    }

    /// Averages blocks of pixels. The new size must divide the current one exactly.
    public func boxDownsampled(toWidth newWidth: Int, height newHeight: Int) -> GrayscaleBitmap {
        precondition(width % newWidth == 0 && height % newHeight == 0, "box downsampling needs integer factors")
        let factorX = width / newWidth
        let factorY = height / newHeight
        let area = factorX * factorY
        var output = [UInt8](repeating: 0, count: newWidth * newHeight)
        for y in 0..<newHeight {
            for x in 0..<newWidth {
                var sum = 0
                for row in 0..<factorY {
                    let rowStart = (y * factorY + row) * width + x * factorX
                    for column in 0..<factorX {
                        sum += Int(pixels[rowStart + column])
                    }
                }
                output[y * newWidth + x] = UInt8(sum / area)
            }
        }
        return GrayscaleBitmap(width: newWidth, height: newHeight, pixels: output)
    }
}

/// Core Graphics could not render the bitmap a hash is computed from.
public enum HashingError: Error {
    case renderingFailed
}

/// A 64-bit perceptual hash. ``distance(to:)`` is the Hamming distance: 0 for
/// identical images, around 32 for unrelated ones.
public struct ImageHash: Hashable, Sendable, Codable {
    public let bits: UInt64

    public init(bits: UInt64) {
        self.bits = bits
    }

    public func distance(to other: ImageHash) -> Int {
        (bits ^ other.bits).nonzeroBitCount
    }

    /// 1 for identical hashes, 0 for fully opposite ones.
    public func similarity(to other: ImageHash) -> Double {
        1 - Double(distance(to: other)) / 64
    }
}

/// dHash and pHash over a shared working bitmap.
public enum PerceptualHashing {
    /// 288 × 256 divides exactly into the 9 × 8 dHash grid and the 32 × 32 pHash grid.
    public static let workingWidth = 288
    public static let workingHeight = 256

    public static func workingBitmap(for image: CGImage) throws(HashingError) -> GrayscaleBitmap {
        try GrayscaleBitmap(rendering: image, width: workingWidth, height: workingHeight)
    }

    /// Difference hash: each bit records whether a cell of a 9 × 8 grid is brighter
    /// than its right-hand neighbour. Robust to global lighting changes.
    public static func differenceHash(of bitmap: GrayscaleBitmap) -> ImageHash {
        let grid = bitmap.boxDownsampled(toWidth: 9, height: 8)
        var bits: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 {
                bits <<= 1
                if grid.pixel(x: x, y: y) > grid.pixel(x: x + 1, y: y) {
                    bits |= 1
                }
            }
        }
        return ImageHash(bits: bits)
    }

    /// Perceptual hash: the 8 × 8 low-frequency block of a 32 × 32 DCT, thresholded
    /// at the median of its AC terms. Robust to blur and small shifts.
    public static func perceptualHash(of bitmap: GrayscaleBitmap) -> ImageHash {
        let grid = bitmap.boxDownsampled(toWidth: 32, height: 32)
        let n = 32
        let kept = 8
        var cosines = [Double](repeating: 0, count: kept * n)
        for u in 0..<kept {
            for x in 0..<n {
                cosines[u * n + x] = cos(Double(2 * x + 1) * Double(u) * .pi / Double(2 * n))
            }
        }
        // Separable DCT-II, computing only the `kept` × `kept` low-frequency block.
        var rows = [Double](repeating: 0, count: kept * n)
        for u in 0..<kept {
            for y in 0..<n {
                var sum = 0.0
                for x in 0..<n {
                    sum += Double(grid.pixel(x: x, y: y)) * cosines[u * n + x]
                }
                rows[u * n + y] = sum
            }
        }
        var coefficients = [Double](repeating: 0, count: kept * kept)
        for u in 0..<kept {
            for v in 0..<kept {
                var sum = 0.0
                for y in 0..<n {
                    sum += rows[u * n + y] * cosines[v * n + y]
                }
                coefficients[u * kept + v] = sum
            }
        }
        let alternating = coefficients.dropFirst().sorted()
        let median = alternating[alternating.count / 2]
        var bits: UInt64 = 0
        for coefficient in coefficients {
            bits <<= 1
            if coefficient > median {
                bits |= 1
            }
        }
        return ImageHash(bits: bits)
    }
}
