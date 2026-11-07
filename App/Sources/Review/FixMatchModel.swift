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
    /// What the server last said about this scan's ledger item, when it was
    /// something the user has to act on (`unknown_card`, `duplicate_mismatch`).
    let serverStatus: TerminalStatus?

    init(record: ScanRecord, directory: CardDirectory, preferredSet: SetCode?, serverStatus: TerminalStatus? = nil) {
        self.record = record
        self.directory = directory
        self.serverStatus = serverStatus
        set = preferredSet ?? record.topCandidate?.card.code.set ?? directory.sets.first ?? record.codeReading?.code.set ?? SetCode(rawValue: "OGN")!
    }

    /// The printing key the ledger was sent for this scan: the override when
    /// a decision chose one, else the confirmed (or recognised) card's own.
    var ledgeredKey: PrintingKey? {
        record.effectivePrintingCode
            ?? record.confirmedCardID.flatMap(PrintingKey.init(cardID:))
            ?? record.topCandidate.map { PrintingKey($0.card.code) }
    }

    /// Plain words for a server outcome that needs a person (ADR-002,
    /// principle 2), or `nil` when the server said nothing of the kind.
    var explanation: String? {
        switch serverStatus {
        case .unknownCard:
            let key = ledgeredKey?.rawValue ?? String(localized: "this printing")
            return String(localized: "The server does not know the printing \(key). Pick the card or printing it lists; a new decision here is sent as a new item, and the old one is retried on its own when the server's catalog changes.")
        case .duplicateMismatch:
            return String(localized: "The server already holds an item with this scan's reference but different content, so it kept what it had. A new decision here is sent as a new item; compare the two on the web if the count looks wrong.")
        case .wouldGoNegative, .nothingToUndo:
            return String(localized: "The server refused to undo this scan's earlier item. Resolve the count on the web; a new decision here is still sent.")
        case .invalid, .unrecognized:
            return String(localized: "The server rejected this scan's ledger item. A new decision here is sent as a new item.")
        case .duplicate, nil:
            return nil
        }
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
