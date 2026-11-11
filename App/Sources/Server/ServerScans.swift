import Foundation

/// The server's copy of every device's scans (ADR-003), read back so the Mac
/// can import a batch an iPhone captured and review it. A scan waiting for a
/// person is on the server with its record and full photo (`UploadTiers`).
nonisolated protocol ServerScanReading: Sendable {
    /// `GET /api/scans/batches`, every page, newest first.
    func scanBatches() async throws(ServerError) -> [ServerScanBatch]
    /// `GET /api/scans?batch_id=`, every page: the batch's stored scans.
    func scanIDs(inBatch id: UUID) async throws(ServerError) -> [UUID]
    /// `GET /api/scans/{id}`: the record as the capturing device uploaded it.
    func scan(id: UUID) async throws(ServerError) -> ServerScan
    /// `GET /api/scans/{id}/{kind}`: one stored JPEG.
    func asset(_ kind: AssetKind, scanID: UUID) async throws(ServerError) -> Data
}

/// One row of `GET /api/scans/batches`: the batch as its device uploaded it
/// (`BatchUpload`), plus how many of its scans the server holds.
nonisolated struct ServerScanBatch: Hashable, Sendable, Codable, Identifiable {
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
    let scanCount: Int
    let decidedCount: Int

    init(id: UUID, startedAt: Date, label: String = "", purpose: String, product: String? = nil, defaultFinish: Finish? = nil, trainingQuality: String? = nil, deviceModel: String, systemVersion: String, appVersion: String, scanCount: Int, decidedCount: Int) {
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
        self.scanCount = scanCount
        self.decidedCount = decidedCount
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, purpose, product
        case startedAt = "started_at"
        case defaultFinish = "default_finish"
        case trainingQuality = "training_quality"
        case deviceModel = "device_model"
        case systemVersion = "system_version"
        case appVersion = "app_version"
        case scanCount = "scan_count"
        case decidedCount = "decided_count"
    }

    var displayName: String {
        label.isEmpty ? startedAt.formatted(date: .abbreviated, time: .shortened) : label
    }

    var pendingCount: Int {
        max(scanCount - decidedCount, 0)
    }
}

/// `GET /api/scans/{id}`, the parts an import needs: the record exactly as
/// the device sent it (without image URLs, ADR-002 decision 15) and which
/// JPEGs the server holds for it.
nonisolated struct ServerScan: Hashable, Sendable, Codable {
    nonisolated struct Asset: Hashable, Sendable, Codable {
        let kind: String
        let bytes: Int?
    }

    let id: UUID
    let batchID: UUID
    let record: JSONValue
    let assets: [Asset]

    init(id: UUID, batchID: UUID, record: JSONValue, assets: [Asset]) {
        self.id = id
        self.batchID = batchID
        self.record = record
        self.assets = assets
    }

    private enum CodingKeys: String, CodingKey {
        case id, record, assets
        case batchID = "batch_id"
    }

    func has(_ kind: AssetKind) -> Bool {
        assets.contains { $0.kind == kind.rawValue }
    }
}

/// A page of `GET /api/scans/batches` or `GET /api/scans`.
nonisolated struct ServerPage<Item: Decodable & Sendable>: Decodable, Sendable {
    let total: Int
    let items: [Item]
}

/// A row of `GET /api/scans`; only the id is read.
nonisolated struct ServerScanSummary: Decodable, Sendable {
    let id: UUID
}
