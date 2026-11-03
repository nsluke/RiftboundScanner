import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// Renders Core Image graphs into bitmaps.
///
/// Holds the process's `CIContext`, which is expensive to create and safe to
/// share between threads; create one in the composition root and inject it.
public struct ImageRenderer: Sendable {
    private let context: CIContext

    public init(context: CIContext = CIContext(options: [.cacheIntermediates: false])) {
        self.context = context
    }

    /// Renders `image`, or the part of it inside `rect`, into a bitmap.
    public func makeCGImage(_ image: CIImage, in rect: CGRect? = nil) throws(RenderingError) -> CGImage {
        let target = (rect ?? image.extent).integral
        guard !target.isEmpty, !target.isInfinite, let rendered = context.createCGImage(image, from: target) else {
            throw .renderingFailed
        }
        return rendered
    }

    /// Resamples `image` with a Lanczos filter so it exactly fills `size`, then renders it.
    public func makeCGImage(fitting image: CIImage, to size: PixelSize) throws(RenderingError) -> CGImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, !extent.isInfinite else { throw .emptyImage }
        let scaleY = CGFloat(size.height) / extent.height
        let scaleX = CGFloat(size.width) / extent.width
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = image.movedToOrigin()
        filter.scale = Float(scaleY)
        filter.aspectRatio = Float(scaleX / scaleY)
        guard let scaled = filter.outputImage else { throw .renderingFailed }
        return try makeCGImage(scaled, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
    }

    /// Rotates by quarter turns counter-clockwise.
    public func rotated(_ image: CGImage, quarterTurnsCounterclockwise turns: Int) throws(RenderingError) -> CGImage {
        try makeCGImage(CIImage(cgImage: image).rotated(quarterTurnsCounterclockwise: turns))
    }
}

/// Core Image could not produce a bitmap.
public enum RenderingError: Error {
    case renderingFailed
    case emptyImage
}

extension CIImage {
    /// Rotates by `turns` quarter turns counter-clockwise (in Core Image's y-up
    /// coordinates) using exact matrices, then moves the result back to the origin.
    public func rotated(quarterTurnsCounterclockwise turns: Int) -> CIImage {
        let normalized = ((turns % 4) + 4) % 4
        let transform: CGAffineTransform = switch normalized {
        case 1: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
        case 2: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        case 3: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)
        default: .identity
        }
        guard normalized != 0 else { return self }
        return transformed(by: transform).movedToOrigin()
    }

    /// Translates so the extent's origin is (0, 0), rounding away floating-point drift.
    public func movedToOrigin() -> CIImage {
        let origin = extent.origin
        guard origin != .zero else { return self }
        return transformed(by: CGAffineTransform(translationX: -origin.x.rounded(), y: -origin.y.rounded()))
    }
}
