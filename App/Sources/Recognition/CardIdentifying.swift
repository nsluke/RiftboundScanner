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
/// recogniser; tests inject a stub with canned results. `hints` carries what
/// the run already knows (a sealed box's set), which biases the ranking and
/// restrains OCR repairs without vetoing what the card says (ADR-002, decision 14).
nonisolated protocol CardIdentifying: Sendable {
    func identify(_ photo: CGImage, hints: RecognitionHints) async throws -> IdentifiedCard
}

nonisolated extension CardIdentifying {
    /// Identification with no prior knowledge.
    func identify(_ photo: CGImage) async throws -> IdentifiedCard {
        try await identify(photo, hints: .none)
    }
}

nonisolated struct LiveCardIdentifier: CardIdentifying {
    let recognizer: CardRecognizer

    func identify(_ photo: CGImage, hints: RecognitionHints) async throws -> IdentifiedCard {
        let result = try await recognizer.identify(photo, hints: hints)
        return IdentifiedCard(result: result, engine: EngineStamp(result.engine))
    }
}
