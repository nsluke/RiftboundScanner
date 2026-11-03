import CoreGraphics
import CoreText
import Foundation
import RiftboundRecognizer

/// Procedurally drawn stand-ins for card images, so the pipeline is tested
/// without any Riot assets.
enum TestImages {
    static let portraitSize = PixelSize(width: 378, height: 528)
    static let landscapeSize = PixelSize(width: 528, height: 378)

    /// A card-like image: dark border, a seeded abstract illustration, a name
    /// bar, a pale text box and `code` printed small at the bottom-left, like a
    /// real card. Everything scales with `size`, so the same seed at two sizes
    /// depicts the same card.
    static func card(seed: UInt64, code: String?, size: PixelSize = portraitSize) -> CGImage {
        var generator = SeededRandomNumberGenerator(seed: seed)
        let width = CGFloat(size.width)
        let height = CGFloat(size.height)
        let context = makeContext(size)
        context.setFillColor(CGColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let border = min(width, height) * 0.045
        let inner = CGRect(x: border, y: border * 1.7, width: width - 2 * border, height: height - border * 2.7)
        let artHeight = inner.height * (size.width < size.height ? 0.5 : 0.62)
        let art = CGRect(x: inner.minX, y: inner.maxY - artHeight, width: inner.width, height: artHeight)
        context.setFillColor(randomColor(&generator))
        context.fill(art)
        context.saveGState()
        context.clip(to: art)
        for _ in 0..<14 {
            let rect = CGRect(
                x: art.minX + CGFloat.random(in: -0.2...0.9, using: &generator) * art.width,
                y: art.minY + CGFloat.random(in: -0.2...0.9, using: &generator) * art.height,
                width: CGFloat.random(in: 0.1...0.5, using: &generator) * art.width,
                height: CGFloat.random(in: 0.1...0.5, using: &generator) * art.height
            )
            context.setFillColor(randomColor(&generator))
            if Bool.random(using: &generator) {
                context.fillEllipse(in: rect)
            } else {
                context.fill(rect)
            }
        }
        context.restoreGState()

        let nameBar = CGRect(x: inner.minX, y: art.minY - inner.height * 0.1, width: inner.width, height: inner.height * 0.1)
        context.setFillColor(randomColor(&generator))
        context.fill(nameBar)
        let textBox = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: nameBar.minY - inner.minY)
        context.setFillColor(CGColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1))
        context.fill(textBox)

        if let code {
            drawText(code, at: CGPoint(x: border, y: border * 0.45), pointSize: min(width, height) * 0.03,
                     color: CGColor(red: 1, green: 1, blue: 1, alpha: 1), in: context)
        }
        return makeImage(context)
    }

    /// A black image with one red pixel at the top-left, for rotation tests.
    static func marker(width: Int, height: Int) -> CGImage {
        let context = makeContext(PixelSize(width: width, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: height - 1, width: 1, height: 1))
        return makeImage(context)
    }

    /// Draws `card` onto a flat background at `rect` (pixel coordinates with a
    /// top-left origin), returning the photo and the card's quad in Core Image
    /// coordinates.
    static func photo(of card: CGImage, at rect: CGRect, canvas size: PixelSize) -> (CGImage, CardQuad) {
        let context = makeContext(size)
        context.setFillColor(CGColor(red: 0.35, green: 0.4, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        let flipped = CGRect(x: rect.minX, y: CGFloat(size.height) - rect.maxY, width: rect.width, height: rect.height)
        context.draw(card, in: flipped)
        let quad = CardQuad(
            topLeft: CGPoint(x: flipped.minX, y: flipped.maxY),
            topRight: CGPoint(x: flipped.maxX, y: flipped.maxY),
            bottomRight: CGPoint(x: flipped.maxX, y: flipped.minY),
            bottomLeft: CGPoint(x: flipped.minX, y: flipped.minY)
        )
        return (makeImage(context), quad)
    }

    /// The red, green and blue bytes at (`x`, `y`) counted from the top-left.
    static func rgb(of image: CGImage, x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8) {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                    data: base, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { fatalError("could not create a bitmap context") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let offset = (y * image.width + x) * 4
        return (pixels[offset], pixels[offset + 1], pixels[offset + 2])
    }

    static func makeContext(_ size: PixelSize) -> CGContext {
        guard let context = CGContext(
            data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { fatalError("could not create a bitmap context") }
        return context
    }

    static func makeImage(_ context: CGContext) -> CGImage {
        guard let image = context.makeImage() else { fatalError("could not render the test image") }
        return image
    }

    private static func randomColor(_ generator: inout SeededRandomNumberGenerator) -> CGColor {
        CGColor(
            red: CGFloat.random(in: 0...1, using: &generator),
            green: CGFloat.random(in: 0...1, using: &generator),
            blue: CGFloat.random(in: 0...1, using: &generator),
            alpha: 1
        )
    }

    private static func drawText(_ text: String, at origin: CGPoint, pointSize: CGFloat, color: CGColor, in context: CGContext) {
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, pointSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = origin
        CTLineDraw(line, context)
    }
}
