import CoreGraphics
import Foundation

/// A procedural card-shaped image, drawn the same way on every device, whose
/// feature print fingerprints the embedding a Vision model produces.
///
/// `GenerateImageFeaturePrintRequest.Revision` has one case, so the SDK
/// cannot tell two embeddings apart; a print of a known image can. The canvas
/// is pure geometry (flat fills, one gradient, no text, anti-aliasing off) so
/// that the raster depends on nothing but the drawing code, and it contains
/// no Riot content, so it can live in the repository and on the server.
public enum CalibrationCanvas {
    /// Draws the canvas at `size`; the default is the recogniser's canonical
    /// card canvas, which is what the index and overlays are printed at.
    public static func render(size: PixelSize = CanvasSpecification.standard.size) throws(CalibrationCanvasError) -> CGImage {
        guard size.width > 0, size.height > 0,
              let context = CGContext(
                data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { throw .contextUnavailable }
        context.setShouldAntialias(false)
        context.setAllowsAntialiasing(false)
        context.interpolationQuality = .none

        let width = CGFloat(size.width)
        let height = CGFloat(size.height)
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            // Unit coordinates with a top-left origin, snapped to whole pixels.
            CGRect(x: (x * width).rounded(), y: ((1 - y - h) * height).rounded(), width: (w * width).rounded(), height: (h * height).rounded())
        }
        func fill(_ r: CGRect, _ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) {
            context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
            context.fill(r)
        }
        func ellipse(_ r: CGRect, _ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) {
            context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
            context.fillEllipse(in: r)
        }

        // Border and inner frame.
        fill(CGRect(x: 0, y: 0, width: width, height: height), 0.05, 0.05, 0.06)
        fill(rect(0.045, 0.03, 0.91, 0.925), 0.78, 0.64, 0.30)
        fill(rect(0.06, 0.04, 0.88, 0.905), 0.12, 0.11, 0.14)

        // Illustration: a vertical gradient with a fixed set of shapes over it.
        let art = rect(0.07, 0.06, 0.86, 0.44)
        context.saveGState()
        context.clip(to: art)
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [CGColor(red: 0.10, green: 0.25, blue: 0.55, alpha: 1), CGColor(red: 0.85, green: 0.45, blue: 0.15, alpha: 1)] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(gradient, start: CGPoint(x: art.minX, y: art.maxY), end: CGPoint(x: art.maxX, y: art.minY), options: [])
        }
        var generator = SeededRandomNumberGenerator(seed: 0x5249_4654)   // "RIFT"
        for step in 0..<18 {
            let shape = CGRect(
                x: art.minX + (CGFloat.random(in: -0.15...0.85, using: &generator) * art.width).rounded(),
                y: art.minY + (CGFloat.random(in: -0.15...0.85, using: &generator) * art.height).rounded(),
                width: (CGFloat.random(in: 0.08...0.45, using: &generator) * art.width).rounded(),
                height: (CGFloat.random(in: 0.08...0.45, using: &generator) * art.height).rounded()
            )
            let red = CGFloat.random(in: 0...1, using: &generator)
            let green = CGFloat.random(in: 0...1, using: &generator)
            let blue = CGFloat.random(in: 0...1, using: &generator)
            if step % 3 == 0 {
                ellipse(shape, red, green, blue)
            } else {
                fill(shape, red, green, blue)
            }
        }
        context.restoreGState()

        // Name bar, then a text box with ruled "lines" and a checkerboard badge.
        fill(rect(0.07, 0.51, 0.86, 0.07), 0.55, 0.12, 0.16)
        fill(rect(0.09, 0.525, 0.5, 0.04), 0.92, 0.88, 0.80)
        let textBox = rect(0.07, 0.59, 0.86, 0.33)
        fill(textBox, 0.95, 0.94, 0.90)
        for line in 0..<9 {
            let y = 0.61 + CGFloat(line) * 0.034
            let length: CGFloat = [0.78, 0.62, 0.71, 0.45, 0.80, 0.58, 0.69, 0.33, 0.74][line]
            fill(rect(0.095, y, length, 0.012), 0.20, 0.20, 0.24)
        }
        for row in 0..<6 {
            for column in 0..<6 where (row + column) % 2 == 0 {
                fill(rect(0.70 + CGFloat(column) * 0.035, 0.76 + CGFloat(row) * 0.025, 0.035, 0.025), 0.10, 0.10, 0.10)
            }
        }
        // Bottom band: the stand-in for the printed code, as blocks rather than glyphs.
        for (column, tall) in [true, false, true, true, false, true, false, false, true, true].enumerated() {
            fill(rect(0.07 + CGFloat(column) * 0.028, tall ? 0.955 : 0.962, 0.018, tall ? 0.025 : 0.018), 0.88, 0.88, 0.88)
        }

        guard let image = context.makeImage() else { throw .renderingFailed }
        return image
    }
}

/// The calibration canvas could not be drawn.
public enum CalibrationCanvasError: Error {
    case contextUnavailable
    case renderingFailed
}
