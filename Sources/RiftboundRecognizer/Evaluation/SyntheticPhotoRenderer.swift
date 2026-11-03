import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// How hard a synthetic photo is.
public enum Severity: String, Hashable, Sendable, Codable, CaseIterable {
    case mild, moderate, harsh
}

/// Everything that determines one synthetic photo, so a manifest can reproduce it.
public struct SyntheticPhotoParameters: Hashable, Sendable, Codable {
    public var severity: Severity
    public var photoSize: PixelSize
    /// Card height as a fraction of the photo height (before fitting it inside the frame).
    public var cardHeightFraction: Double
    /// Where the card sits, as a fraction of the room left after margins.
    public var centerX: Double
    public var centerY: Double
    public var rotationDegrees: Double
    /// Turned 180°: the card goes through a feeder either way up.
    public var flipped: Bool
    /// The card lies on its side in the frame.
    public var sideways: Bool
    /// Eight values in -1...1: per-corner perspective jitter.
    public var cornerJitter: [Double]
    public var jitterFraction: Double
    public var brightness: Double
    public var contrast: Double
    public var saturation: Double
    public var exposure: Double
    public var temperature: Double
    public var shadeDirectionDegrees: Double
    public var shadeStrength: Double
    public var blurRadius: Double
    public var noiseAmplitude: Double
    public var vignette: Double
    public var glareX: Double
    public var glareY: Double
    public var glareRadius: Double
    public var glareStrength: Double
    public var jpegQuality: Double
    public var backgroundSeed: UInt64
    /// Random shapes drawn behind the card; 0 gives a plain background.
    public var clutterShapeCount: Int

    public static func random(severity: Severity, using generator: inout some RandomNumberGenerator) -> SyntheticPhotoParameters {
        func pick(_ mild: ClosedRange<Double>, _ moderate: ClosedRange<Double>, _ harsh: ClosedRange<Double>) -> Double {
            let range = switch severity {
            case .mild: mild
            case .moderate: moderate
            case .harsh: harsh
            }
            return Double.random(in: range, using: &generator)
        }
        func chance(_ mild: Double, _ moderate: Double, _ harsh: Double) -> Bool {
            let probability = switch severity {
            case .mild: mild
            case .moderate: moderate
            case .harsh: harsh
            }
            return Double.random(in: 0..<1, using: &generator) < probability
        }
        return SyntheticPhotoParameters(
            severity: severity,
            photoSize: PixelSize(width: 1536, height: 2048),
            cardHeightFraction: pick(0.55...0.75, 0.4...0.75, 0.3...0.7),
            centerX: Double.random(in: 0...1, using: &generator),
            centerY: Double.random(in: 0...1, using: &generator),
            rotationDegrees: pick(-8...8, -20...20, -35...35),
            flipped: chance(0.3, 0.5, 0.5),
            sideways: chance(0, 0.1, 0.2),
            cornerJitter: (0..<8).map { _ in Double.random(in: -1...1, using: &generator) },
            jitterFraction: pick(0.0...0.02, 0.02...0.06, 0.05...0.11),
            brightness: pick(-0.05...0.05, -0.12...0.12, -0.2...0.2),
            contrast: pick(0.95...1.05, 0.85...1.2, 0.7...1.35),
            saturation: pick(0.9...1.1, 0.7...1.2, 0.5...1.3),
            exposure: pick(-0.2...0.2, -0.5...0.5, -0.9...0.9),
            temperature: pick(5500...7000, 4000...8000, 3000...9000),
            shadeDirectionDegrees: Double.random(in: 0..<360, using: &generator),
            shadeStrength: pick(0...0.15, 0.1...0.35, 0.25...0.55),
            blurRadius: pick(0...0.6, 0.5...1.8, 1.5...3.5),
            noiseAmplitude: pick(0...0.02, 0.01...0.05, 0.03...0.09),
            vignette: pick(0...0.3, 0.2...0.7, 0.4...1.0),
            glareX: Double.random(in: 0.2...0.8, using: &generator),
            glareY: Double.random(in: 0.2...0.8, using: &generator),
            glareRadius: pick(0.1...0.2, 0.1...0.3, 0.15...0.4),
            glareStrength: pick(0...0, 0...0.35, 0.2...0.6),
            jpegQuality: pick(0.85...0.95, 0.65...0.9, 0.4...0.75),
            backgroundSeed: generator.next(),
            clutterShapeCount: Int.random(in: 6...16, using: &generator)
        )
    }
}

