import CoreGraphics
import CryptoKit
import Foundation
import RiftboundRecognizer

/// Builds the `PUT /api/scans/{id}` body for a record. The sync engine owns
/// *when* a record goes up; this seam owns *what* goes up, so A5's
/// `ScanUploadBuilder` (reference similarities, code alternatives) replaces
/// `RecordUploadComposer` without touching the engine.
nonisolated protocol ScanUploadComposing: Sendable {
    func upload(for record: ScanRecord, in batch: ScanBatch) throws -> ScanUpload
}

/// The record as stored (minus image URLs), its oriented descriptor with the
/// calibration hash, the analysis stamp and the engine. No similarities yet.
nonisolated struct RecordUploadComposer: ScanUploadComposing {
    init() {}

    func upload(for record: ScanRecord, in batch: ScanBatch) throws -> ScanUpload {
        ScanUpload(
            id: record.id.rawValue,
            batchID: batch.id.rawValue,
            record: try ScanUpload.record(from: record),
            descriptor: Self.descriptor(for: record),
            codeAlternatives: record.analysis?.codeAlternatives.map {
                CodeAlternativeUpload(code: $0.code.canonical, cardRef: nil, referenceSimilarity: nil, isLiteral: $0.origin == .literal)
            } ?? [],
            analysisStamp: Self.analysisStamp(for: record),
            engine: record.engine.map(EngineStampUpload.init)
        )
    }

    /// The winning oriented descriptor, or `nil` for a v1 record that has not
    /// been re-identified; the server keeps the record without one.
    static func descriptor(for record: ScanRecord) -> DescriptorUpload? {
        guard let analysis = record.analysis, let engine = record.engine else { return nil }
        let descriptor = analysis.descriptor.descriptor
        return DescriptorUpload(
            calibrationHash: engine.calibrationHash,
            orientation: analysis.descriptor.orientation == .upright ? .upright : .upsideDown,
            featurePrint: descriptor.featurePrint.float32Data.base64EncodedString(),
            hashes: [
                "wholeDifferenceHash": String(descriptor.wholeDifferenceHash.bits, radix: 16),
                "wholePerceptualHash": String(descriptor.wholePerceptualHash.bits, radix: 16),
                "artDifferenceHash": String(descriptor.artDifferenceHash.bits, radix: 16),
            ]
        )
    }

    /// SHA-256 over what identifies one analysis (ADR-002 §4.1 v3): the
    /// calibration hash, platform, package and overlay versions and the time
    /// it was computed. A re-identified record gets a new stamp at equal seq.
    static func analysisStamp(for record: ScanRecord) -> String {
        let parts = [
            record.engine?.calibrationHash ?? "",
            record.engine?.platform ?? "",
            record.engine?.packageVersion ?? "",
            record.engine?.overlayVersion.map(String.init) ?? "",
            record.analysis.map { $0.analyzedAt.timeIntervalSince1970.description } ?? "",
        ]
        let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated extension EngineStampUpload {
    init(_ stamp: EngineStamp) {
        self.init(
            packageVersion: stamp.packageVersion,
            calibrationHash: stamp.calibrationHash,
            platform: stamp.platform,
            osVersion: stamp.osVersion,
            overlayVersion: stamp.overlayVersion,
            policyVersion: stamp.policyVersion
        )
    }
}

nonisolated extension BatchUpload {
    /// The batch as `PUT /api/scans/batches/{id}` wants it; the calibration
    /// hash comes from the first stamped record, since the batch itself has none.
    init(_ batch: ScanBatch, calibrationHash: String?) {
        self.init(
            id: batch.id.rawValue,
            startedAt: batch.startedAt,
            label: batch.label,
            purpose: batch.purpose.rawValue,
            product: batch.product?.wireDescription,
            defaultFinish: batch.defaultFinish,
            trainingQuality: batch.trainingQuality.rawValue,
            deviceModel: batch.device.model,
            systemVersion: batch.device.systemVersion,
            appVersion: batch.device.appVersion,
            calibrationHash: calibrationHash
        )
    }
}

nonisolated extension BatchProduct {
    /// A flat spelling for the server's text column: `sealedBox:OGN`, `loose`, `other:<name>`.
    var wireDescription: String {
        switch self {
        case .sealedBox(let set): "sealedBox:\(set.rawValue)"
        case .loose: "loose"
        case .other(let name): "other:\(name)"
        }
    }
}

/// Produces the bytes for one asset of a scan, already within the server's
/// cap for that kind, or `nil` when the asset cannot be produced (the photo
/// is gone, or no encoding fits). A5's `AssetUploader` refines this.
nonisolated protocol ScanAssetProviding: Sendable {
    func asset(_ kind: AssetKind, for record: ScanRecord) async throws -> Data?
}

/// How an asset is shrunk to fit the server's cap for its kind (ADR-002,
/// principle 4: every threshold is a policy value, injected at the
/// composition root rather than written where it is used). `photoSmallLongEdge`
/// is the ADR's 1024 px; a canvas or photo over its cap is re-encoded at its
/// fallback long edge, trying each JPEG quality in turn.
nonisolated struct AssetEncodingPolicy: Hashable, Sendable {
    var photoSmallLongEdge: Int
    var canvasFallbackLongEdge: Int
    var photoFallbackLongEdge: Int
    var jpegQualities: [Double]

    init(photoSmallLongEdge: Int = 1024, canvasFallbackLongEdge: Int = 1056, photoFallbackLongEdge: Int = 2048, jpegQualities: [Double] = [0.8, 0.6, 0.45]) {
        self.photoSmallLongEdge = photoSmallLongEdge
        self.canvasFallbackLongEdge = canvasFallbackLongEdge
        self.photoFallbackLongEdge = photoFallbackLongEdge
        self.jpegQualities = jpegQualities
    }
}

/// Reads assets from the scan store: `photo_small` is the photo downsampled
/// to the policy's long edge, the canvas is the rectified file, the photo
/// is the stored JPEG; anything over the cap is re-encoded smaller once.
nonisolated struct StoredAssetProvider: ScanAssetProviding {
    private let store: any ScanStoring
    private let policy: AssetEncodingPolicy

    init(store: any ScanStoring, policy: AssetEncodingPolicy) {
        self.store = store
        self.policy = policy
    }

    func asset(_ kind: AssetKind, for record: ScanRecord) async throws -> Data? {
        switch kind {
        case .photoSmall:
            guard let image = await PhotoDecoder.thumbnail(at: store.photoURL(for: record), maxPixelSize: policy.photoSmallLongEdge) else { return nil }
            return try await encodeWithinCap(image, cap: kind.maximumBytes)
        case .canvas:
            guard let url = store.rectifiedURL(for: record) else { return nil }
            return try await fileWithinCap(url, cap: kind.maximumBytes, fallbackLongEdge: policy.canvasFallbackLongEdge)
        case .photo:
            return try await fileWithinCap(store.photoURL(for: record), cap: kind.maximumBytes, fallbackLongEdge: policy.photoFallbackLongEdge)
        }
    }

    private func fileWithinCap(_ url: URL, cap: Int, fallbackLongEdge: Int) async throws -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.count <= cap { return data }
        guard let image = await PhotoDecoder.thumbnail(at: url, maxPixelSize: fallbackLongEdge) else { return nil }
        return try await encodeWithinCap(image, cap: cap)
    }

    private func encodeWithinCap(_ image: CGImage, cap: Int) async throws -> Data? {
        for quality in policy.jpegQualities {
            let data = try await PhotoDecoder.encodeJPEG(image, quality: quality)
            if data.count <= cap { return data }
        }
        return nil
    }
}
