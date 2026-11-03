import CoreGraphics
import CoreImage

/// A printed code read from the rectified card, with where it was found.
public struct CodeReading: Hashable, Sendable {
    public let code: PrintedCode
    public let confidence: Double
    /// The canvas rotation that made the code upright, i.e. how the card sits
    /// relative to the index's canonical view.
    public let orientation: CardOrientation
    /// Whether the code was found along a short edge (portrait card) or a long one (landscape card).
    public let layout: Card.Orientation
    public let text: String

    public init(code: PrintedCode, confidence: Double, orientation: CardOrientation, layout: Card.Orientation, text: String) {
        self.code = code
        self.confidence = confidence
        self.orientation = orientation
        self.layout = layout
        self.text = text
    }
}

/// The four bands of the canvas that can hold the printed code.
///
/// Portrait cards print it along the bottom edge; a landscape card that was
/// turned clockwise onto the canvas has it along the left edge, reading
/// upwards. Each case knows the quarter turns that make its text upright.
enum CodeStrip: CaseIterable, Sendable {
    case bottom, top, left, right

    var orientation: CardOrientation {
        switch self {
        case .bottom, .left: .upright
        case .top, .right: .upsideDown
        }
    }

    var layout: Card.Orientation {
        switch self {
        case .bottom, .top: .portrait
        case .left, .right: .landscape
        }
    }

    var quarterTurnsCounterclockwise: Int {
        switch self {
        case .bottom: 0
        case .top: 2
        case .left: 1
        case .right: 3
        }
    }

    /// The band in Core Image coordinates (origin bottom-left).
    func rect(in size: PixelSize, bandFraction: Double) -> CGRect {
        let width = CGFloat(size.width)
        let height = CGFloat(size.height)
        let bandHeight = (height * bandFraction).rounded()
        let bandWidth = (width * bandFraction).rounded()
        return switch self {
        case .bottom: CGRect(x: 0, y: 0, width: width, height: bandHeight)
        case .top: CGRect(x: 0, y: height - bandHeight, width: width, height: bandHeight)
        case .left: CGRect(x: 0, y: 0, width: bandWidth, height: height)
        case .right: CGRect(x: width - bandWidth, y: 0, width: bandWidth, height: height)
        }
    }
}

/// Reads the set/collector code from a rectified card by OCR-ing the four edge
/// bands. Whichever band yields a code also tells us the card's orientation.
public struct PrintedCodeReader: Sendable {
    private let textRecognizer: any TextRecognizing
    private let renderer: ImageRenderer
    private let canvas: CanvasSpecification
    private let parser: PrintedCodeParser
    /// Bands are enlarged before OCR; the code is printed about 2 mm tall.
    private let stripScale: CGFloat = 2

    public init(textRecognizer: any TextRecognizing, renderer: ImageRenderer, canvas: CanvasSpecification, parser: PrintedCodeParser) {
        self.textRecognizer = textRecognizer
        self.renderer = renderer
        self.canvas = canvas
        self.parser = parser
    }

    /// Every code found on the card, most confident first.
    public func readCode(from canvasImage: CGImage) async throws -> [CodeReading] {
        let base = CIImage(cgImage: canvasImage)
        let size = PixelSize(width: canvasImage.width, height: canvasImage.height)
        var strips: [(CodeStrip, CGImage)] = []
        for strip in CodeStrip.allCases {
            strips.append((strip, try stripImage(strip, from: base, size: size)))
        }
        var readings: [CodeReading] = []
        try await withThrowingTaskGroup(of: [CodeReading].self) { group in
            for (strip, image) in strips {
                group.addTask { try await self.read(strip: strip, image: image) }
            }
            for try await part in group {
                readings += part
            }
        }
        return readings.sorted { $0.confidence > $1.confidence }
    }

    private func stripImage(_ strip: CodeStrip, from base: CIImage, size: PixelSize) throws -> CGImage {
        let band = base.cropped(to: strip.rect(in: size, bandFraction: canvas.codeBandFraction)).movedToOrigin()
        let upright = band.rotated(quarterTurnsCounterclockwise: strip.quarterTurnsCounterclockwise)
        let enlarged = PixelSize(
            width: Int((upright.extent.width * stripScale).rounded()),
            height: Int((upright.extent.height * stripScale).rounded())
        )
        return try renderer.makeCGImage(fitting: upright, to: enlarged)
    }

    private func read(strip: CodeStrip, image: CGImage) async throws -> [CodeReading] {
        try await textRecognizer.recognizeText(in: image).flatMap { line in
            parser.codes(in: line.string).map { code in
                CodeReading(code: code, confidence: line.confidence, orientation: strip.orientation, layout: strip.layout, text: line.string)
            }
        }
    }
}
