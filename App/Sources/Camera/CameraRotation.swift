import CoreGraphics
import ImageIO

/// A quarter-turn applied to a camera's picture, so a card the iPhone sees
/// sideways on the stand reads upright on the Mac.
///
/// The preview and the photo are turned by the same amount: the preview by
/// rotating its layer, the photo by rewriting its EXIF orientation. The guide
/// crop then maps preview points to photo pixels exactly as on the iPhone.
/// AVFoundation's own connection rotation is not used, because whether a
/// Continuity Camera connection supports it is not documented per device.
nonisolated enum CameraRotation: Int, Hashable, Sendable, Codable, CaseIterable {
    case none = 0
    case clockwise90 = 90
    case clockwise180 = 180
    case clockwise270 = 270

    var degrees: Int { rawValue }

    /// The next quarter-turn clockwise, wrapping after three.
    var turnedClockwise: CameraRotation {
        CameraRotation(rawValue: (rawValue + 90) % 360) ?? .none
    }

    /// A quarter or three-quarter turn swaps the picture's width and height.
    var swapsAxes: Bool {
        self == .clockwise90 || self == .clockwise270
    }

    /// The size of a `width` × `height` picture once turned.
    func turning(_ size: CGSize) -> CGSize {
        swapsAxes ? CGSize(width: size.height, height: size.width) : size
    }

    /// The EXIF orientation that shows a photo stored with `orientation`
    /// turned clockwise by this rotation.
    func applied(to orientation: CGImagePropertyOrientation) -> CGImagePropertyOrientation {
        var display = DisplayTransform(orientation)
        for _ in 0..<(rawValue / 90) {
            display = .clockwiseQuarterTurn * display
        }
        return Self.orientations.first { DisplayTransform($0) == display } ?? orientation
    }

    private static let orientations: [CGImagePropertyOrientation] = [
        .up, .upMirrored, .down, .downMirrored, .leftMirrored, .right, .rightMirrored, .left,
    ]
}

/// How an EXIF orientation carries stored pixels onto the screen, as a 2 × 2
/// integer matrix on (x, y) with y pointing down. Composing two transforms is
/// a matrix product, which is how `CameraRotation.applied(to:)` finds the
/// orientation of a photo turned once more.
nonisolated private struct DisplayTransform: Equatable {
    let a: Int, b: Int, c: Int, d: Int

    /// (x, y) → (−y, x): rightwards becomes downwards.
    static let clockwiseQuarterTurn = DisplayTransform(a: 0, b: -1, c: 1, d: 0)

    init(a: Int, b: Int, c: Int, d: Int) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
    }

    init(_ orientation: CGImagePropertyOrientation) {
        switch orientation {
        case .up: self.init(a: 1, b: 0, c: 0, d: 1)
        case .upMirrored: self.init(a: -1, b: 0, c: 0, d: 1)
        case .down: self.init(a: -1, b: 0, c: 0, d: -1)
        case .downMirrored: self.init(a: 1, b: 0, c: 0, d: -1)
        case .leftMirrored: self.init(a: 0, b: 1, c: 1, d: 0)
        case .right: self.init(a: 0, b: -1, c: 1, d: 0)
        case .rightMirrored: self.init(a: 0, b: -1, c: -1, d: 0)
        case .left: self.init(a: 0, b: 1, c: -1, d: 0)
        }
    }

    static func * (lhs: DisplayTransform, rhs: DisplayTransform) -> DisplayTransform {
        DisplayTransform(
            a: lhs.a * rhs.a + lhs.b * rhs.c,
            b: lhs.a * rhs.b + lhs.b * rhs.d,
            c: lhs.c * rhs.a + lhs.d * rhs.c,
            d: lhs.c * rhs.b + lhs.d * rhs.d
        )
    }
}
