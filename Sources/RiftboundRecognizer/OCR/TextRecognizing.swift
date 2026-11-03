import CoreGraphics
import Foundation
import Vision

/// One line of recognised text with the recogniser's confidence in 0...1.
public struct TextLine: Hashable, Sendable {
    public let string: String
    public let confidence: Double

    public init(string: String, confidence: Double) {
        self.string = string
        self.confidence = confidence
    }
}

/// Reads text from an image. Tests inject a stub; the live implementation uses Vision.
public protocol TextRecognizing: Sendable {
    func recognizeText(in image: CGImage) async throws -> [TextLine]
}

/// Wraps Vision's `RecognizeTextRequest`, tuned for short printed codes:
/// accurate mode, no language correction (which would "fix" `OGN` into a word).
///
/// Requests are limited to `maxConcurrentRequests` at a time (one by default):
/// Vision's text recogniser crashed under heavy concurrent use.
public struct VisionTextRecognizer: TextRecognizing {
    private let limiter: AsyncLimiter

    public init(maxConcurrentRequests: Int = 1) {
        limiter = AsyncLimiter(limit: maxConcurrentRequests)
    }

    public func recognizeText(in image: CGImage) async throws -> [TextLine] {
        try await limiter.run {
            var request = RecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.automaticallyDetectsLanguage = false
            request.recognitionLanguages = [Locale.Language(identifier: "en-US")]
            let observations = try await request.perform(on: image)
            return observations.compactMap { observation in
                observation.topCandidates(1).first.map { candidate in
                    TextLine(string: candidate.string, confidence: Double(candidate.confidence))
                }
            }
        }
    }
}
