import Foundation
import RiftboundRecognizer

/// Copies a batch another device captured from the server into this device's
/// scan store, so it is reviewed here like a batch scanned here (ADR-003): the
/// iPhone shoots through its close-focus lens and uploads every scan that
/// waits for a person with its full photo, and the Mac imports and reviews.
///
/// Records keep their ids and decision logs, so a verdict given here goes
/// back as the next decision of the same scan, and the server refuses a
/// stale one from either device (ADR-002 §5.5). An import that stops part
/// way resumes: scans already in the store are skipped.
nonisolated struct ServerBatchImporter: Sendable {
    /// Why a scan could not be imported. The rest of the batch still is.
    enum Failure: Error, Hashable {
        case noPhoto(UUID)
        case unreadableRecord(UUID, String)
    }

    struct Outcome: Hashable, Sendable {
        let batch: ScanBatch
        let imported: Int
        /// Scans already in the store from an earlier attempt.
        let alreadyHere: Int
        /// Scans the server holds no photo for, or whose record did not decode.
        let skipped: [Failure]
    }

    let server: any ServerScanReading
    let store: any ScanStoring
    let directory: CardDirectory
    /// This device's reference index. The server does not keep the capturing
    /// device's, and the summary is informational only.
    let index: IndexSummary

    /// Imports `remote`, reporting `(done, total)` after each scan.
    func importBatch(_ remote: ServerScanBatch, progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> Outcome {
        let batch = Self.batch(from: remote, index: index)
        let local = try await store.batches().first { $0.id == batch.id }
        if local == nil {
            try await store.save(batch)
        }
        let present = Set(try await store.records(in: batch.id).map(\.id.rawValue))
        let ids = try await server.scanIDs(inBatch: remote.id)
        let held = store as? any ServerHeldMarking
        try await held?.markBatchHeldByServer(batch.id)

        var imported = 0
        var skipped: [Failure] = []
        for (offset, id) in ids.enumerated() where !present.contains(id) {
            switch try await importScan(id, marking: held) {
            case .success: imported += 1
            case .failure(let failure): skipped.append(failure)
            }
            await progress(offset + 1, ids.count)
        }
        await progress(ids.count, ids.count)
        return Outcome(batch: local ?? batch, imported: imported, alreadyHere: present.count, skipped: skipped)
    }

    /// One scan: its record, its best photo and, when the server has it, the
    /// rectified canvas. Transport failures throw and stop the import.
    private func importScan(_ id: UUID, marking held: (any ServerHeldMarking)?) async throws -> Result<Void, Failure> {
        let scan = try await server.scan(id: id)
        let record: ScanRecord
        do {
            record = try Self.record(from: scan.record, directory: directory)
        } catch {
            return .failure(.unreadableRecord(id, String(describing: error)))
        }
        guard let photo = try await photo(for: scan) else {
            return .failure(.noPhoto(id))
        }
        let rectified = scan.has(.canvas) ? try? await server.asset(.canvas, scanID: id) : nil
        try await store.append(record, photo: photo, rectified: rectified)
        try await held?.markHeldByServer(record, assets: Set(AssetKind.allCases.filter(scan.has)))
        return .success(())
    }

    /// The full photo, else the 1024 px one a scan decided before ADR-003
    /// may be all the server has.
    private func photo(for scan: ServerScan) async throws -> Data? {
        for kind in [AssetKind.photo, .photoSmall] where scan.has(kind) {
            return try await server.asset(kind, scanID: scan.id)
        }
        return nil
    }

    // MARK: - Mapping

    static func batch(from remote: ServerScanBatch, index: IndexSummary) -> ScanBatch {
        ScanBatch(
            id: ScanBatch.ID(rawValue: remote.id),
            startedAt: remote.startedAt,
            label: remote.label,
            device: ScanBatch.Device(model: remote.deviceModel, systemVersion: remote.systemVersion, appVersion: remote.appVersion),
            index: index,
            purpose: BatchPurpose(rawValue: remote.purpose) ?? .calibration,
            product: remote.product.flatMap(BatchProduct.init(wireDescription:)),
            defaultFinish: remote.defaultFinish,
            trainingQuality: remote.trainingQuality.flatMap(TrainingQuality.init(rawValue:)) ?? .legacy
        )
    }

    /// The record the device uploaded, with each candidate's art URL filled
    /// back in from this device's catalog: the server keeps no Riot URLs
    /// (ADR-002 decision 15), and `Card` needs one. A card this catalog lacks
    /// gets a URL that loads nothing, and shows the art placeholder.
    static func record(from json: JSONValue, directory: CardDirectory) throws -> ScanRecord {
        let restored = json.restoringImageURLs(directory)
        return try JSONDecoder.scanStore.decode(ScanRecord.self, from: JSONEncoder.scanStore.encode(restored))
    }
}

/// A store that keeps sync state, told what the server already holds after
/// an import so the scans are not sent straight back.
nonisolated protocol ServerHeldMarking: Sendable {
    func markBatchHeldByServer(_ id: ScanBatch.ID) async throws
    func markHeldByServer(_ record: ScanRecord, assets: Set<AssetKind>) async throws
}

nonisolated extension BatchProduct {
    /// Reads `wireDescription` back: `sealedBox:OGN`, `loose`, `other:<name>`.
    init?(wireDescription: String) {
        if wireDescription == "loose" {
            self = .loose
        } else if wireDescription.hasPrefix("sealedBox:"), let set = SetCode(rawValue: String(wireDescription.dropFirst("sealedBox:".count))) {
            self = .sealedBox(set: set)
        } else if wireDescription.hasPrefix("other:") {
            self = .other(String(wireDescription.dropFirst("other:".count)))
        } else {
            return nil
        }
    }
}

nonisolated extension JSONDecoder {
    /// Reads what `JSONEncoder.scanStore` wrote.
    static var scanStore: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONValue {
    nonisolated static let missingArt = "about:blank"

    /// Puts `imageURL` back on every candidate's card.
    nonisolated func restoringImageURLs(_ directory: CardDirectory) -> JSONValue {
        guard case .object(var record) = self, case .array(let candidates)? = record["candidates"] else { return self }
        record["candidates"] = .array(candidates.map { candidate in
            guard case .object(var entry) = candidate, case .object(var card)? = entry["card"] else { return candidate }
            let id: Card.ID? = if case .string(let raw)? = card["id"] { Card.ID(rawValue: raw) } else { nil }
            card["imageURL"] = .string(id.flatMap { directory[$0]?.imageURL.absoluteString } ?? Self.missingArt)
            entry["card"] = .object(card)
            return .object(entry)
        })
        return .object(record)
    }
}
