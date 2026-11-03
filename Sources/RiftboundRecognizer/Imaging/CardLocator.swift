import CoreGraphics
import Vision

/// Where the card was found in a photo.
public enum CardLocation: Hashable, Sendable {
    case detected(CardQuad, confidence: Double)
    /// Nothing card-shaped was found; the whole image is treated as the card so
    /// that an already-cropped picture still works.
    case assumedWholeImage
}

/// A card-shaped rectangle the locator found.
public struct CardCandidate: Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        /// From the rectangle detector; may be the card's inner frame rather than its edge.
        case rectangleDetector
        /// Fitted to a salient object's bounding box; already the card's outline.
        case salientObject
    }

    public let quad: CardQuad
    public let confidence: Double
    public let source: Source

    public init(quad: CardQuad, confidence: Double, source: Source = .rectangleDetector) {
        self.quad = quad
        self.confidence = confidence
        self.source = source
    }
}

/// Finds card-shaped rectangles in a photo, most plausible first. Tests inject
/// a fake; the live implementation uses Vision.
public protocol CardLocating: Sendable {
    func locateCards(in image: CGImage) async throws -> [CardCandidate]
}

/// Finds cards with Vision's rectangle detector, backed up by objectness saliency.
///
/// Rectangle candidates are ranked by confidence, closeness to the 63 : 88
/// aspect ratio and size, because the detector also reports the card's inner
/// frame, its illustration, and rectangles merged with background edges. In a
/// cluttered scene it can lose the card entirely while saliency still boxes it,
/// so the most salient objects are fitted with ``CardQuad/fitting(boundingBox:cardAspectRatio:)``
/// and appended as lower-confidence candidates.
public struct VisionCardLocator: CardLocating {
    /// Vision's aspect ratio is short side over long side (1 is square), so the
    /// same range admits portrait and landscape cards. The margins allow foreshortening.
    public var minimumAspectRatio: Float = 0.55
    public var maximumAspectRatio: Float = 0.9
    public var minimumSize: Float = 0.15
    public var minimumConfidence: Float = 0.4
    public var maximumRectangleCandidates = 2
    public var maximumSalientObjects = 1

    public static let cardAspectRatio = 63.0 / 88.0

    public init() {}

    public func locateCards(in image: CGImage) async throws -> [CardCandidate] {
        async let rectangles = detectRectangles(in: image)
        async let salient = detectSalientObjects(in: image)
        return try await rectangles + salient
    }

    private func detectSalientObjects(in image: CGImage) async throws -> [CardCandidate] {
        let request = GenerateObjectnessBasedSaliencyImageRequest()
        let observation = try await request.perform(on: image)
        let size = CGSize(width: image.width, height: image.height)
        let objects = observation.salientObjects.sorted { $0.confidence > $1.confidence }.prefix(max(0, maximumSalientObjects))
        return objects.flatMap { object in
            let box = object.boundingBox.toImageCoordinates(size, origin: .lowerLeft)
            return CardQuad.fitting(boundingBox: box, cardAspectRatio: Self.cardAspectRatio).map { quad in
                CardCandidate(quad: quad, confidence: Double(object.confidence), source: .salientObject)
            }
        }
    }

    private func detectRectangles(in image: CGImage) async throws -> [CardCandidate] {
        var request = DetectRectanglesRequest()
        request.minimumAspectRatio = minimumAspectRatio
        request.maximumAspectRatio = maximumAspectRatio
        request.minimumSize = minimumSize
        request.minimumConfidence = minimumConfidence
        request.maximumObservations = 8
        let observations = try await request.perform(on: image)
        let size = CGSize(width: image.width, height: image.height)
        let ranked = observations.map { observation -> (candidate: CardCandidate, plausibility: Double) in
            let quad = CardQuad(
                topLeft: observation.topLeft.toImageCoordinates(size, origin: .lowerLeft),
                topRight: observation.topRight.toImageCoordinates(size, origin: .lowerLeft),
                bottomRight: observation.bottomRight.toImageCoordinates(size, origin: .lowerLeft),
                bottomLeft: observation.bottomLeft.toImageCoordinates(size, origin: .lowerLeft)
            )
            let candidate = CardCandidate(quad: quad, confidence: Double(observation.confidence))
            return (candidate, Self.plausibility(of: quad, confidence: candidate.confidence, imageSize: size))
        }
        return ranked.sorted { $0.plausibility > $1.plausibility }.prefix(max(0, maximumRectangleCandidates)).map(\.candidate)
    }

    /// Confidence, scaled down as the aspect ratio drifts from a card's and
    /// scaled up gently with size.
    static func plausibility(of quad: CardQuad, confidence: Double, imageSize: CGSize) -> Double {
        let longSide = max(quad.averageWidth, quad.averageHeight)
        let shortSide = min(quad.averageWidth, quad.averageHeight)
        guard longSide > 0 else { return 0 }
        let aspectFit = max(0, 1 - abs(Double(shortSide / longSide) - cardAspectRatio) / 0.12)
        let areaFraction = Double(longSide * shortSide) / Double(imageSize.width * imageSize.height)
        return confidence * aspectFit * areaFraction.squareRoot()
    }
}