public struct SyntheticPhoto: Sendable {
    public let image: CGImage
    /// Where the card's corners landed, in Core Image coordinates of the photo.
    public let quad: CardQuad
    public let parameters: SyntheticPhotoParameters
}

/// Renders a reference card into a fake photograph: cluttered background,
/// perspective, uneven lighting, colour cast, glare, blur, noise and vignette.
/// JPEG compression is applied by whoever writes the file, using
/// ``SyntheticPhotoParameters/jpegQuality``.
public struct SyntheticPhotoRenderer: Sendable {
    private let renderer: ImageRenderer

    public init(renderer: ImageRenderer) {
        self.renderer = renderer
    }

    public func render(card: CGImage, parameters: SyntheticPhotoParameters) throws -> SyntheticPhoto {
        let size = parameters.photoSize
        let photoRect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        var backgroundGenerator = SeededRandomNumberGenerator(seed: parameters.backgroundSeed)
        let background = CIImage(cgImage: try Self.background(size: size, shapes: parameters.clutterShapeCount, using: &backgroundGenerator))
        let quad = Self.placement(cardSize: PixelSize(width: card.width, height: card.height), in: parameters)

        let warp = CIFilter.perspectiveTransform()
        warp.inputImage = CIImage(cgImage: card)
        warp.topLeft = quad.topLeft
        warp.topRight = quad.topRight
        warp.bottomRight = quad.bottomRight
        warp.bottomLeft = quad.bottomLeft
        let composite = CIFilter.sourceOverCompositing()
        composite.inputImage = try Self.output(of: warp)
        composite.backgroundImage = background
        var image = try Self.output(of: composite).cropped(to: photoRect)

        // Uneven lighting: multiply by a linear gradient across the frame.
        if parameters.shadeStrength > 0 {
            let angle = parameters.shadeDirectionDegrees * .pi / 180
            let center = CGPoint(x: photoRect.midX, y: photoRect.midY)
            let reach = hypot(photoRect.width, photoRect.height) / 2
            let gradient = CIFilter.linearGradient()
            gradient.point0 = CGPoint(x: center.x - cos(angle) * reach, y: center.y - sin(angle) * reach)
            gradient.point1 = CGPoint(x: center.x + cos(angle) * reach, y: center.y + sin(angle) * reach)
            gradient.color0 = CIColor(red: 1, green: 1, blue: 1)
            let dim = CGFloat(1 - parameters.shadeStrength)
            gradient.color1 = CIColor(red: dim, green: dim, blue: dim)
            let multiply = CIFilter.multiplyCompositing()
            multiply.inputImage = try Self.output(of: gradient).cropped(to: photoRect)
            multiply.backgroundImage = image
            image = try Self.output(of: multiply)
        }

        let colour = CIFilter.colorControls()
        colour.inputImage = image
        colour.brightness = Float(parameters.brightness)
        colour.contrast = Float(parameters.contrast)
        colour.saturation = Float(parameters.saturation)
        image = try Self.output(of: colour)

        let tint = CIFilter.temperatureAndTint()
        tint.inputImage = image
        tint.neutral = CIVector(x: 6500, y: 0)
        tint.targetNeutral = CIVector(x: CGFloat(parameters.temperature), y: 0)
        image = try Self.output(of: tint)

        let exposure = CIFilter.exposureAdjust()
        exposure.inputImage = image
        exposure.ev = Float(parameters.exposure)
        image = try Self.output(of: exposure)

        if parameters.glareStrength > 0 {
            let glare = CIFilter.radialGradient()
            glare.center = CGPoint(x: parameters.glareX * photoRect.width, y: parameters.glareY * photoRect.height)
            glare.radius0 = 0
            glare.radius1 = Float(parameters.glareRadius * photoRect.height)
            glare.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: CGFloat(parameters.glareStrength))
            glare.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
            let over = CIFilter.sourceOverCompositing()
            over.inputImage = try Self.output(of: glare).cropped(to: photoRect)
            over.backgroundImage = image
            image = try Self.output(of: over)
        }

