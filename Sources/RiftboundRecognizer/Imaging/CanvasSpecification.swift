import CoreGraphics

/// A size in pixels.
public struct PixelSize: Hashable, Sendable, Codable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var cgSize: CGSize { CGSize(width: width, height: height) }
}

/// A rectangle in unit coordinates of an image, with the origin at the top-left.
public struct UnitRect: Hashable, Sendable, Codable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The rectangle in pixel coordinates (top-left origin, as `CGImage.cropping(to:)` expects).
    public func pixelRect(in size: PixelSize) -> CGRect {
        CGRect(
            x: (x * Double(size.width)).rounded(),
            y: (y * Double(size.height)).rounded(),
            width: (width * Double(size.width)).rounded(),
            height: (height * Double(size.height)).rounded()
        )
    }
}

/// The fixed portrait canvas every card is rectified onto before hashing, OCR
/// and indexing. Reference images and photos go through the same canvas, so
/// descriptors are comparable.
public struct CanvasSpecification: Hashable, Sendable, Codable {
    /// Canvas size in pixels; 756 × 1056 is exactly 63 : 88 (12 px per millimetre).
    public let size: PixelSize
    /// Where the illustration sits on a standard portrait card (top-left origin).
    public let artRegion: UnitRect
    /// Thickness of the band along each edge that may contain the printed code,
    /// as a fraction of the canvas's corresponding dimension.
    public let codeBandFraction: Double

    public init(size: PixelSize, artRegion: UnitRect, codeBandFraction: Double) {
        self.size = size
        self.artRegion = artRegion
        self.codeBandFraction = codeBandFraction
    }

    public static let standard = CanvasSpecification(
        size: PixelSize(width: 756, height: 1056),
        artRegion: UnitRect(x: 0.07, y: 0.06, width: 0.86, height: 0.44),
        codeBandFraction: 0.09
    )
}
