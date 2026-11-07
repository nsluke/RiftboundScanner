import CryptoKit
import Foundation
import RiftboundRecognizer

/// Who or what gave a verdict (ADR-002, decision 6). Machine labels must stay
/// separable from human ones forever, so the source is written with every
/// decision and never inferred later.
nonisolated enum DecisionSource: String, Hashable, Sendable, Codable, CaseIterable {
    /// The user judged the scan in a review screen.
    case human
    /// Accepted in bulk because the recogniser was confident; ledgers but never trains.
    case autoAccepted
    /// A confident scan the policy held back for a random audit, then judged by the user.
    case audit
    /// The user re-checked an already accepted scan on request.
    case spotCheck
    /// Synthesised from a v1 record's bare verdict; ledgers nothing.
    case legacy

    /// A person looked at the card.
    var isHuman: Bool {
        switch self {
        case .human, .audit, .spotCheck: true
        case .autoAccepted, .legacy: false
        }
    }
}

/// A record-level choice that a decision may leave alone or set. Folded over
/// the decision log, the last `.set` wins; a log with only `.inherit` entries
/// means the batch default (or the recognised printing) applies.
///
/// JSON: `{"inherit":true}` or `{"value":<Value>}`.
nonisolated enum Override<Value: Hashable & Sendable & Codable>: Hashable, Sendable, Codable {
    case inherit
    case set(Value)

    var value: Value? {
        if case .set(let value) = self { return value }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case inherit, value
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.value) {
            self = .set(try container.decode(Value.self, forKey: .value))
        } else if try container.decodeIfPresent(Bool.self, forKey: .inherit) == true {
            self = .inherit
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "an override needs either inherit:true or a value"))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inherit: try container.encode(true, forKey: .inherit)
        case .set(let value): try container.encode(value, forKey: .value)
        }
    }
}

/// One verdict in a scan's append-only log. `cardID` is a snapshot of the card
/// the verdict named at the time, so nothing that later re-ranks candidates
/// can change what was confirmed (ADR-002, principle 8).
nonisolated struct Decision: Hashable, Sendable, Codable, Identifiable {
    /// Encodes as the bare UUID string.
    struct ID: RawRepresentable, Hashable, Sendable, Codable {
        let rawValue: UUID

        init(rawValue: UUID) {
            self.rawValue = rawValue
        }

        init(from decoder: any Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(UUID.self)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        /// The id of the decision synthesised for a v1 record: derived from the
        /// scan id so decoding the same file twice yields the same decision.
        static func legacy(for scan: ScanRecord.ID) -> ID {
            let digest = SHA256.hash(data: Data("legacy-decision:\(scan.rawValue.uuidString)".utf8))
            var bytes = Array(digest.prefix(16))
            bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5 style, name based
            bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
            let uuid = bytes.withUnsafeBytes { $0.load(as: uuid_t.self) }
            return ID(rawValue: UUID(uuid: uuid))
        }
    }

    let id: ID
    /// 1 for the first decision on a scan, then +1 per decision; the ledger's
    /// client references (`scan:<id>:<seq>`) are built from it.
    let seq: Int
    let verdict: Verdict
    /// The card this decision confirmed: the top candidate at the time for
    /// `.correct`, the named card for `.corrected`, nothing for the rest.
    let cardID: Card.ID?
    let source: DecisionSource
    let decidedAt: Date
    let finish: Override<Finish>
    /// The printing to ledger when it differs from the recognised one, e.g. a
    /// promo the recogniser cannot tell apart (`OGN-066-P`).
    let ledgerPrintingCode: Override<PrintingKey>

    init(
        id: ID,
        seq: Int,
        verdict: Verdict,
        cardID: Card.ID?,
        source: DecisionSource,
        decidedAt: Date,
        finish: Override<Finish> = .inherit,
        ledgerPrintingCode: Override<PrintingKey> = .inherit
    ) {
        self.id = id
        self.seq = seq
        self.verdict = verdict
        self.cardID = cardID
        self.source = source
        self.decidedAt = decidedAt
        self.finish = finish
        self.ledgerPrintingCode = ledgerPrintingCode
    }

    private enum CodingKeys: String, CodingKey {
        case id, seq, verdict, cardID, source, decidedAt, finish, ledgerPrintingCode
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ID.self, forKey: .id)
        seq = try container.decode(Int.self, forKey: .seq)
        verdict = try container.decode(Verdict.self, forKey: .verdict)
        cardID = try container.decodeIfPresent(Card.ID.self, forKey: .cardID)
        source = try container.decode(DecisionSource.self, forKey: .source)
        decidedAt = try container.decode(Date.self, forKey: .decidedAt)
        finish = try container.decodeIfPresent(Override<Finish>.self, forKey: .finish) ?? .inherit
        ledgerPrintingCode = try container.decodeIfPresent(Override<PrintingKey>.self, forKey: .ledgerPrintingCode) ?? .inherit
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(seq, forKey: .seq)
        try container.encode(verdict, forKey: .verdict)
        try container.encodeIfPresent(cardID, forKey: .cardID)
        try container.encode(source, forKey: .source)
        try container.encode(decidedAt, forKey: .decidedAt)
        try container.encode(finish, forKey: .finish)
        try container.encode(ledgerPrintingCode, forKey: .ledgerPrintingCode)
    }
}

/// What a writer asks the store to record. The store supplies the id, the
/// sequence number, the time and the card snapshot, so a stale in-memory copy
/// of the record can never shape the decision (`ScanStoring.decide`).
nonisolated struct DecisionInput: Hashable, Sendable {
    let verdict: Verdict
    let source: DecisionSource
    let finish: Override<Finish>
    let ledgerPrintingCode: Override<PrintingKey>

    init(_ verdict: Verdict, source: DecisionSource, finish: Override<Finish> = .inherit, ledgerPrintingCode: Override<PrintingKey> = .inherit) {
        self.verdict = verdict
        self.source = source
        self.finish = finish
        self.ledgerPrintingCode = ledgerPrintingCode
    }
}
