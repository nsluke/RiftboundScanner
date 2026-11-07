import Foundation

/// A card added by hand (Collection -> Add card), for the 464 printings the
/// recogniser can never see and for anything acquired without a scan
/// (ADR-002, decision 13). Sent as a `manual:<id>` ledger item through the
/// same outbox as scan decisions; `manual.json` under the sync directory is
/// its durable truth, so a lost outbox cannot lose a card (principle 7).
nonisolated struct ManualItem: Hashable, Sendable, Codable, Identifiable {
    let id: UUID
    /// The printing key the server resolves through its aliases (`OGN-066-P`).
    let cardKey: String
    /// `nil` lets the server derive it from the printing.
    let finish: Finish?
    /// How many copies; positive.
    let quantity: Int
    let condition: String?
    let createdAt: Date
    /// Where the item stands with the server; `queued` until sent.
    var state: LedgerItemState

    init(id: UUID, cardKey: String, finish: Finish?, quantity: Int, condition: String? = "NM", createdAt: Date, state: LedgerItemState = .queued) {
        self.id = id
        self.cardKey = cardKey
        self.finish = finish
        self.quantity = quantity
        self.condition = condition
        self.createdAt = createdAt
        self.state = state
    }

    /// The deterministic reference the server keys idempotency on.
    var clientRef: String { Self.clientRef(for: id) }

    static func clientRef(for id: UUID) -> String { "manual:\(id.uuidString)" }

    /// The wire item.
    var ledgerItem: LedgerSyncItem {
        .delta(LedgerSyncItem.Delta(
            clientRef: clientRef,
            cardKey: cardKey,
            quantityDelta: quantity,
            finish: finish,
            condition: condition,
            occurredAt: createdAt
        ))
    }
}

/// The manual items and their states, in order of creation, as one JSON file.
actor ManualItemStore {
    private let fileURL: URL
    private var items: [ManualItem]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL) {
        self.fileURL = fileURL
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = (try? decoder.decode([ManualItem].self, from: Data(contentsOf: fileURL))) ?? []
    }

    func allItems() -> [ManualItem] { items }

    /// Items the server has not given its final word on.
    func pending() -> [ManualItem] {
        items.filter { !$0.state.isAcknowledged }
    }

    func add(_ item: ManualItem) throws {
        var updated = items
        updated.removeAll { $0.id == item.id }
        updated.append(item)
        try store(updated)
    }

    /// Records where an item stands; unknown references are ignored.
    func set(_ state: LedgerItemState, for clientRef: String) throws {
        guard let position = items.firstIndex(where: { $0.clientRef == clientRef }) else { return }
        var updated = items
        updated[position].state = state
        try store(updated)
    }

    private func store(_ updated: [ManualItem]) throws {
        guard updated != items else { return }
        items = updated
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(updated).write(to: fileURL, options: .atomic)
    }
}