        if parameters.blurRadius > 0 {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = image.clampedToExtent()
            blur.radius = Float(parameters.blurRadius)
            image = try Self.output(of: blur).cropped(to: photoRect)
        }

        if parameters.noiseAmplitude > 0 {
            var noiseGenerator = SeededRandomNumberGenerator(seed: parameters.backgroundSeed ^ 0x5DEE_CE66_D1CE_4E5B)
            let noise = try GrayscaleBitmap.noise(width: size.width / 2, height: size.height / 2, using: &noiseGenerator).makeCGImage()
            let amplitude = CGFloat(parameters.noiseAmplitude)
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = CIImage(cgImage: noise).transformed(by: CGAffineTransform(scaleX: 2, y: 2))
            matrix.rVector = CIVector(x: amplitude, y: 0, z: 0, w: 0)
            matrix.gVector = CIVector(x: 0, y: amplitude, z: 0, w: 0)
            matrix.bVector = CIVector(x: 0, y: 0, z: amplitude, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            matrix.biasVector = CIVector(x: -amplitude / 2, y: -amplitude / 2, z: -amplitude / 2, w: 0)
            let add = CIFilter.additionCompositing()
            add.inputImage = try Self.output(of: matrix).cropped(to: photoRect)
            add.backgroundImage = image
            image = try Self.output(of: add)
        }

        if parameters.vignette > 0 {
            let vignette = CIFilter.vignette()
            vignette.inputImage = image
            vignette.intensity = Float(parameters.vignette)
            vignette.radius = 1.5
            image = try Self.output(of: vignette)
        }

        let rendered = try renderer.makeCGImage(image, in: photoRect)
        return SyntheticPhoto(image: rendered, quad: quad, parameters: parameters)
    }

    // MARK: - Geometry

    /// Places the card: scaled by `cardHeightFraction`, rotated, shrunk if needed to
    /// stay inside the frame with a margin, positioned by `centerX/Y`, then jittered.
    static func placement(cardSize: PixelSize, in parameters: SyntheticPhotoParameters) -> CardQuad {
        let photoWidth = Double(parameters.photoSize.width)
        let photoHeight = Double(parameters.photoSize.height)
        var cardHeight = parameters.cardHeightFraction * photoHeight
        let cardWidth = cardHeight * Double(cardSize.width) / Double(cardSize.height)
        let degrees = parameters.rotationDegrees + (parameters.flipped ? 180 : 0) + (parameters.sideways ? 90 : 0)
        let angle = degrees * .pi / 180
        let (sine, cosine) = (sin(angle), cos(angle))
        var local: [(x: Double, y: Double)] = [
            (-cardWidth / 2, cardHeight / 2), (cardWidth / 2, cardHeight / 2),
            (cardWidth / 2, -cardHeight / 2), (-cardWidth / 2, -cardHeight / 2),
        ].map { point in (point.0 * cosine - point.1 * sine, point.0 * sine + point.1 * cosine) }

        let margin = 0.1 * min(photoWidth, photoHeight)
        func bounds() -> (minX: Double, maxX: Double, minY: Double, maxY: Double) {
            (local.map(\.x).min() ?? 0, local.map(\.x).max() ?? 0, local.map(\.y).min() ?? 0, local.map(\.y).max() ?? 0)
        }
        var box = bounds()
        let scale = min(1, (photoWidth - 2 * margin) / (box.maxX - box.minX), (photoHeight - 2 * margin) / (box.maxY - box.minY))
        if scale < 1 {
            local = local.map { ($0.x * scale, $0.y * scale) }
            cardHeight *= scale
            box = bounds()
        }
        let lowX = margin - box.minX
        let highX = photoWidth - margin - box.maxX
        let lowY = margin - box.minY
        let highY = photoHeight - margin - box.maxY
        let centerX = lowX + parameters.centerX * max(0, highX - lowX)
        let centerY = lowY + parameters.centerY * max(0, highY - lowY)
        let jitter = parameters.jitterFraction * cardHeight
        let jitters = parameters.cornerJitter + [Double](repeating: 0, count: max(0, 8 - parameters.cornerJitter.count))
        let corners = local.enumerated().map { index, point in
            CGPoint(x: centerX + point.x + jitters[2 * index] * jitter, y: centerY + point.y + jitters[2 * index + 1] * jitter)
        }
        return CardQuad(topLeft: corners[0], topRight: corners[1], bottomRight: corners[2], bottomLeft: corners[3])
    }

