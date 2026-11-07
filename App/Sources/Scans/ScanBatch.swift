import Foundation
import RiftboundRecognizer

/// A sitting of scans: one phone, one index, one lighting setup. Every record
/// belongs to exactly one batch, and a batch is one folder on disk. Version 2
/// (ADR-002, decision 6) adds the purpose, product, default finish and
/// training quality; a v1 file decodes as a calibration batch that never trains.
nonisolated struct ScanBatch: Hashable, Sendable, Codable, Identifiable {
    /// Encodes as the bare UUID string, so the JSON stays readable by scripts.
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
    }

    struct Device: Hashable, Sendable, Codable {
        let model: String
        let systemVersion: String
        let appVersion: String

        /// The running device, e.g. `iPhone17,1` on iOS 26.
        static func current(appVersion: String) -> Device {
            var systemInfo = utsname()
            uname(&systemInfo)
            let machine = withUnsafePointer(to: &systemInfo.machine) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(validatingCString: $0) ?? "unknown" }
            }
            return Device(model: machine, systemVersion: ProcessInfo.processInfo.operatingSystemVersionString, appVersion: appVersion)
        }
    }

    /// What the batch is for and whether its decisions reach the ledger.
    struct Setup: Hashable, Sendable {
        var label: String
        var purpose: BatchPurpose
        var product: BatchProduct?
        var defaultFinish: Finish?

        init(label: String, purpose: BatchPurpose, product: BatchProduct? = nil, defaultFinish: Finish? = nil) {
            self.label = label
            self.purpose = purpose
            self.product = product
            self.defaultFinish = defaultFinish
        }

        /// A sitting that records nothing in the collection: the default
        /// until the start-run sheet asks.
        static func calibration(label: String) -> Setup {
            Setup(label: label, purpose: .calibration)
        }
    }

    let id: ID
    let startedAt: Date
    var label: String
    let device: Device
    let index: IndexSummary
    /// Set when the run starts and never changed once a decision exists.
    let purpose: BatchPurpose
    /// What was opened or stacked for this run, when the user said.
    let product: BatchProduct?
    /// The finish both-finish printings take unless a decision overrides it.
    let defaultFinish: Finish?
    /// Whether the batch's standard-quality captures may train the recogniser.
    let trainingQuality: TrainingQuality

    init(
        id: ID,
        startedAt: Date,
        label: String,
        device: Device,
        index: IndexSummary,
        purpose: BatchPurpose = .calibration,
        product: BatchProduct? = nil,
        defaultFinish: Finish? = nil,
        trainingQuality: TrainingQuality = .legacy
    ) {
        self.id = id
        self.startedAt = startedAt
        self.label = label
        self.device = device
        self.index = index
        self.purpose = purpose
        self.product = product
        self.defaultFinish = defaultFinish
        self.trainingQuality = trainingQuality
    }

    var displayName: String {
        label.isEmpty ? startedAt.formatted(date: .abbreviated, time: .shortened) : label
    }

    // MARK: - Coding

    private enum CodingKeys: String, CodingKey {
        case id, startedAt, label, device, index, purpose, product, defaultFinish, trainingQuality
    }

    /// v1 files have none of the v2 keys: they are calibration sittings whose
    /// photos never train (ADR-002, decision 6).
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(ID.self, forKey: .id),
            startedAt: try container.decode(Date.self, forKey: .startedAt),
            label: try container.decode(String.self, forKey: .label),
            device: try container.decode(Device.self, forKey: .device),
            index: try container.decode(IndexSummary.self, forKey: .index),
            purpose: try container.decodeIfPresent(BatchPurpose.self, forKey: .purpose) ?? .calibration,
            product: try container.decodeIfPresent(BatchProduct.self, forKey: .product),
            defaultFinish: try container.decodeIfPresent(Finish.self, forKey: .defaultFinish),
            trainingQuality: try container.decodeIfPresent(TrainingQuality.self, forKey: .trainingQuality) ?? .legacy
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(label, forKey: .label)
        try container.encode(device, forKey: .device)
        try container.encode(index, forKey: .index)
        try container.encode(purpose, forKey: .purpose)
        try container.encodeIfPresent(product, forKey: .product)
        try container.encodeIfPresent(defaultFinish, forKey: .defaultFinish)
        try container.encode(trainingQuality, forKey: .trainingQuality)
    }
}

/// Whether a batch's decisions are acquisitions. The 113 scans judged before
/// the ledger existed are calibration data and are never ledgered.
nonisolated enum BatchPurpose: String, Hashable, Sendable, Codable, CaseIterable {
    /// Cards being added to the collection; correct and corrected decisions ledger +1.
    case collection
    /// A test sitting; nothing reaches the ledger.
    case calibration
}

/// Whether a batch may feed exemplars. A batch-level veto over the per-scan
/// `CaptureQuality`: a `legacy` batch trains nothing however its photos look.
nonisolated enum TrainingQuality: String, Hashable, Sendable, Codable, CaseIterable {
    case standard
    case legacy
}

/// What the cards in a batch came from. A sealed box names its set so the
/// recogniser can be hinted and promo printings hidden behind a disclosure.
///
/// JSON: `{"kind":"sealedBox","set":"OGN"}`, `{"kind":"loose"}` or `{"kind":"other","name":"…"}`.
nonisolated enum BatchProduct: Hashable, Sendable, Codable {
    case sealedBox(set: SetCode)
    case loose
    case other(String)

    /// The set every card in the batch belongs to, when the product fixes one.
    var expectedSet: SetCode? {
        if case .sealedBox(let set) = self { return set }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case kind, set, name
    }

    private enum Kind: String, Codable {
        case sealedBox, loose, other
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .sealedBox: self = .sealedBox(set: try container.decode(SetCode.self, forKey: .set))
        case .loose: self = .loose
        case .other: self = .other(try container.decode(String.self, forKey: .name))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sealedBox(let set):
            try container.encode(Kind.sealedBox, forKey: .kind)
            try container.encode(set, forKey: .set)
        case .loose:
            try container.encode(Kind.loose, forKey: .kind)
        case .other(let name):
            try container.encode(Kind.other, forKey: .kind)
            try container.encode(name, forKey: .name)
        }
    }
}
