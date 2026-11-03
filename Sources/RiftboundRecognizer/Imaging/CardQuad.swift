import CoreGraphics
import Foundation

/// The four corners of a card in an image, in Core Image coordinates (pixels,
/// origin at the bottom-left). Corners are named by where they appear in the
/// upright image and listed clockwise.
public struct CardQuad: Hashable, Sendable, Codable {
    public let topLeft: CGPoint
    public let topRight: CGPoint
    public let bottomRight: CGPoint
    public let bottomLeft: CGPoint

    public init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    /// The whole image, for inputs that are already cropped to the card.
    public init(fullImageOfSize size: PixelSize) {
        let width = CGFloat(size.width)
        let height = CGFloat(size.height)
        self.init(
            topLeft: CGPoint(x: 0, y: height),
            topRight: CGPoint(x: width, y: height),
            bottomRight: CGPoint(x: width, y: 0),
            bottomLeft: CGPoint(x: 0, y: 0)
        )
    }

    public var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    public var averageWidth: CGFloat {
        (Self.distance(topLeft, topRight) + Self.distance(bottomLeft, bottomRight)) / 2
    }

    public var averageHeight: CGFloat {
        (Self.distance(topLeft, bottomLeft) + Self.distance(topRight, bottomRight)) / 2
    }

    /// `true` when the card's long side runs horizontally in the image.
    public var isSideways: Bool { averageWidth > averageHeight }

    /// Relabels the corners so that perspective correction yields a portrait
    /// canvas. A sideways card is turned a quarter turn; the recogniser tries
    /// both 180° orientations afterwards, so the direction does not matter.
    public func portraitOriented() -> CardQuad {
        guard isSideways else { return self }
        return CardQuad(topLeft: bottomLeft, topRight: topLeft, bottomRight: topRight, bottomLeft: bottomRight)
    }

    /// The card quads consistent with an axis-aligned bounding box of a card.
    ///
    /// A rotated card's bounding box fixes the card's size and how far it is
    /// rotated, but not which way, so two quads come back (one when the box is
    /// not rotated at all). Works for cards lying on their side too. Used with
    /// Vision's objectness saliency, which boxes the card reliably even when the
    /// rectangle detector loses its edges in a cluttered scene.
    public static func fitting(boundingBox box: CGRect, cardAspectRatio: Double = 63.0 / 88.0) -> [CardQuad] {
        guard box.width > 0, box.height > 0 else { return [] }
        let sideways = box.width > box.height
        let ratio = sideways ? cardAspectRatio : 1 / cardAspectRatio   // height over width as the card lies
        let boxRatio = Double(box.height / box.width)
        // For a w × h card turned by θ: W = w cos θ + h sin θ, H = w sin θ + h cos θ,
        // hence tan θ = (H/W − h/w) / (1 − (H/W)(h/w)).
        let tangent = (boxRatio - ratio) / (1 - boxRatio * ratio)
        let theta = tangent.isFinite ? max(0, min(atan(tangent), .pi / 4)) : 0
        let width = Double(box.width) / (cos(theta) + ratio * sin(theta))
        let height = ratio * width
        let center = CGPoint(x: box.midX, y: box.midY)
        let angles = theta < 0.5 * .pi / 180 ? [0.0] : [theta, -theta]
        return angles.map { angle in
            func corner(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: center.x + CGFloat(x * cos(angle) - y * sin(angle)), y: center.y + CGFloat(x * sin(angle) + y * cos(angle)))
            }
            return CardQuad(
                topLeft: corner(-width / 2, height / 2),
                topRight: corner(width / 2, height / 2),
                bottomRight: corner(width / 2, -height / 2),
                bottomLeft: corner(-width / 2, -height / 2)
            )
        }
    }

    /// The axis-aligned box around the corners.
    public var boundingBox: CGRect {
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Moves each corner outwards along its two edges, e.g. from a card's inner
    /// frame to its outer edge. Fractions are of the adjacent edge's length.
    public func expanded(top: CGFloat, bottom: CGFloat, left: CGFloat, right: CGFloat) -> CardQuad {
        func step(_ from: CGPoint, _ to: CGPoint, _ fraction: CGFloat) -> CGPoint {
            CGPoint(x: (to.x - from.x) * fraction, y: (to.y - from.y) * fraction)
        }
        func sum(_ point: CGPoint, _ offsets: CGPoint...) -> CGPoint {
            offsets.reduce(point) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        }
        return CardQuad(
            topLeft: sum(topLeft, step(topRight, topLeft, left), step(bottomLeft, topLeft, top)),
            topRight: sum(topRight, step(topLeft, topRight, right), step(bottomRight, topRight, top)),
            bottomRight: sum(bottomRight, step(bottomLeft, bottomRight, right), step(topRight, bottomRight, bottom)),
            bottomLeft: sum(bottomLeft, step(bottomRight, bottomLeft, left), step(topLeft, bottomLeft, bottom))
        )
    }

    /// The largest distance from each corner to the nearest corner of `other`,
    /// as a fraction of this quad's height. Labelling differences are ignored.
    public func cornerError(comparedTo other: CardQuad) -> CGFloat {
        let worst = corners.map { corner in
            other.corners.map { Self.distance(corner, $0) }.min() ?? .infinity
        }.max() ?? .infinity
        return worst / max(averageHeight, 1)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

/// Where the printed frame sits inside a standard card, as fractions of the
/// card's size. The rectangle detector often finds this frame instead of the
/// black outer edge, and the printed code lies outside it, so the recogniser
/// also tries each detection expanded by these amounts.
public struct CardFrame: Hashable, Sendable, Codable {
    public let topInset: Double
    public let bottomInset: Double
    public let sideInset: Double

    public init(topInset: Double, bottomInset: Double, sideInset: Double) {
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.sideInset = sideInset
    }

    /// Measured on Origins, Radiance and Spiritforged reference images: the
    /// frame's outer edge sits 4.3–5.4 % of the width in from the sides, 2.8–3.8 %
    /// of the height from the top and 5.3–5.9 % from the bottom. Expressed
    /// relative to the frame itself with a little slack; top and bottom share the
    /// larger value because the card may be upside down.
    public static let riftbound = CardFrame(topInset: 0.075, bottomInset: 0.075, sideInset: 0.065)

    /// `quad` grown from the frame to the card edge.
    public func outerQuad(from quad: CardQuad) -> CardQuad {
        quad.expanded(top: topInset, bottom: bottomInset, left: sideInset, right: sideInset)
    }
}
