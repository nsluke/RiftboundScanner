import Foundation

// The wire shapes of the collection server (ADR-002 §5). Snake_case on the
// wire through explicit coding keys, never a key strategy, so documents the
// app forwards verbatim (`JSONValue`) keep their own spelling. No DTO carries
// an image URL: the server stores no Riot assets (Decision 15).

// MARK: - /health

/// `GET /health`. Every v2 field is optional so a v1 server still decodes and
/// Settings can say "Server needs updating" instead of "malformed".
nonisolated struct HealthReport: Hashable, Sendable, Codable {
    /// The schema version the app needs (ADR-002 Decision 5).
    static let minimumUserVersion = 3

    let status: String
    let version: String?
    let cards: Int?
    let catalogAsOf: String?
    let pricesRefreshedAt: String?
    let userVersion: Int?
    let apiVersion: Int?
    let catalogVersion: String?
    let lastBackupAt: String?
    let freeDiskMB: Double?
    let rssMB: Double?
    let assetsBytes: Int?
    let scansStored: Int?
    let exemplars: Int?
    let overlayVersions: Int?
    let catalogWarnings: [String]?

    init(
        status: String = "ok",
        version: String? = nil,
        cards: Int? = nil,
        catalogAsOf: String? = nil,
        pricesRefreshedAt: String? = nil,
        userVersion: Int? = nil,
        apiVersion: Int? = nil,
        catalogVersion: String? = nil,
        lastBackupAt: String? = nil,
        freeDiskMB: Double? = nil,
        rssMB: Double? = nil,
        assetsBytes: Int? = nil,
        scansStored: Int? = nil,
        exemplars: Int? = nil,
        overlayVersions: Int? = nil,
        catalogWarnings: [String]? = nil
    ) {
        self.status = status
        self.version = version
        self.cards = cards
        self.catalogAsOf = catalogAsOf
        self.pricesRefreshedAt = pricesRefreshedAt
        self.userVersion = userVersion
        self.apiVersion = apiVersion
        self.catalogVersion = catalogVersion
        self.lastBackupAt = lastBackupAt
        self.freeDiskMB = freeDiskMB
        self.rssMB = rssMB
        self.assetsBytes = assetsBytes
        self.scansStored = scansStored
        self.exemplars = exemplars
        self.overlayVersions = overlayVersions
        self.catalogWarnings = catalogWarnings
    }

    /// Whether the app may talk to this server: a missing `user_version` is a
    /// pre-migration server and counts as 0.
    var isSupported: Bool { (userVersion ?? 0) >= Self.minimumUserVersion }

    private enum CodingKeys: String, CodingKey {
        case status, version, cards, exemplars
        case catalogAsOf = "catalog_as_of"
        case pricesRefreshedAt = "prices_refreshed_at"
        case userVersion = "user_version"
        case apiVersion = "api_version"
        case catalogVersion = "catalog_version"
        case lastBackupAt = "last_backup_at"
        case freeDiskMB = "free_disk_mb"
        case rssMB = "rss_mb"
        case assetsBytes = "assets_bytes"
        case scansStored = "scans_stored"
        case overlayVersions = "overlay_versions"
        case catalogWarnings = "catalog_warnings"
    }
}

// MARK: - /api/cards/resolve

/// One resolved printing key: the vault code it maps to, the finishes it is
/// printed in, its siblings (same set and number, any suffix) and its
/// learning identity.
nonisolated struct CardResolution: Hashable, Sendable, Codable {
    let cardID: String
    let finishes: [Finish]
    let siblings: [String]
    let artGroup: String?

    init(cardID: String, finishes: [Finish], siblings: [String] = [], artGroup: String? = nil) {
        self.cardID = cardID
        self.finishes = finishes
        self.siblings = siblings
        self.artGroup = artGroup
    }

    private enum CodingKeys: String, CodingKey {
        case cardID = "card_id"
        case finishes, siblings
        case artGroup = "art_group"
    }
}

/// `GET /api/cards/resolve?keys=`: resolutions keyed by the requested key,
/// plus the keys the server does not know.
nonisolated struct ResolveResponse: Hashable, Sendable, Codable {
    let resolved: [String: CardResolution]
    let unknown: [String]

    init(resolved: [String: CardResolution], unknown: [String] = []) {
        self.resolved = resolved
        self.unknown = unknown
    }
}

// MARK: - POST /api/sync/ledger

