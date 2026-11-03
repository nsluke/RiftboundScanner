import Foundation

/// A sitting of scans: one phone, one index, one lighting setup. Every record
/// belongs to exactly one batch, and a batch is one folder on disk.
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

    let id: ID
    let startedAt: Date
    var label: String
    let device: Device
    let index: IndexSummary

    init(id: ID, startedAt: Date, label: String, device: Device, index: IndexSummary) {
        self.id = id
        self.startedAt = startedAt
        self.label = label
        self.device = device
        self.index = index
    }

    var displayName: String {
        label.isEmpty ? startedAt.formatted(date: .abbreviated, time: .shortened) : label
    }
}
