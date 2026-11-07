import Foundation

// The phone's record of what the server has acknowledged (ADR-002, decision
// 4). Durable truth is `scans.json` (decisions) plus one `sync.json` per
// batch holding these states; the outbox is derived from the two and can be
// deleted at any time. Every enum encodes as `{"kind": …}` plus its fields,
// like the rest of the scan JSON.

/// The deterministic name of one ledger item: `scan:<scan id>:<seq>` for the
/// +1 a decision caused, `scan:<scan id>:<seq>:undo` for the undo a later
/// decision caused. The server keys idempotency on it.
nonisolated struct ClientRef: Hashable, Sendable, CustomStringConvertible {
    let scanID: ScanRecord.ID
    let seq: Int
    let isUndo: Bool

    init(scanID: ScanRecord.ID, seq: Int, isUndo: Bool = false) {
        self.scanID = scanID
        self.seq = seq
        self.isUndo = isUndo
    }

    static func plusOne(_ scanID: ScanRecord.ID, seq: Int) -> ClientRef {
        ClientRef(scanID: scanID, seq: seq)
    }

    static func undo(_ scanID: ScanRecord.ID, seq: Int) -> ClientRef {
        ClientRef(scanID: scanID, seq: seq, isUndo: true)
    }

    /// Parses `scan:<uuid>:<seq>[:undo]`; `nil` for anything else (a web
    /// `manual:` reference, say).
    init?(_ string: String) {
        let parts = string.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3 || parts.count == 4, parts[0] == "scan",
              let uuid = UUID(uuidString: String(parts[1])), let seq = Int(parts[2]), seq > 0 else { return nil }
        if parts.count == 4 {
            guard parts[3] == "undo" else { return nil }
            isUndo = true
        } else {
            isUndo = false
        }
        scanID = ScanRecord.ID(rawValue: uuid)
        self.seq = seq
    }

    var description: String {
        "scan:\(scanID.rawValue.uuidString):\(seq)" + (isUndo ? ":undo" : "")
    }
}

/// Why a ledger item is finished without having been applied. Every case is
/// acknowledged: the phone never sends the item again, except an
/// `unknownCard` once the server's catalog changes.
nonisolated enum TerminalStatus: Hashable, Sendable, Codable {
    /// The server already had this reference with the same content.
    case duplicate
    /// The server had this reference with different content; needs a look.
    case duplicateMismatch
    /// The key resolved to no card under the named catalog version.
    case unknownCard(catalogVersion: String?)
    /// An undo that would take a holding below zero (a web edit got there first).
    case wouldGoNegative
    /// An undo whose target row does not exist on the server.
    case nothingToUndo
    /// The server rejected the item itself.
    case invalid
    /// A status this build does not know; kept verbatim and shown for attention.
    case unrecognized(String)

    /// The terminal reading of a server status; `nil` for `.applied`, which
    /// is a row, not an ending.
    init?(_ status: LedgerItemStatus, catalogVersion: String?) {
        switch status {
        case .applied: return nil
        case .duplicate: self = .duplicate
        case .duplicateMismatch: self = .duplicateMismatch
        case .unknownCard: self = .unknownCard(catalogVersion: catalogVersion)
        case .wouldGoNegative: self = .wouldGoNegative
        case .nothingToUndo: self = .nothingToUndo
        case .invalid: self = .invalid
        case .unknown(let raw): self = .unrecognized(raw)
        }
    }

    /// Whether the outcome deserves a needs-attention row. `duplicate` is a
    /// clean replay and says nothing the user should act on.
    var needsAttention: Bool {
        switch self {
        case .duplicate: false
        case .duplicateMismatch, .unknownCard, .wouldGoNegative, .nothingToUndo, .invalid, .unrecognized: true
        }
    }

    var message: String {
        switch self {
        case .duplicate: String(localized: "Already in the ledger.")
        case .duplicateMismatch: String(localized: "The server has this item with different content.")
        case .unknownCard: String(localized: "The server does not know this printing. It is retried when the catalog changes.")
        case .wouldGoNegative: String(localized: "Undo refused: the holding was already emptied on the web. Resolve on the web.")
        case .nothingToUndo: String(localized: "Undo refused: the server has no row to reverse.")
        case .invalid: String(localized: "The server rejected this item.")
        case .unrecognized(let raw): String(localized: "The server answered “\(raw)”.")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, catalogVersion, raw
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "duplicate": self = .duplicate
        case "duplicateMismatch": self = .duplicateMismatch
        case "unknownCard": self = .unknownCard(catalogVersion: try container.decodeIfPresent(String.self, forKey: .catalogVersion))
        case "wouldGoNegative": self = .wouldGoNegative
        case "nothingToUndo": self = .nothingToUndo
        case "invalid": self = .invalid
        case "unrecognized": self = .unrecognized(try container.decodeIfPresent(String.self, forKey: .raw) ?? "")
        case let other: self = .unrecognized(other)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .duplicate: try container.encode("duplicate", forKey: .kind)
        case .duplicateMismatch: try container.encode("duplicateMismatch", forKey: .kind)
        case .unknownCard(let version):
            try container.encode("unknownCard", forKey: .kind)
            try container.encodeIfPresent(version, forKey: .catalogVersion)
        case .wouldGoNegative: try container.encode("wouldGoNegative", forKey: .kind)
        case .nothingToUndo: try container.encode("nothingToUndo", forKey: .kind)
        case .invalid: try container.encode("invalid", forKey: .kind)
        case .unrecognized(let raw):
            try container.encode("unrecognized", forKey: .kind)
            try container.encode(raw, forKey: .raw)
        }
    }
}