/// One item of a sync request. An undo names the applied row it reverses and
/// carries no card fields; a delta names the card. The flat wire shape is
/// `{client_ref, undo_of?, card_key?, finish?, default_finish?, quantity_delta?, occurred_at?, scan_id?, condition?}`.
nonisolated enum LedgerSyncItem: Hashable, Sendable, Codable {
    case delta(Delta)
    case undo(Undo)

    nonisolated struct Delta: Hashable, Sendable {
        let clientRef: String
        let cardKey: String
        let quantityDelta: Int
        /// `nil` lets the server derive the finish from the printing and `defaultFinish`.
        let finish: Finish?
        let defaultFinish: Finish?
        let condition: String?
        let occurredAt: Date?
        let scanID: UUID?

        init(clientRef: String, cardKey: String, quantityDelta: Int, finish: Finish? = nil, defaultFinish: Finish? = nil, condition: String? = nil, occurredAt: Date? = nil, scanID: UUID? = nil) {
            self.clientRef = clientRef
            self.cardKey = cardKey
            self.quantityDelta = quantityDelta
            self.finish = finish
            self.defaultFinish = defaultFinish
            self.condition = condition
            self.occurredAt = occurredAt
            self.scanID = scanID
        }
    }

    nonisolated struct Undo: Hashable, Sendable {
        let clientRef: String
        /// The `client_ref` of the applied row being reversed.
        let undoOf: String
        let occurredAt: Date?
        let scanID: UUID?

        init(clientRef: String, undoOf: String, occurredAt: Date? = nil, scanID: UUID? = nil) {
            self.clientRef = clientRef
            self.undoOf = undoOf
            self.occurredAt = occurredAt
            self.scanID = scanID
        }
    }

    var clientRef: String {
        switch self {
        case .delta(let delta): delta.clientRef
        case .undo(let undo): undo.clientRef
        }
    }

    private enum CodingKeys: String, CodingKey {
        case clientRef = "client_ref"
        case undoOf = "undo_of"
        case cardKey = "card_key"
        case finish
        case defaultFinish = "default_finish"
        case quantityDelta = "quantity_delta"
        case occurredAt = "occurred_at"
        case scanID = "scan_id"
        case condition
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let clientRef = try container.decode(String.self, forKey: .clientRef)
        let occurredAt = try container.decodeIfPresent(Date.self, forKey: .occurredAt)
        let scanID = try container.decodeIfPresent(UUID.self, forKey: .scanID)
        if let undoOf = try container.decodeIfPresent(String.self, forKey: .undoOf) {
            self = .undo(Undo(clientRef: clientRef, undoOf: undoOf, occurredAt: occurredAt, scanID: scanID))
        } else {
            self = .delta(Delta(
                clientRef: clientRef,
                cardKey: try container.decode(String.self, forKey: .cardKey),
                quantityDelta: try container.decode(Int.self, forKey: .quantityDelta),
                finish: try container.decodeIfPresent(Finish.self, forKey: .finish),
                defaultFinish: try container.decodeIfPresent(Finish.self, forKey: .defaultFinish),
                condition: try container.decodeIfPresent(String.self, forKey: .condition),
                occurredAt: occurredAt,
                scanID: scanID
            ))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .delta(let delta):
            try container.encode(delta.clientRef, forKey: .clientRef)
            try container.encode(delta.cardKey, forKey: .cardKey)
            try container.encode(delta.quantityDelta, forKey: .quantityDelta)
            // `finish: null` is meaningful: it asks the server to derive it.
            try container.encode(delta.finish, forKey: .finish)
            try container.encodeIfPresent(delta.defaultFinish, forKey: .defaultFinish)
            try container.encodeIfPresent(delta.condition, forKey: .condition)
            try container.encodeIfPresent(delta.occurredAt, forKey: .occurredAt)
            try container.encodeIfPresent(delta.scanID, forKey: .scanID)
        case .undo(let undo):
            try container.encode(undo.clientRef, forKey: .clientRef)
            try container.encode(undo.undoOf, forKey: .undoOf)
            try container.encodeIfPresent(undo.occurredAt, forKey: .occurredAt)
            try container.encodeIfPresent(undo.scanID, forKey: .scanID)
        }
    }
}

nonisolated struct LedgerSyncRequest: Hashable, Sendable, Codable {
    /// The server accepts at most this many items per request.
    static let maximumItems = 100

    let device: String
    let items: [LedgerSyncItem]

    init(device: String, items: [LedgerSyncItem]) {
        self.device = device
        self.items = items
    }
}