    // MARK: - Background

    /// A flat colour with random shapes: tabletop, mat, stray objects.
    static func background(size: PixelSize, shapes: Int, using generator: inout some RandomNumberGenerator) throws -> CGImage {
        guard let context = CGContext(
            data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw RenderingError.renderingFailed }
        let frame = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        context.setFillColor(randomColor(brightness: 0.15...0.9, alpha: 1...1, using: &generator))
        context.fill(frame)
        for _ in 0..<max(0, shapes) {
            let width = Double.random(in: 0.08...0.6, using: &generator) * frame.width
            let height = Double.random(in: 0.08...0.6, using: &generator) * frame.height
            let origin = CGPoint(
                x: Double.random(in: -0.3...1.0, using: &generator) * frame.width,
                y: Double.random(in: -0.3...1.0, using: &generator) * frame.height
            )
            let rect = CGRect(origin: origin, size: CGSize(width: width, height: height))
            context.setFillColor(randomColor(brightness: 0.05...1, alpha: 0.4...1, using: &generator))
            if Bool.random(using: &generator) {
                context.fillEllipse(in: rect)
            } else {
                context.fill(rect)
            }
        }
        guard let image = context.makeImage() else { throw RenderingError.renderingFailed }
        return image
    }

    private static func randomColor(brightness: ClosedRange<Double>, alpha: ClosedRange<Double>, using generator: inout some RandomNumberGenerator) -> CGColor {
        let level = Double.random(in: brightness, using: &generator)
        let tintStrength = Double.random(in: 0...0.5, using: &generator)
        func channel() -> CGFloat {
            CGFloat(min(1, max(0, level + Double.random(in: -tintStrength...tintStrength, using: &generator))))
        }
        return CGColor(red: channel(), green: channel(), blue: channel(), alpha: CGFloat(Double.random(in: alpha, using: &generator)))
    }

    private static func output(of filter: CIFilter) throws -> CIImage {
        guard let image = filter.outputImage else { throw RenderingError.renderingFailed }
        return image
    }
}

extension GrayscaleBitmap {
    /// Uniform random noise.
    public static func noise(width: Int, height: Int, using generator: inout some RandomNumberGenerator) -> GrayscaleBitmap {
        var pixels = [UInt8](repeating: 0, count: width * height)
        var index = 0
        while index < pixels.count {
            var word = generator.next()
            for _ in 0..<8 where index < pixels.count {
                pixels[index] = UInt8(truncatingIfNeeded: word)
                word >>= 8
                index += 1
            }
        }
        return GrayscaleBitmap(width: width, height: height, pixels: pixels)
    }

    /// A device-gray `CGImage` of the bitmap.
    public func makeCGImage() throws(HashingError) -> CGImage {
        var copy = pixels
        let image = copy.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                    data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
                  )
            else { return nil }
            return context.makeImage()
        }
        guard let image else { throw .renderingFailed }
        return image
    }
}
