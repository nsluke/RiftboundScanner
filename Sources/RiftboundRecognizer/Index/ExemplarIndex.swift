import Foundation

/// Feature prints learned from confirmed photos, keyed by ``ArtGroup``: the
/// overlay the collection server builds per calibration hash and the phone
/// downloads (ADR-002, section 7). A ``DescriptorMatcher`` fuses them with the
/// reference index; the index itself never changes.
///
/// Wire format (`formatVersion` 2) is JSON with the same conventions as
/// ``CardIndex``: feature prints are base64 little-endian Float32, dates are
/// ISO 8601. On the phone the same content is kept as a binary file by
/// ``BinaryExemplarStore``.
public struct ExemplarIndex: Hashable, Sendable, Codable {
    public static let currentFormatVersion = 2

    /// One learned print. ``id`` is the scan it came from: the admission gate
    /// admits at most one exemplar per scan, and a delta revokes by scan id.
    public struct Exemplar: Hashable, Sendable, Codable, Identifiable {
        public let artGroup: ArtGroup
        public let featurePrint: FeaturePrint
        public let scanID: UUID
        public let batchID: UUID
        public let admittedAt: Date

        public init(artGroup: ArtGroup, featurePrint: FeaturePrint, scanID: UUID, batchID: UUID, admittedAt: Date) {
            self.artGroup = artGroup
            self.featurePrint = featurePrint
            self.scanID = scanID
            self.batchID = batchID
            self.admittedAt = admittedAt
        }

        public var id: UUID { scanID }
    }

    public let formatVersion: Int
    /// Monotonic per calibration hash on the server; 0 for ``empty``.
    public let version: Int
    /// The ``CalibrationCanvas`` as printed by the devices whose scans the
    /// exemplars came from; `nil` only for an overlay with nothing to compare.
    public let calibrationPrint: FeaturePrint?
    public let exemplars: [Exemplar]

    public init(version: Int, calibrationPrint: FeaturePrint?, exemplars: [Exemplar]) {
        self.formatVersion = Self.currentFormatVersion
        self.version = version
        self.calibrationPrint = calibrationPrint
        self.exemplars = exemplars
    }

    /// No exemplars: matching with it is identical to matching without an overlay.
    public static let empty = ExemplarIndex(version: 0, calibrationPrint: nil, exemplars: [])

    public var isEmpty: Bool { exemplars.isEmpty }

    /// The digest of ``calibrationPrint``, the key artefacts in the same
    /// embedding space share.
    public var calibrationHash: FeaturePrint.Digest? { calibrationPrint?.digest }

    /// The element count the exemplars (and calibration print) share; `nil`
    /// when there is nothing to measure.
    public var dimension: Int? {
        exemplars.first?.featurePrint.elements.count ?? calibrationPrint?.elements.count
    }

    /// The exemplars of every group, in file order.
    public var exemplarsByGroup: [ArtGroup: [Exemplar]] {
        Dictionary(grouping: exemplars, by: \.artGroup)
    }

    // MARK: Compatibility

    /// Whether exemplars computed in this overlay's embedding space can be
    /// compared with prints the device computes (ADR-002, decision 14).
    public enum Compatibility: Hashable, Sendable {
        case compatible(similarity: Double)
        /// The device's Vision model embeds the calibration canvas differently.
        case embeddingChanged(similarity: Double)
        case dimensionMismatch(overlay: Int, device: Int)
        /// The overlay has exemplars but no calibration print to compare.
        case uncalibrated
    }

    /// Compares the device's print of the ``CalibrationCanvas`` with the one
    /// the overlay was built against: compatible iff the dimensions agree and
    /// the cosine similarity reaches `minimum` (``LearningPolicy/calibrationMinimum``).
    /// An overlay with no exemplars is compatible with every device.
    public func compatibility(with devicePrint: FeaturePrint, minimum: Double) -> Compatibility {
        guard let calibrationPrint else {
            return exemplars.isEmpty ? .compatible(similarity: 1) : .uncalibrated
        }
        let deviceDimension = devicePrint.elements.count
        for dimension in [calibrationPrint.elements.count] + exemplars.map(\.featurePrint.elements.count) where dimension != deviceDimension {
            return .dimensionMismatch(overlay: dimension, device: deviceDimension)
        }
        let similarity = calibrationPrint.similarity(to: devicePrint)
        return similarity >= minimum ? .compatible(similarity: similarity) : .embeddingChanged(similarity: similarity)
    }

    public func isCompatible(calibrationPrint devicePrint: FeaturePrint, minimum: Double) -> Bool {
        if case .compatible = compatibility(with: devicePrint, minimum: minimum) { true } else { false }
    }

    // MARK: Filtering

    /// The overlay without the exemplars learned from the given batches, so a
    /// scan can be re-identified without the knowledge its own sitting taught.
    public func excluding(batches: Set<UUID>) -> ExemplarIndex {
        guard !batches.isEmpty else { return self }
        return ExemplarIndex(version: version, calibrationPrint: calibrationPrint, exemplars: exemplars.filter { !batches.contains($0.batchID) })
    }

    // MARK: Deltas

    /// Applies a server delta: revoked scans are dropped, added exemplars
    /// replace any existing exemplar of the same scan, and the version moves to
    /// the delta's. Throws when the delta was computed against another version.
    public func applying(_ delta: ExemplarDelta) throws(ExemplarIndexError) -> ExemplarIndex {
        if let base = delta.baseVersion, base != version {
            throw .deltaBaseMismatch(expected: version, found: base)
        }
        let removed = delta.revoked.union(delta.added.map(\.scanID))
        let kept = exemplars.filter { !removed.contains($0.scanID) }
        return ExemplarIndex(version: delta.version, calibrationPrint: delta.calibrationPrint ?? calibrationPrint, exemplars: kept + delta.added)
    }

    // MARK: Files

    public static func read(from url: URL) throws -> ExemplarIndex {
        try decode(try Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> ExemplarIndex {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let index = try decoder.decode(ExemplarIndex.self, from: data)
        guard index.formatVersion == currentFormatVersion else {
            throw ExemplarIndexError.unsupportedFormat(found: index.formatVersion, expected: currentFormatVersion)
        }
        return index
    }

    public func write(to url: URL) throws {
        try encoded().write(to: url, options: .atomic)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// What `GET /api/learning/overlay/changes` returns: the exemplars admitted
/// and the scans revoked since `baseVersion`, moving the overlay to `version`.
public struct ExemplarDelta: Hashable, Sendable, Codable {
    /// The overlay version the delta applies to; `nil` for a delta that is
    /// valid against any base (a server rebuilding from scratch sends a full
    /// overlay instead, so this is normally set).
    public let baseVersion: Int?
    public let version: Int
    /// Present when the server wants to (re)state the calibration print.
    public let calibrationPrint: FeaturePrint?
    public let added: [ExemplarIndex.Exemplar]
    /// Scan ids whose exemplars were revoked.
    public let revoked: Set<UUID>

    public init(baseVersion: Int?, version: Int, calibrationPrint: FeaturePrint? = nil, added: [ExemplarIndex.Exemplar], revoked: Set<UUID>) {
        self.baseVersion = baseVersion
        self.version = version
        self.calibrationPrint = calibrationPrint
        self.added = added
        self.revoked = revoked
    }
}

public enum ExemplarIndexError: Error, Hashable, Sendable {
    case unsupportedFormat(found: Int, expected: Int)
    case deltaBaseMismatch(expected: Int, found: Int)
}
