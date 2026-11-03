import CoreGraphics
import RiftboundRecognizer

/// Identifies the card in a photo. The live implementation wraps the package's
/// recogniser; tests inject a stub with canned results.
nonisolated protocol CardIdentifying: Sendable {
    func identify(_ photo: CGImage) async throws -> RecognitionResult
}

nonisolated struct LiveCardIdentifier: CardIdentifying {
    let recognizer: CardRecognizer

    func identify(_ photo: CGImage) async throws -> RecognitionResult {
        try await recognizer.identify(photo)
    }
}
