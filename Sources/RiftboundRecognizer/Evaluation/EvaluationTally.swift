import Foundation

/// One labelled photo in an evaluation set.
public struct EvaluationCase: Hashable, Sendable, Codable {
    /// Path relative to the manifest's folder.
    public let file: String
    public let expected: Card.ID
    /// Grouping key for the report (a synthetic severity, or `samples`).
    public let group: String
    public let parameters: SyntheticPhotoParameters?

    public init(file: String, expected: Card.ID, group: String, parameters: SyntheticPhotoParameters? = nil) {
        self.file = file
        self.expected = expected
        self.group = group
        self.parameters = parameters
    }
}

/// `manifest.json` next to a synthetic test set.
public struct EvaluationManifest: Sendable, Codable {
    public static let fileName = "manifest.json"

    public let generatedAt: Date
    public let seed: UInt64
    public let cases: [EvaluationCase]

    public init(generatedAt: Date, seed: UInt64, cases: [EvaluationCase]) {
        self.generatedAt = generatedAt
        self.seed = seed
        self.cases = cases
    }

    public static func read(from folder: URL) throws -> EvaluationManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(EvaluationManifest.self, from: try Data(contentsOf: folder.appendingPathComponent(fileName)))
    }

    public func write(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

/// Accumulates top-1 / top-3 accuracy per group. Pure, so it is unit-tested
/// without running the recogniser.
public struct EvaluationTally: Hashable, Sendable {
    public struct GroupStatistics: Hashable, Sendable {
        public private(set) var total = 0
        public private(set) var top1 = 0
        public private(set) var top3 = 0
        public private(set) var totalDuration: Duration = .zero

        public var top1Rate: Double { total == 0 ? 0 : Double(top1) / Double(total) }
        public var top3Rate: Double { total == 0 ? 0 : Double(top3) / Double(total) }
        public var meanDuration: Duration { total == 0 ? .zero : totalDuration / total }

        fileprivate mutating func record(rank: Int?, duration: Duration) {
            total += 1
            if let rank {
                if rank == 0 { top1 += 1 }
                if rank < 3 { top3 += 1 }
            }
            totalDuration += duration
        }
    }

    public struct Failure: Hashable, Sendable {
        public let file: String
        public let group: String
        public let expected: Card.ID
        public let ranked: [Card.ID]
        public let rank: Int?
    }

    public private(set) var groups: [String: GroupStatistics] = [:]
    public private(set) var overall = GroupStatistics()
    public private(set) var failures: [Failure] = []

    public init() {}

    /// Records one case. `ranked` lists the recogniser's candidates, best first.
    public mutating func record(_ evaluationCase: EvaluationCase, ranked: [Card.ID], duration: Duration) {
        let rank = ranked.firstIndex(of: evaluationCase.expected)
        groups[evaluationCase.group, default: GroupStatistics()].record(rank: rank, duration: duration)
        overall.record(rank: rank, duration: duration)
        if rank != 0 {
            failures.append(Failure(file: evaluationCase.file, group: evaluationCase.group, expected: evaluationCase.expected, ranked: Array(ranked.prefix(3)), rank: rank))
        }
    }

    public var groupNames: [String] { groups.keys.sorted() }
}
