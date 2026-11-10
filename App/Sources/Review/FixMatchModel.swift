import Observation
import RiftboundRecognizer

/// Finds the right printing for a wrong match from one field: a name, a code
/// with its set, or a bare collector number (`FixQuery`). Results resolve as
/// the user types; the arrow keys move the selection and Return uses it.
@Observable
final class FixMatchModel: Identifiable {
    let record: ScanRecord
    let directory: CardDirectory
    var query = "" {
        didSet { resolve() }
    }
    /// The printings the query names, best first.
    private(set) var results: [Card] = []
    /// The result Return would use; the first one whenever the results change.
    private(set) var selection: Card.ID?
    /// Where a bare number is looked up first: the set of the last fix in
    /// this review, else the batch's usual set, else the matched card's.
    let preferredSet: SetCode?
    /// What the server last said about this scan's ledger item, when it was
    /// something the user has to act on (`unknown_card`, `duplicate_mismatch`).
    let serverStatus: TerminalStatus?

    init(record: ScanRecord, directory: CardDirectory, preferredSet: SetCode?, serverStatus: TerminalStatus? = nil) {
        self.record = record
        self.directory = directory
        self.serverStatus = serverStatus
        self.preferredSet = preferredSet ?? record.topCandidate?.card.code.set ?? record.codeReading?.code.set
    }

    /// The query as the panel understood it, for the hint under the field.
    var parsedQuery: FixQuery {
        FixQuery(query, sets: directory.sets)
    }

    var selectedCard: Card? {
        results.first { $0.id == selection }
    }

    /// Moves the selection `offset` rows, stopping at either end.
    func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        let index = results.firstIndex { $0.id == selection } ?? 0
        selection = results[min(max(index + offset, 0), results.count - 1)].id
    }

    func select(_ card: Card) {
        selection = card.id
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

    /// The scan's candidates other than the one it was matched to.
    var otherCandidates: [Candidate] {
        Array(record.candidates.dropFirst())
    }

    private func resolve() {
        results = directory.cards(for: parsedQuery, preferredSet: preferredSet)
        selection = results.first?.id
    }
}