/// The per-item outcome of a sync. Every case but `applied` is terminal; an
/// unrecognised status decodes as `.unknown` so a new server value cannot
/// fail the whole response.
nonisolated enum LedgerItemStatus: Hashable, Sendable, Codable {
    case applied
    case duplicate
    case duplicateMismatch
    case unknownCard
    case wouldGoNegative
    case nothingToUndo
    case invalid
    case unknown(String)

    var rawValue: String {
        switch self {
        case .applied: "applied"
        case .duplicate: "duplicate"
        case .duplicateMismatch: "duplicate_mismatch"
        case .unknownCard: "unknown_card"
        case .wouldGoNegative: "would_go_negative"
        case .nothingToUndo: "nothing_to_undo"
        case .invalid: "invalid"
        case .unknown(let raw): raw
        }
    }

    init(rawValue: String) {
        switch rawValue {
        case "applied": self = .applied
        case "duplicate": self = .duplicate
        case "duplicate_mismatch": self = .duplicateMismatch
        case "unknown_card": self = .unknownCard
        case "would_go_negative": self = .wouldGoNegative
        case "nothing_to_undo": self = .nothingToUndo
        case "invalid": self = .invalid
        default: self = .unknown(rawValue)
        }
    }

    init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated struct LedgerItemResult: Hashable, Sendable, Codable {
    let clientRef: String
    let status: LedgerItemStatus
    let cardID: String?
    let finish: Finish?
    let ledgerID: Int?
    let finishWarning: String?

    init(clientRef: String, status: LedgerItemStatus, cardID: String? = nil, finish: Finish? = nil, ledgerID: Int? = nil, finishWarning: String? = nil) {
        self.clientRef = clientRef
        self.status = status
        self.cardID = cardID
        self.finish = finish
        self.ledgerID = ledgerID
        self.finishWarning = finishWarning
    }

    private enum CodingKeys: String, CodingKey {
        case clientRef = "client_ref"
        case status, finish
        case cardID = "card_id"
        case ledgerID = "ledger_id"
        case finishWarning = "finish_warning"
    }
}

nonisolated struct LedgerSyncResponse: Hashable, Sendable, Codable {
    let results: [LedgerItemResult]

    init(results: [LedgerItemResult]) {
        self.results = results
    }
}

// MARK: - PUT /api/scans/batches/{id}

/// `PUT /api/scans/batches/{id}`: the batch's own metadata. Purpose and
/// finish are strings on the wire so this layer does not depend on the
/// batch types another item defines.
nonisolated struct BatchUpload: Hashable, Sendable, Codable {
    let id: UUID
    let startedAt: Date
    let label: String
    let purpose: String
    let product: String?
    let defaultFinish: Finish?
    let trainingQuality: String?
    let deviceModel: String
    let systemVersion: String
    let appVersion: String
    let calibrationHash: String?

    init(id: UUID, startedAt: Date, label: String, purpose: String, product: String? = nil, defaultFinish: Finish? = nil, trainingQuality: String? = nil, deviceModel: String, systemVersion: String, appVersion: String, calibrationHash: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.label = label
        self.purpose = purpose
        self.product = product
        self.defaultFinish = defaultFinish
        self.trainingQuality = trainingQuality
        self.deviceModel = deviceModel
        self.systemVersion = systemVersion
        self.appVersion = appVersion
        self.calibrationHash = calibrationHash
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, purpose, product
        case startedAt = "started_at"
        case defaultFinish = "default_finish"
        case trainingQuality = "training_quality"
        case deviceModel = "device_model"
        case systemVersion = "system_version"
        case appVersion = "app_version"
        case calibrationHash = "calibration_hash"
    }
}

/// What the server says about an upserted resource.
nonisolated enum UpsertOutcome: Hashable, Sendable {
    case created
    case updated
    case unchanged
}

// MARK: - PUT /api/scans/{id}

/// The winning oriented descriptor: feature print as base64 Float32 bytes,
/// hashes as hex strings, and the calibration hash of the embedding space.
nonisolated struct DescriptorUpload: Hashable, Sendable, Codable {
    nonisolated enum Orientation: String, Hashable, Sendable, Codable {
        case upright
        case upsideDown
    }

    let calibrationHash: String
    let orientation: Orientation
    let featurePrint: String
    let hashes: [String: String]

    init(calibrationHash: String, orientation: Orientation, featurePrint: String, hashes: [String: String] = [:]) {
        self.calibrationHash = calibrationHash
        self.orientation = orientation
        self.featurePrint = featurePrint
        self.hashes = hashes
    }

    private enum CodingKeys: String, CodingKey {
        case calibrationHash = "calibration_hash"
        case orientation, hashes
        case featurePrint = "feature_print"
    }
}

/// A code the OCR read (literally or via a parser alternative), the card it
/// names and how similar the photo is to that card's reference.
nonisolated struct CodeAlternativeUpload: Hashable, Sendable, Codable {
    let code: String
    let cardRef: String?
    let referenceSimilarity: Double?
    let isLiteral: Bool

    init(code: String, cardRef: String?, referenceSimilarity: Double?, isLiteral: Bool) {
        self.code = code
        self.cardRef = cardRef
        self.referenceSimilarity = referenceSimilarity
        self.isLiteral = isLiteral
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case cardRef = "card_ref"
        case referenceSimilarity = "reference_similarity"
        case isLiteral = "literal"
    }
}

nonisolated struct ReferenceSimilarityUpload: Hashable, Sendable, Codable {
    let cardRef: String
    let similarity: Double

    init(cardRef: String, similarity: Double) {
        self.cardRef = cardRef
        self.similarity = similarity
    }

    private enum CodingKeys: String, CodingKey {
        case cardRef = "card_ref"
        case similarity
    }
}

nonisolated struct EngineStampUpload: Hashable, Sendable, Codable {
    let packageVersion: String
    let calibrationHash: String
    let platform: String
    let osVersion: String
    let overlayVersion: Int?
    let policyVersion: Int?

    init(packageVersion: String, calibrationHash: String, platform: String, osVersion: String, overlayVersion: Int? = nil, policyVersion: Int? = nil) {
        self.packageVersion = packageVersion
        self.calibrationHash = calibrationHash
        self.platform = platform
        self.osVersion = osVersion
        self.overlayVersion = overlayVersion
        self.policyVersion = policyVersion
    }

    private enum CodingKeys: String, CodingKey {
        case platform
        case packageVersion = "package_version"
        case calibrationHash = "calibration_hash"
        case osVersion = "os_version"
        case overlayVersion = "overlay_version"
        case policyVersion = "policy_version"
    }
}

/// `PUT /api/scans/{id}`. `record` is the scan's own JSON, forwarded as it
/// is stored on the phone minus every `imageURL`; see `ScanUpload.record(from:)`.
nonisolated struct ScanUpload: Hashable, Sendable, Codable {
    /// Keys stripped from the record before it leaves the phone (Decision 15).
    static let strippedRecordKeys: Set<String> = ["imageURL"]

    let id: UUID
    let batchID: UUID
    let record: JSONValue
    let descriptor: DescriptorUpload?
    let referenceSimilarity: Double?
    let bestOtherReference: ReferenceSimilarityUpload?
    let codeAlternatives: [CodeAlternativeUpload]
    /// Hash of (calibration hash, platform, overlay/package version, analysedAt):
    /// a changed stamp makes the server refresh its analysis columns.
    let analysisStamp: String
    let engine: EngineStampUpload?

    init(id: UUID, batchID: UUID, record: JSONValue, descriptor: DescriptorUpload?, referenceSimilarity: Double? = nil, bestOtherReference: ReferenceSimilarityUpload? = nil, codeAlternatives: [CodeAlternativeUpload] = [], analysisStamp: String, engine: EngineStampUpload?) {
        self.id = id
        self.batchID = batchID
        self.record = record.removingKeys(Self.strippedRecordKeys)
        self.descriptor = descriptor
        self.referenceSimilarity = referenceSimilarity
        self.bestOtherReference = bestOtherReference
        self.codeAlternatives = codeAlternatives
        self.analysisStamp = analysisStamp
        self.engine = engine
    }

    /// The record's stored JSON with every `imageURL` removed.
    static func record(from record: ScanRecord) throws -> JSONValue {
        try JSONValue(encoding: record, encoder: .scanStore).removingKeys(strippedRecordKeys)
    }

    private enum CodingKeys: String, CodingKey {
        case id, record, descriptor, engine
        case batchID = "batch_id"
        case referenceSimilarity = "reference_similarity"
        case bestOtherReference = "best_other_reference"
        case codeAlternatives = "code_alternatives"
        case analysisStamp = "analysis_stamp"
    }
}

/// The server's answer to a scan upload.
nonisolated struct ScanUploadReceipt: Hashable, Sendable {
    let outcome: UpsertOutcome
    /// `true` when the batch is not on the server yet and the record was not stored.
    let isDeferred: Bool
    /// Which derived columns the server refreshed, e.g. `["analysis"]`.
    let updated: [String]

    init(outcome: UpsertOutcome, isDeferred: Bool = false, updated: [String] = []) {
        self.outcome = outcome
        self.isDeferred = isDeferred
        self.updated = updated
    }

    nonisolated struct Body: Decodable, Sendable {
        let status: String?
        let deferred: Bool?
        let updated: [String]?
    }
}

// MARK: - PUT /api/scans/{id}/{kind}

nonisolated enum AssetKind: String, Hashable, Sendable, Codable, CaseIterable {
    case photoSmall = "photo_small"
    case canvas
    case photo

    /// The server's body cap for this kind (ADR-002 §5.2).
    var maximumBytes: Int {
        switch self {
        case .photoSmall, .canvas: 400 * 1024
        case .photo: 3 * 1024 * 1024
        }
    }
}

nonisolated struct AssetReceipt: Hashable, Sendable {
    let outcome: UpsertOutcome
    let sha256: String

    init(outcome: UpsertOutcome, sha256: String) {
        self.outcome = outcome
        self.sha256 = sha256
    }
}

// MARK: - GET /api/holdings, GET /api/ledger

nonisolated struct HoldingsSummary: Hashable, Sendable, Codable {
    let distinctCards: Int
    let totalCards: Int
    let marketValue: Double?
    let ledgerEvents: Int?

    init(distinctCards: Int, totalCards: Int, marketValue: Double? = nil, ledgerEvents: Int? = nil) {
        self.distinctCards = distinctCards
        self.totalCards = totalCards
        self.marketValue = marketValue
        self.ledgerEvents = ledgerEvents
    }

    private enum CodingKeys: String, CodingKey {
        case distinctCards = "distinct_cards"
        case totalCards = "total_cards"
        case marketValue = "market_value"
        case ledgerEvents = "ledger_events"
    }
}

nonisolated struct Holding: Hashable, Sendable, Codable, Identifiable {
    let cardID: String
    let name: String?
    let setCode: String?
    let rarity: String?
    let type: String?
    let normal: Int
    let foil: Int

    var id: String { cardID }
    var total: Int { normal + foil }

    init(cardID: String, name: String? = nil, setCode: String? = nil, rarity: String? = nil, type: String? = nil, normal: Int, foil: Int) {
        self.cardID = cardID
        self.name = name
        self.setCode = setCode
        self.rarity = rarity
        self.type = type
        self.normal = normal
        self.foil = foil
    }

    private enum CodingKeys: String, CodingKey {
        case cardID = "card_id"
        case name, rarity, type, normal, foil
        case setCode = "set_code"
    }
}

nonisolated struct HoldingsResponse: Hashable, Sendable, Codable {
    let summary: HoldingsSummary
    let items: [Holding]

    init(summary: HoldingsSummary, items: [Holding]) {
        self.summary = summary
        self.items = items
    }
}

nonisolated struct LedgerEvent: Hashable, Sendable, Codable, Identifiable {
    let id: Int
    let cardID: String
    let finish: Finish
    let quantityDelta: Int
    let condition: String?
    let source: String?
    let batchID: String?
    let clientRef: String?
    let undoOf: String?
    let scanID: String?
    let occurredAt: String?
    let createdAt: String?

    private enum CodingKeys: String, CodingKey {
        case id, finish, condition, source
        case cardID = "card_id"
        case quantityDelta = "quantity_delta"
        case batchID = "batch_id"
        case clientRef = "client_ref"
        case undoOf = "undo_of"
        case scanID = "scan_id"
        case occurredAt = "occurred_at"
        case createdAt = "created_at"
    }
}

/// `GET /api/ledger?since_id=`: rows newer than `since_id`, ascending, and
/// the ledger head (the highest row id) for the next request.
nonisolated struct LedgerPage: Hashable, Sendable, Codable {
    let items: [LedgerEvent]
    let head: Int?

    init(items: [LedgerEvent], head: Int?) {
        self.items = items
        self.head = head
    }
}

// MARK: - GET /api/catalog, GET /api/prices/latest

/// A vault row as the server streams it. Field names follow the bundled
/// `CardVault.json` (camelCase), which is the shape S8 reproduces; the image
/// and cardmarket URLs are not part of it.
nonisolated struct CatalogCard: Hashable, Sendable, Codable, Identifiable {
    let code: String
    let name: String
    let set: String
    let setName: String
    let rarity: String
    let type: String?
    let supertype: String?
    let domains: [String]
    let energy: Int?
    let might: Int?
    let power: Int?
    let text: String?
    let flavor: String?
    let tags: [String]
    let tcgplayerID: Int?
    let marketNormal: Double?
    let marketFoil: Double?
    let hasNormal: Bool
    let hasFoil: Bool
    let promo: Bool
    let banned: Bool
    let nameKey: String?
    let artGroup: String?

    var id: String { code }

    private enum CodingKeys: String, CodingKey {
        case code, name, set, setName, rarity, type, supertype, domains, energy, might, power, text, flavor, tags
        case tcgplayerID, marketNormal, marketFoil, hasNormal, hasFoil, promo, banned
        case nameKey = "name_key"
        case artGroup = "art_group"
    }
}

nonisolated struct CatalogResponse: Hashable, Sendable, Codable {
    let asOf: String
    let catalogVersion: String
    let cards: [CatalogCard]

    private enum CodingKeys: String, CodingKey {
        case cards
        case asOf = "as_of"
        case catalogVersion = "catalog_version"
    }
}

nonisolated struct PriceQuote: Hashable, Sendable, Codable {
    let normal: Double?
    let foil: Double?

    init(normal: Double?, foil: Double?) {
        self.normal = normal
        self.foil = foil
    }
}

/// `GET /api/prices/latest`: one day's market prices keyed by vault code.
nonisolated struct PriceSheetResponse: Hashable, Sendable, Codable {
    let day: String
    let items: [String: PriceQuote]

    init(day: String, items: [String: PriceQuote]) {
        self.day = day
        self.items = items
    }
}

// MARK: - Learning artefacts

nonisolated struct OverlayMeta: Hashable, Sendable, Codable {
    let version: Int
    let calibrationHash: String
    let exemplarCount: Int
    let builtAt: String?
    let etag: String?
    let policyVersion: Int?

    init(version: Int, calibrationHash: String, exemplarCount: Int, builtAt: String? = nil, etag: String? = nil, policyVersion: Int? = nil) {
        self.version = version
        self.calibrationHash = calibrationHash
        self.exemplarCount = exemplarCount
        self.builtAt = builtAt
        self.etag = etag
        self.policyVersion = policyVersion
    }

    private enum CodingKeys: String, CodingKey {
        case version, etag
        case calibrationHash = "calibration_hash"
        case exemplarCount = "exemplar_count"
        case builtAt = "built_at"
        case policyVersion = "policy_version"
    }
}

/// One exemplar as the overlay wire format carries it (ADR-002 §7).
nonisolated struct OverlayExemplar: Hashable, Sendable, Codable {
    let id: Int
    let artGroup: String
    let featurePrint: String
    let scanID: String
    let batchID: String
    let admittedAt: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case artGroup = "art_group"
        case featurePrint = "feature_print"
        case scanID = "scan_id"
        case batchID = "batch_id"
        case admittedAt = "admitted_at"
    }
}

