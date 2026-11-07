import CoreGraphics
import RiftboundRecognizer

/// A recognition result together with the stamp of the engine that produced
/// it: the package build and embedding, plus the learned overlay and policy
/// once those exist. Every saved scan records the stamp (ADR-002, decision 8).
nonisolated struct IdentifiedCard: Sendable {
    let result: RecognitionResult
    let engine: EngineStamp

    init(result: RecognitionResult, engine: EngineStamp) {
        self.result = result
        self.engine = engine
    }
}

/// Identifies the card in a photo. The live implementation wraps the package's
/// recogniser; tests inject a stub with canned results.
nonisolated protocol CardIdentifying: Sendable {
    func identify(_ photo: CGImage) async throws -> IdentifiedCard
}

nonisolated struct LiveCardIdentifier: CardIdentifying {
    let recognizer: CardRecognizer

    func identify(_ photo: CGImage) async throws -> IdentifiedCard {
        let result = try await recognizer.identify(photo)
        return IdentifiedCard(result: result, engine: EngineStamp(result.engine))
    }
}
