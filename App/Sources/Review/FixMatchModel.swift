import Observation
import RiftboundRecognizer

/// Resolves a typed collector number against the index as the user types,
/// within one set. Code first: it is the one thing on the card that names a
/// printing unambiguously.
@Observable
final class FixMatchModel {
    let record: ScanRecord
    let directory: CardDirectory
    var set: SetCode {
        didSet { resolve() }
    }
    var numberText = "" {
        didSet { resolve() }
    }
    /// Printings matching the typed number; usually one, more when a number
    /// has alternate-art or signature printings.
    private(set) var matches: [Card] = []

    init(record: ScanRecord, directory: CardDirectory, preferredSet: SetCode?) {
        self.record = record
        self.directory = directory
        set = preferredSet ?? record.topCandidate?.card.code.set ?? directory.sets.first ?? record.codeReading?.code.set ?? SetCode(rawValue: "OGN")!
    }

    var sets: [SetCode] { directory.sets }

    /// The scan's candidates other than the one it was matched to.
    var otherCandidates: [Candidate] {
        Array(record.candidates.dropFirst())
    }

    private func resolve() {
        matches = numberText.isEmpty ? [] : directory.cards(in: set, number: numberText)
    }
}