/// `GET /api/learning/overlay/changes?since_version=&calibration=`.
nonisolated struct OverlayChanges: Hashable, Sendable, Codable {
    let sinceVersion: Int
    let version: Int
    let added: [OverlayExemplar]
    let revoked: [Int]

    private enum CodingKeys: String, CodingKey {
        case version, added, revoked
        case sinceVersion = "since_version"
    }
}

/// `GET /api/learning/policy`: the version is read here, the document is
/// kept as bytes for `LearningPolicy` (a package type) to decode.
nonisolated struct PolicyDocument: Hashable, Sendable {
    let version: Int
    let json: Data

    init(version: Int, json: Data) {
        self.version = version
        self.json = json
    }

    nonisolated struct Header: Decodable, Sendable {
        let version: Int
    }
}

/// `GET /api/learning/stats` (ADR-002, decision 9): how well the confident
/// tier is doing, as the server measures it over random audits alone.
/// Spot-checks are counted separately and never move the bound. Every field
/// but `random_audits` is optional so an older or partial server still decodes.
nonisolated struct LearningStats: Hashable, Sendable, Codable {
    /// The 95 % Wilson lower bound of auto-accept precision; `nil` until the
    /// first random audit exists.
    let wilsonLowerBound: Double?
    /// The confidence level the bound was computed at (0.95).
    let confidenceLevel: Double?
    /// Random audits recorded so far; the policy's audit rate switches on it.
    let randomAudits: Int
    let randomAuditsWrong: Int?
    /// Wrong audits nobody has resolved yet; one of these makes the tier unhealthy.
    let unresolvedWrongAudits: Int?
    let spotChecks: Int?
    let auditsBySource: [String: Int]?
    let humanLabels: Int?
    /// Distinct sittings (batches) with human labels; phase 2 waits for three.
    let sittings: Int?
    let exemplars: Int?
    let exemplarsBySet: [String: Int]?
    let overlayVersion: Int?
    let policyVersion: Int?

    init(
        wilsonLowerBound: Double? = nil,
        confidenceLevel: Double? = nil,
        randomAudits: Int = 0,
        randomAuditsWrong: Int? = nil,
        unresolvedWrongAudits: Int? = nil,
        spotChecks: Int? = nil,
        auditsBySource: [String: Int]? = nil,
        humanLabels: Int? = nil,
        sittings: Int? = nil,
        exemplars: Int? = nil,
        exemplarsBySet: [String: Int]? = nil,
        overlayVersion: Int? = nil,
        policyVersion: Int? = nil
    ) {
        self.wilsonLowerBound = wilsonLowerBound
        self.confidenceLevel = confidenceLevel
        self.randomAudits = randomAudits
        self.randomAuditsWrong = randomAuditsWrong
        self.unresolvedWrongAudits = unresolvedWrongAudits
        self.spotChecks = spotChecks
        self.auditsBySource = auditsBySource
        self.humanLabels = humanLabels
        self.sittings = sittings
        self.exemplars = exemplars
        self.exemplarsBySet = exemplarsBySet
        self.overlayVersion = overlayVersion
        self.policyVersion = policyVersion
    }

    /// The bound the tier must keep to count as healthy (ADR-002, decision 9).
    static let healthyLowerBound = 0.97

    /// Healthy while the bound is at least 97 % and no wrong audit is
    /// unresolved; `nil` before any random audit exists.
    var isHealthy: Bool? {
        guard let wilsonLowerBound else { return nil }
        return wilsonLowerBound >= Self.healthyLowerBound && (unresolvedWrongAudits ?? 0) == 0
    }

    private enum CodingKeys: String, CodingKey {
        case exemplars, sittings
        case wilsonLowerBound = "wilson_lower_bound"
        case confidenceLevel = "confidence_level"
        case randomAudits = "random_audits"
        case randomAuditsWrong = "random_audits_wrong"
        case unresolvedWrongAudits = "unresolved_wrong_audits"
        case spotChecks = "spot_checks"
        case auditsBySource = "audits_by_source"
        case humanLabels = "human_labels"
        case exemplarsBySet = "exemplars_by_set"
        case overlayVersion = "overlay_version"
        case policyVersion = "policy_version"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            wilsonLowerBound: try container.decodeIfPresent(Double.self, forKey: .wilsonLowerBound),
            confidenceLevel: try container.decodeIfPresent(Double.self, forKey: .confidenceLevel),
            randomAudits: try container.decodeIfPresent(Int.self, forKey: .randomAudits) ?? 0,
            randomAuditsWrong: try container.decodeIfPresent(Int.self, forKey: .randomAuditsWrong),
            unresolvedWrongAudits: try container.decodeIfPresent(Int.self, forKey: .unresolvedWrongAudits),
            spotChecks: try container.decodeIfPresent(Int.self, forKey: .spotChecks),
            auditsBySource: try container.decodeIfPresent([String: Int].self, forKey: .auditsBySource),
            humanLabels: try container.decodeIfPresent(Int.self, forKey: .humanLabels),
            sittings: try container.decodeIfPresent(Int.self, forKey: .sittings),
            exemplars: try container.decodeIfPresent(Int.self, forKey: .exemplars),
            exemplarsBySet: try container.decodeIfPresent([String: Int].self, forKey: .exemplarsBySet),
            overlayVersion: try container.decodeIfPresent(Int.self, forKey: .overlayVersion),
            policyVersion: try container.decodeIfPresent(Int.self, forKey: .policyVersion)
        )
    }
}

