/// A query descriptor together with the canvas rotation it was computed from.
public struct OrientedDescriptor: Hashable, Sendable, Codable {
    public let descriptor: CardDescriptor
    public let orientation: CardOrientation

    public init(descriptor: CardDescriptor, orientation: CardOrientation) {
        self.descriptor = descriptor
        self.orientation = orientation
    }
}

/// An index entry ranked by descriptor similarity alone.
public struct DescriptorCandidate: Hashable, Sendable {
    public let entry: CardIndex.Entry
    public let orientation: CardOrientation
    public let components: ScoreComponents
    public let score: Double
}

/// Brute-force nearest-neighbour search over the index. 1,400 entries × 768
/// floats is about one million multiply-adds, which is far cheaper than the
/// Vision work that precedes it, so no approximate index is needed.
public struct DescriptorMatcher: Sendable {
    public let policy: ScoringPolicy

    public init(policy: ScoringPolicy) {
        self.policy = policy
    }

    /// Scores one entry against the query rotations, keeping the better one.
    public func candidate(for entry: CardIndex.Entry, queries: [OrientedDescriptor]) -> DescriptorCandidate? {
        var best: DescriptorCandidate?
        for query in queries {
            let components = ScoreComponents(query: query.descriptor, reference: entry.descriptor)
            let score = policy.descriptorScore(components)
            if let current = best, current.score >= score { continue }
            best = DescriptorCandidate(entry: entry, orientation: query.orientation, components: components, score: score)
        }
        return best
    }

    /// Ranks every entry by its best score over the supplied query rotations.
    public func rank(_ queries: [OrientedDescriptor], in index: CardIndex, limit: Int) -> [DescriptorCandidate] {
        var candidates: [DescriptorCandidate] = []
        candidates.reserveCapacity(index.entries.count)
        for entry in index.entries {
            if let best = candidate(for: entry, queries: queries) {
                candidates.append(best)
            }
        }
        candidates.sort { $0.score > $1.score }
        return Array(candidates.prefix(limit))
    }
}
