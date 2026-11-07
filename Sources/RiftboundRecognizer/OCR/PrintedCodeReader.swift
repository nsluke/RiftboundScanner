import CoreGraphics
import CoreImage

/// Where in the image a printed code was read.
public enum CodeSource: String, Hashable, Sendable, Codable {
    /// One of the four edge bands of the rectified canvas: the code sat where a
    /// card prints it, so the reading also vouches for the card's placement.
    case edgeBand
    /// Anywhere in the un-rectified photo, the fallback for a crop whose code
    /// the canvas's bands missed; says nothing about the placement.
    case fullImage
}

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
    public let source: CodeSource
    /// Whether ``code`` is what the text literally says or a digit alternative
    /// the parser substituted because the literal reading named nothing.
    public let origin: CodeOrigin
    /// Every index-known code the text could name, best first, beginning with
    /// ``code``; the rest are the parser's ranked digit alternatives
    /// (`1` ↔ `2`, `7` ↔ `1`). The recogniser credits a candidate that matches
    /// one of them, less than it credits the literal reading.
    public let alternatives: [PrintedCode]

    /// `alternatives` need not repeat `code`; it is placed first regardless.
    public init(
        code: PrintedCode,
        confidence: Double,
        orientation: CardOrientation,
        layout: Card.Orientation,
        text: String,
        source: CodeSource,
        origin: CodeOrigin = .literal,
        alternatives: [PrintedCode] = []
    ) {
        self.code = code
        self.confidence = confidence
        self.orientation = orientation
        self.layout = layout
        self.text = text
        self.source = source
        self.origin = origin
        self.alternatives = [code] + alternatives.filter { $0 != code }
    }

    init(_ interpretation: CodeInterpretation, confidence: Double, orientation: CardOrientation, layout: Card.Orientation, text: String, source: CodeSource) {
        self.init(
            code: interpretation.code, confidence: confidence, orientation: orientation, layout: layout, text: text, source: source,
            origin: interpretation.origin, alternatives: interpretation.alternatives
        )
    }

    /// How this reading bears on a candidate printing's code, or `nil` when it
    /// says nothing about it.
    ///
    /// A literal reading is compared first and supplies every kind of
    /// agreement, penalties included; when it is not an exact match, an exact
    /// match against one of the alternatives counts as ``CodeAgreement/exact``
    /// *via* ``CodeOrigin/alternative``. Alternatives, and a reading whose
    /// ``code`` is itself an alternative (the literal text named no printing),
    /// are guesses and therefore only ever positive evidence: they never
    /// penalise a candidate and never supply variant-only matches, so a garbled
    /// code cannot demote the card the descriptors favour.
    public func evidence(for candidate: PrintedCode) -> CodeEvidence? {
        var literal: CodeEvidence?
        if origin == .literal {
            literal = CodeEvidence(agreement: CodeAgreement(reading: code, candidate: candidate), origin: .literal)
            if literal?.agreement == .exact { return literal }
        }
        let guesses = origin == .literal ? alternatives.dropFirst() : alternatives[...]
        if guesses.contains(where: { CodeAgreement(reading: $0, candidate: candidate) == .exact }) {
            return CodeEvidence(agreement: .exact, origin: .alternative)
        }
        return literal
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

    /// Every code found on the card, most confident first. `hints` restrain the
    /// parser's repairs; see ``RecognitionHints/expectedSet``.
    public func readCode(from canvasImage: CGImage, hints: RecognitionHints = .none) async throws -> [CodeReading] {
        let base = CIImage(cgImage: canvasImage)
        let size = PixelSize(width: canvasImage.width, height: canvasImage.height)
        var strips: [(CodeStrip, CGImage)] = []
        for strip in CodeStrip.allCases {
            strips.append((strip, try stripImage(strip, from: base, size: size)))
        }
        var readings: [CodeReading] = []
        try await withThrowingTaskGroup(of: [CodeReading].self) { group in
            for (strip, image) in strips {
                group.addTask { try await self.read(strip: strip, image: image, hints: hints) }
            }
            for try await part in group {
                readings += part
            }
        }
        return readings.sorted { $0.confidence > $1.confidence }
    }

    /// Every code found anywhere in an un-rectified image, most confident first,
    /// tried upright and turned through 180°. For a photo that is already a
    /// tight crop of a card (a feeder stand), the code is legible in the photo
    /// itself even when nothing card-shaped could be located in it.
    public func readCode(fromFullImage image: CGImage, maxPixelSize: Int = 1536, hints: RecognitionHints = .none) async throws -> [CodeReading] {
        let base = CIImage(cgImage: image)
        let longest = CGFloat(max(image.width, image.height))
        let scale = min(1, CGFloat(maxPixelSize) / longest)
        let fitted = PixelSize(width: Int((CGFloat(image.width) * scale).rounded()), height: Int((CGFloat(image.height) * scale).rounded()))
        let layout: Card.Orientation = image.width <= image.height ? .portrait : .landscape
        // Upright first; the 180° pass only runs when nothing was found, since
        // a full-frame OCR pass is the costliest step in the pipeline.
        let upright = try renderer.makeCGImage(fitting: base, to: fitted)
        let uprightReadings = try await textRecognizer.recognizeText(in: upright).flatMap { line in
            parser.interpretations(in: line.string, hints: hints).map { CodeReading($0, confidence: line.confidence, orientation: .upright, layout: layout, text: line.string, source: .fullImage) }
        }
        if !uprightReadings.isEmpty {
            return uprightReadings.sorted { $0.confidence > $1.confidence }
        }
        let upsideDown = try renderer.makeCGImage(fitting: base.rotated(quarterTurnsCounterclockwise: 2), to: fitted)
        return try await textRecognizer.recognizeText(in: upsideDown).flatMap { line in
            parser.interpretations(in: line.string, hints: hints).map { CodeReading($0, confidence: line.confidence, orientation: .upsideDown, layout: layout, text: line.string, source: .fullImage) }
        }.sorted { $0.confidence > $1.confidence }
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

    private func read(strip: CodeStrip, image: CGImage, hints: RecognitionHints) async throws -> [CodeReading] {
        try await textRecognizer.recognizeText(in: image).flatMap { line in
            parser.interpretations(in: line.string, hints: hints).map { interpretation in
                CodeReading(interpretation, confidence: line.confidence, orientation: strip.orientation, layout: strip.layout, text: line.string, source: .edgeBand)
            }
        }
    }
}