/// `POST /api/learning/evaluations`. The per-case payload belongs to the
/// evaluation item and travels as it was written.
nonisolated struct EvaluationRunUpload: Hashable, Sendable, Codable {
    let id: UUID
    let ranAt: Date
    let device: String?
    let batchID: UUID?
    let excludedBatch: UUID?
    let exemplarCountUsed: Int?
    let overlayVersion: Int?
    let policyVersion: Int?
    let engine: EngineStampUpload?
    let cases: JSONValue

    init(id: UUID, ranAt: Date, device: String?, batchID: UUID?, excludedBatch: UUID?, exemplarCountUsed: Int?, overlayVersion: Int?, policyVersion: Int?, engine: EngineStampUpload?, cases: JSONValue) {
        self.id = id
        self.ranAt = ranAt
        self.device = device
        self.batchID = batchID
        self.excludedBatch = excludedBatch
        self.exemplarCountUsed = exemplarCountUsed
        self.overlayVersion = overlayVersion
        self.policyVersion = policyVersion
        self.engine = engine
        self.cases = cases
    }

    private enum CodingKeys: String, CodingKey {
        case id, device, engine, cases
        case ranAt = "ran_at"
        case batchID = "batch_id"
        case excludedBatch = "excluded_batch"
        case exemplarCountUsed = "exemplar_count_used"
        case overlayVersion = "overlay_version"
        case policyVersion = "policy_version"
    }
}