/// Where one ledger item stands with the server.
nonisolated enum LedgerItemState: Hashable, Sendable, Codable {
    /// In the outbox, or about to be re-derived into it.
    case queued
    /// The server inserted a row; an undo of this item names it by reference.
    case applied(ledgerID: Int, cardID: String, finish: Finish?)
    /// Acknowledged without a row.
    case terminal(TerminalStatus)

    /// Whether the server has given its final word.
    var isAcknowledged: Bool {
        switch self {
        case .queued: false
        case .applied, .terminal: true
        }
    }

    var isApplied: Bool {
        if case .applied = self { return true }
        return false
    }

    private enum CodingKeys: String, CodingKey {
        case kind, ledgerID, cardID, finish, status
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "queued": self = .queued
        case "applied":
            self = .applied(
                ledgerID: try container.decode(Int.self, forKey: .ledgerID),
                cardID: try container.decode(String.self, forKey: .cardID),
                finish: try container.decodeIfPresent(Finish.self, forKey: .finish)
            )
        case "terminal": self = .terminal(try container.decode(TerminalStatus.self, forKey: .status))
        case let other: throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown ledger item state \(other)")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .queued:
            try container.encode("queued", forKey: .kind)
        case .applied(let ledgerID, let cardID, let finish):
            try container.encode("applied", forKey: .kind)
            try container.encode(ledgerID, forKey: .ledgerID)
            try container.encode(cardID, forKey: .cardID)
            try container.encodeIfPresent(finish, forKey: .finish)
        case .terminal(let status):
            try container.encode("terminal", forKey: .kind)
            try container.encode(status, forKey: .status)
        }
    }
}

