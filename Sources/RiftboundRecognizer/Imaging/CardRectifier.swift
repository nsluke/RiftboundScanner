import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// Perspective-corrects a located card onto the canonical canvas.
public struct CardRectifier: Sendable {
    public let renderer: ImageRenderer
    public let canvas: CanvasSpecification

    public init(renderer: ImageRenderer, canvas: CanvasSpecification) {
        self.renderer = renderer
        self.canvas = canvas
    }

    /// Warps the card inside `quad` onto the portrait canvas.
    public func rectify(_ image: CGImage, quad: CardQuad) throws -> CGImage {
        let portrait = quad.portraitOriented()
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = CIImage(cgImage: image)
        filter.topLeft = portrait.topLeft
        filter.topRight = portrait.topRight
        filter.bottomRight = portrait.bottomRight
        filter.bottomLeft = portrait.bottomLeft
        filter.crop = true
        guard let corrected = filter.outputImage else { throw RenderingError.renderingFailed }
        return try renderer.makeCGImage(fitting: corrected, to: canvas.size)
    }

    /// Puts a reference image on the canvas. Landscape cards are turned a quarter
    /// turn clockwise so every index entry is portrait, like the physical card.
    public func canonicalImage(fromReference image: CGImage, orientation: Card.Orientation) throws -> CGImage {
        var reference = CIImage(cgImage: image)
        if orientation == .landscape {
            reference = reference.rotated(quarterTurnsCounterclockwise: 3)
        }
        return try renderer.makeCGImage(fitting: reference, to: canvas.size)
    }
}