nonisolated struct EvaluationReceipt: Hashable, Sendable, Codable {
    let id: UUID

    init(id: UUID) {
        self.id = id
    }
}

// MARK: - Decks

nonisolated enum DeckSlot: Hashable, Sendable, Codable, CaseIterable {
    case legend
    case champion
    case rune
    case battlefield
    case main
    case sideboard
    case unknown(String)

    static let allCases: [DeckSlot] = [.legend, .champion, .rune, .battlefield, .main, .sideboard]

    var rawValue: String {
        switch self {
        case .legend: "legend"
        case .champion: "champion"
        case .rune: "rune"
        case .battlefield: "battlefield"
        case .main: "main"
        case .sideboard: "sideboard"
        case .unknown(let raw): raw
        }
    }

    init(rawValue: String) {
        self = Self.allCases.first { $0.rawValue == rawValue } ?? .unknown(rawValue)
    }

    init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated struct DeckSummary: Hashable, Sendable, Codable, Identifiable {
    let id: Int
    let name: String
    let format: String
    let notes: String?
    let cardCount: Int
    let shortCount: Int?
    let createdAt: String?
    let updatedAt: String?

    init(id: Int, name: String, format: String, notes: String? = nil, cardCount: Int, shortCount: Int? = nil, createdAt: String? = nil, updatedAt: String? = nil) {
        self.id = id
        self.name = name
        self.format = format
        self.notes = notes
        self.cardCount = cardCount
        self.shortCount = shortCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, format, notes
        case cardCount = "card_count"
        case shortCount = "short_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

nonisolated struct DecksResponse: Hashable, Sendable, Codable {
    let items: [DeckSummary]

    init(items: [DeckSummary]) {
        self.items = items
    }
}

/// A deck slot entry with the server's ownership arithmetic. The server row
/// also carries `image_url`; it is not read.
nonisolated struct DeckCard: Hashable, Sendable, Codable {
    let cardID: String
    let slot: DeckSlot
    let quantity: Int
    let name: String
    let setCode: String?
    let rarity: String?
    let type: String?
    let supertype: String?
    let domains: [String]
    let energy: Int?
    let owned: Int
    let usedElsewhere: Int
    let available: Int
    let short: Int

    init(cardID: String, slot: DeckSlot, quantity: Int, name: String, setCode: String? = nil, rarity: String? = nil, type: String? = nil, supertype: String? = nil, domains: [String] = [], energy: Int? = nil, owned: Int, usedElsewhere: Int, available: Int, short: Int) {
        self.cardID = cardID
        self.slot = slot
        self.quantity = quantity
        self.name = name
        self.setCode = setCode
        self.rarity = rarity
        self.type = type
        self.supertype = supertype
        self.domains = domains
        self.energy = energy
        self.owned = owned
        self.usedElsewhere = usedElsewhere
        self.available = available
        self.short = short
    }

    private enum CodingKeys: String, CodingKey {
        case slot, quantity, name, rarity, type, supertype, domains, energy, owned, available, short
        case cardID = "card_id"
        case setCode = "set_code"
        case usedElsewhere = "used_elsewhere"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cardID = try container.decode(String.self, forKey: .cardID)
        slot = try container.decode(DeckSlot.self, forKey: .slot)
        quantity = try container.decode(Int.self, forKey: .quantity)
        name = try container.decode(String.self, forKey: .name)
        setCode = try container.decodeIfPresent(String.self, forKey: .setCode)
        rarity = try container.decodeIfPresent(String.self, forKey: .rarity)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        supertype = try container.decodeIfPresent(String.self, forKey: .supertype)
        // The server stores domains as a JSON array but has historically sent
        // it as the raw column string; accept both.
        if let list = try? container.decodeIfPresent([String].self, forKey: .domains) {
            domains = list
        } else if let raw = try container.decodeIfPresent(String.self, forKey: .domains),
                  let list = try? JSONDecoder().decode([String].self, from: Data(raw.utf8)) {
            domains = list
        } else {
            domains = []
        }
        energy = try container.decodeIfPresent(Int.self, forKey: .energy)
        owned = try container.decode(Int.self, forKey: .owned)
        usedElsewhere = try container.decodeIfPresent(Int.self, forKey: .usedElsewhere) ?? 0
        available = try container.decodeIfPresent(Int.self, forKey: .available) ?? (owned - usedElsewhere)
        short = try container.decodeIfPresent(Int.self, forKey: .short) ?? max(0, quantity - available)
    }
}

nonisolated struct DeckIssue: Hashable, Sendable, Codable {
    let code: String
    let message: String?
    let severity: String?
    let cardID: String?

    private enum CodingKeys: String, CodingKey {
        case code, message, severity
        case cardID = "card_id"
    }
}

nonisolated struct DeckDetail: Hashable, Sendable, Codable, Identifiable {
    let id: Int
    let name: String
    let format: String
    let notes: String?
    let cards: [DeckCard]
    let cardCount: Int
    let shortCount: Int
    let validation: [DeckIssue]
    let createdAt: String?
    let updatedAt: String?

    init(id: Int, name: String, format: String, notes: String? = nil, cards: [DeckCard], cardCount: Int, shortCount: Int, validation: [DeckIssue] = [], createdAt: String? = nil, updatedAt: String? = nil) {
        self.id = id
        self.name = name
        self.format = format
        self.notes = notes
        self.cards = cards
        self.cardCount = cardCount
        self.shortCount = shortCount
        self.validation = validation
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, format, notes, cards, validation
        case cardCount = "card_count"
        case shortCount = "short_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        format = try container.decode(String.self, forKey: .format)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        cards = try container.decodeIfPresent([DeckCard].self, forKey: .cards) ?? []
        cardCount = try container.decodeIfPresent(Int.self, forKey: .cardCount) ?? cards.reduce(0) { $0 + $1.quantity }
        shortCount = try container.decodeIfPresent(Int.self, forKey: .shortCount) ?? cards.reduce(0) { $0 + $1.short }
        validation = try container.decodeIfPresent([DeckIssue].self, forKey: .validation) ?? []
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    }
}

/// `PUT /api/decks/{id}/cards`: sets a card's quantity in one slot (0 removes it).
nonisolated struct DeckCardChange: Hashable, Sendable, Codable {
    let cardID: String
    let slot: DeckSlot
    let quantity: Int

    init(cardID: String, slot: DeckSlot, quantity: Int) {
        self.cardID = cardID
        self.slot = slot
        self.quantity = quantity
    }

    private enum CodingKeys: String, CodingKey {
        case slot, quantity
        case cardID = "card_id"
    }
}

// MARK: - Conditional responses

/// A conditionally fetched resource and the validator (the ETag, bare) that
/// the next request should send as `If-None-Match`.
nonisolated struct Versioned<Value: Hashable & Sendable>: Hashable, Sendable {
    let value: Value
    let validator: String?

    init(value: Value, validator: String?) {
        self.value = value
        self.validator = validator
    }
}

// MARK: - Coding

nonisolated extension JSONEncoder {
    /// The wire encoder: ISO 8601 dates with fractional seconds, stable key order.
    static var server: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(.iso8601.year().month().day().timeZone(separator: .omitted).time(includingFractionalSeconds: true).dateTimeSeparator(.standard)))
        }
        return encoder
    }

    /// The encoder `FileScanStore` writes `scans.json` with, so a forwarded
    /// record is byte-for-byte what `summarize-scans.py` reads.
    static var scanStore: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

nonisolated extension JSONDecoder {
    /// The wire decoder: ISO 8601 dates with or without fractional seconds.
    static var server: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: .iso8601.year().month().day().timeZone(separator: .omitted).time(includingFractionalSeconds: true).dateTimeSeparator(.standard)) {
                return date
            }
            if let date = try? Date(text, strategy: .iso8601) {
                return date
            }
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 date: \(text)"))
        }
        return decoder
    }
}