/// Where one upload (the record JSON, or one of its assets) stands.
nonisolated enum UploadState: Hashable, Sendable, Codable {
    /// The tier rules do not want this upload for this scan (yet).
    case notEligible
    case queued
    case uploaded(Date)
    /// 409: the server holds a newer decision log; terminal, needs a look.
    case conflict(serverSeq: Int?)
    /// The last attempt was refused for a reason retrying alone will not fix;
    /// tried again on the next flush in case the server changed.
    case failed(String)

    var isUploaded: Bool {
        if case .uploaded = self { return true }
        return false
    }

    /// Whether the drain should attempt it.
    var wantsUpload: Bool {
        switch self {
        case .queued, .failed: true
        case .notEligible, .uploaded, .conflict: false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, at, serverSeq, reason
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "notEligible": self = .notEligible
        case "queued": self = .queued
        case "uploaded": self = .uploaded(try container.decode(Date.self, forKey: .at))
        case "conflict": self = .conflict(serverSeq: try container.decodeIfPresent(Int.self, forKey: .serverSeq))
        case "failed": self = .failed(try container.decodeIfPresent(String.self, forKey: .reason) ?? "")
        case let other: throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown upload state \(other)")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .notEligible: try container.encode("notEligible", forKey: .kind)
        case .queued: try container.encode("queued", forKey: .kind)
        case .uploaded(let date):
            try container.encode("uploaded", forKey: .kind)
            try container.encode(date, forKey: .at)
        case .conflict(let serverSeq):
            try container.encode("conflict", forKey: .kind)
            try container.encodeIfPresent(serverSeq, forKey: .serverSeq)
        case .failed(let reason):
            try container.encode("failed", forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }
}

/// Everything the server has said about one scan: its ledger items by client
/// reference, the record upload and the three asset uploads.
nonisolated struct ScanSyncState: Hashable, Sendable, Codable {
    var items: [String: LedgerItemState]
    /// How many decisions the server's copy of the record had when it last
    /// accepted one; a longer log on the phone re-queues the record.
    var uploadedSeq: Int
    var record: UploadState
    var photoSmall: UploadState
    var canvas: UploadState
    var photo: UploadState

    init(
        items: [String: LedgerItemState] = [:],
        uploadedSeq: Int = 0,
        record: UploadState = .notEligible,
        photoSmall: UploadState = .notEligible,
        canvas: UploadState = .notEligible,
        photo: UploadState = .notEligible
    ) {
        self.items = items
        self.uploadedSeq = uploadedSeq
        self.record = record
        self.photoSmall = photoSmall
        self.canvas = canvas
        self.photo = photo
    }

    subscript(ref: ClientRef) -> LedgerItemState? {
        get { items[ref.description] }
        set { items[ref.description] = newValue }
    }

    subscript(kind: AssetKind) -> UploadState {
        get {
            switch kind {
            case .photoSmall: photoSmall
            case .canvas: canvas
            case .photo: photo
            }
        }
        set {
            switch kind {
            case .photoSmall: photoSmall = newValue
            case .canvas: canvas = newValue
            case .photo: photo = newValue
            }
        }
    }

    /// Every ledger item has the server's final word.
    var allItemsAcknowledged: Bool {
        items.values.allSatisfy(\.isAcknowledged)
    }

    /// Undo items the server refused: the holding was gone or the row was
    /// missing. Voiding completes with these counted, not retried.
    var rejectedUndos: Int {
        items.filter { ref, state in
            guard ClientRef(ref)?.isUndo == true, case .terminal(let status) = state else { return false }
            return status != .duplicate
        }.count
    }

    private enum CodingKeys: String, CodingKey {
        case items, uploadedSeq, record, photoSmall, canvas, photo
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            items: try container.decodeIfPresent([String: LedgerItemState].self, forKey: .items) ?? [:],
            uploadedSeq: try container.decodeIfPresent(Int.self, forKey: .uploadedSeq) ?? 0,
            record: try container.decodeIfPresent(UploadState.self, forKey: .record) ?? .notEligible,
            photoSmall: try container.decodeIfPresent(UploadState.self, forKey: .photoSmall) ?? .notEligible,
            canvas: try container.decodeIfPresent(UploadState.self, forKey: .canvas) ?? .notEligible,
            photo: try container.decodeIfPresent(UploadState.self, forKey: .photo) ?? .notEligible
        )
    }
}

/// One batch's `sync.json`: the batch metadata upload, every scan's state,
/// and the two user actions that change what sync does with the batch.
nonisolated struct BatchSyncState: Hashable, Sendable, Codable {
    static let formatVersion = 1

    let batchID: ScanBatch.ID
    var batchMeta: UploadState
    /// Keyed by the scan id's UUID string, so the file stays readable.
    var scans: [String: ScanSyncState]
    /// Set by "Close batch": no more scans; A5's pruner may delete photos.
    var closedAt: Date?
    /// Set by "Void batch": every record carries a `voided` decision and the
    /// folder goes once every ledger item is acknowledged.
    var voidedAt: Date?

    init(batchID: ScanBatch.ID, batchMeta: UploadState = .queued, scans: [String: ScanSyncState] = [:], closedAt: Date? = nil, voidedAt: Date? = nil) {
        self.batchID = batchID
        self.batchMeta = batchMeta
        self.scans = scans
        self.closedAt = closedAt
        self.voidedAt = voidedAt
    }

    subscript(scan: ScanRecord.ID) -> ScanSyncState {
        get { scans[scan.rawValue.uuidString] ?? ScanSyncState() }
        set { scans[scan.rawValue.uuidString] = newValue }
    }

    var isClosed: Bool { closedAt != nil }
    var isVoided: Bool { voidedAt != nil }

    var rejectedUndos: Int { scans.values.reduce(0) { $0 + $1.rejectedUndos } }

    /// Every ledger item of every scan has the server's final word.
    var allItemsAcknowledged: Bool { scans.values.allSatisfy(\.allItemsAcknowledged) }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, batchID, batchMeta, scans, closedAt, voidedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            batchID: try container.decode(ScanBatch.ID.self, forKey: .batchID),
            batchMeta: try container.decodeIfPresent(UploadState.self, forKey: .batchMeta) ?? .queued,
            scans: try container.decodeIfPresent([String: ScanSyncState].self, forKey: .scans) ?? [:],
            closedAt: try container.decodeIfPresent(Date.self, forKey: .closedAt),
            voidedAt: try container.decodeIfPresent(Date.self, forKey: .voidedAt)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.formatVersion, forKey: .formatVersion)
        try container.encode(batchID, forKey: .batchID)
        try container.encode(batchMeta, forKey: .batchMeta)
        try container.encode(scans, forKey: .scans)
        try container.encodeIfPresent(closedAt, forKey: .closedAt)
        try container.encodeIfPresent(voidedAt, forKey: .voidedAt)
    }
}

/// Which uploads a scan is due (ADR-002, decision 4 payload tiers): the
/// record for every decided scan, `photo_small` for every decided scan, the
/// rectified canvas when a person decided, the full photo when the
/// recogniser was wrong or the card was rejected. A5 adds audit samples.
nonisolated enum UploadTiers {
    static func wantsRecord(_ record: ScanRecord) -> Bool {
        !record.decisions.isEmpty
    }

    static func eligibleAssets(for record: ScanRecord) -> Set<AssetKind> {
        guard let last = record.lastDecision else { return [] }
        var kinds: Set<AssetKind> = [.photoSmall]
        if last.source.isHuman {
            kinds.insert(.canvas)
        }
        switch last.verdict {
        case .corrected, .rejected: kinds.insert(.photo)
        case .pending, .correct, .voided: break
        }
        return kinds
    }
}
