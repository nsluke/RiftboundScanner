import Foundation

/// A query descriptor together with the canvas rotation it was computed from.
public struct OrientedDescriptor: Hashable, Sendable {
    public let descriptor: CardDescriptor
    public let orientation: CardOrientation

    public init(descriptor: CardDescriptor, orientation: CardOrientation) {
        self.descriptor = descriptor
        self.orientation = orientation
    }
}

/// An index entry scored against the query by descriptors alone.
///
/// Two scores, kept apart on purpose (ADR-002, decision 7): ``referenceScore``
/// compares the query with the entry's reference descriptor only and is what
/// decides between card-location hypotheses; ``fusedScore`` also admits what
/// learned exemplars of the entry's ``ArtGroup`` say and is what ranks the
/// candidates of the winning hypothesis.
public struct DescriptorCandidate: Hashable, Sendable {
    public let entry: CardIndex.Entry
    /// The query rotation that scored best against the reference.
    public let orientation: CardOrientation
    public let components: ScoreComponents
    /// ``ScoringPolicy/descriptorScore(_:)`` of `components`.
    public let referenceScore: Double
    /// The best feature-print cosine between any query rotation and any
    /// exemplar of the entry's art group; identical for every member of the
    /// group, `nil` when the group has no exemplars.
    public let exemplarSimilarity: Double?
    /// `max(referenceScore, exemplarScale × exemplarSimilarity)`; equals
    /// ``referenceScore`` when there are no exemplars.
    public let fusedScore: Double

    public init(entry: CardIndex.Entry, orientation: CardOrientation, components: ScoreComponents, referenceScore: Double, exemplarSimilarity: Double?, fusedScore: Double) {
        self.entry = entry
        self.orientation = orientation
        self.components = components
        self.referenceScore = referenceScore
        self.exemplarSimilarity = exemplarSimilarity
        self.fusedScore = fusedScore
    }
}

/// Brute-force nearest-neighbour search over the index. 1,400 entries × 768
/// floats is about one million multiply-adds, which is far cheaper than the
/// Vision work that precedes it, so no approximate index is needed.
///
/// Built with an ``ExemplarIndex`` it also compares the query with every
/// learned exemplar (a few hundred more dot products) and lifts the fused score
/// of each art group accordingly. With ``ExemplarIndex/empty`` it behaves
/// exactly as it did before exemplars existed.
public struct DescriptorMatcher: Sendable {
    public let policy: ScoringPolicy
    /// The exemplars in force, after `excluding` was applied.
    public let exemplars: ExemplarIndex
    private let printsByGroup: [ArtGroup: [FeaturePrint]]

    /// - Parameters:
    ///   - exemplars: the learned overlay; ``ExemplarIndex/empty`` for none.
    ///   - excluding: batches whose exemplars are left out, so a scan can be
    ///     re-identified without what its own sitting taught.
    public init(policy: ScoringPolicy, exemplars: ExemplarIndex = .empty, excluding: Set<UUID> = []) {
        self.policy = policy
        self.exemplars = exemplars.excluding(batches: excluding)
        printsByGroup = Dictionary(grouping: self.exemplars.exemplars, by: \.artGroup).mapValues { $0.map(\.featurePrint) }
    }

    /// The best feature-print cosine between any query rotation and any
    /// exemplar of `group`; `nil` when the group has none.
    public func exemplarSimilarity(for group: ArtGroup, queries: [OrientedDescriptor]) -> Double? {
        guard let prints = printsByGroup[group] else { return nil }
        var best = 0.0
        for print in prints {
            for query in queries {
                best = max(best, query.descriptor.featurePrint.similarity(to: print))
            }
        }
        return best
    }

    /// Scores one entry against the query rotations, keeping the better one.
    public func candidate(for entry: CardIndex.Entry, queries: [OrientedDescriptor]) -> DescriptorCandidate? {
        candidate(for: entry, queries: queries, exemplarSimilarity: printsByGroup.isEmpty ? nil : exemplarSimilarity(for: entry.artGroup, queries: queries))
    }

    private func candidate(for entry: CardIndex.Entry, queries: [OrientedDescriptor], exemplarSimilarity: Double?) -> DescriptorCandidate? {
        var best: (orientation: CardOrientation, components: ScoreComponents, score: Double)?
        for query in queries {
            let components = ScoreComponents(query: query.descriptor, reference: entry.descriptor)
            let score = policy.descriptorScore(components)
            if let current = best, current.score >= score { continue }
            best = (query.orientation, components, score)
        }
        guard let best else { return nil }
        return DescriptorCandidate(
            entry: entry,
            orientation: best.orientation,
            components: best.components,
            referenceScore: best.score,
            exemplarSimilarity: exemplarSimilarity,
            fusedScore: policy.fusedScore(reference: best.score, exemplarSimilarity: exemplarSimilarity)
        )
    }

    /// The shortlist for one hypothesis: the `limit` best entries by fused
    /// score together with the `limit` best by reference score (one list when
    /// there are no exemplars), best fused score first.
    ///
    /// Keeping both halves is what lets exemplar evidence bring a card into
    /// contention while guaranteeing that the top reference match is always
    /// present, so a hypothesis's best reference score (which decides between
    /// hypotheses) is the same whatever the overlay holds.
    public func rank(_ queries: [OrientedDescriptor], in index: CardIndex, limit: Int) -> [DescriptorCandidate] {
        var candidates: [DescriptorCandidate] = []
        candidates.reserveCapacity(index.entries.count)
        var groupSimilarities: [ArtGroup: Double?] = [:]
        for entry in index.entries {
            var similarity: Double?
            if !printsByGroup.isEmpty {
                let group = entry.artGroup
                if let known = groupSimilarities[group] {
                    similarity = known
                } else {
                    similarity = exemplarSimilarity(for: group, queries: queries)
                    groupSimilarities[group] = similarity
                }
            }
            if let best = candidate(for: entry, queries: queries, exemplarSimilarity: similarity) {
                candidates.append(best)
            }
        }
        candidates.sort { $0.referenceScore > $1.referenceScore }
        let byReference = candidates.prefix(limit)
        if printsByGroup.isEmpty {
            return Array(byReference)
        }
        let byFused = candidates.sorted(by: Self.fusedFirst).prefix(limit)
        var seen = Set<Card.ID>()
        var shortlist: [DescriptorCandidate] = []
        for candidate in byFused + byReference where seen.insert(candidate.entry.id).inserted {
            shortlist.append(candidate)
        }
        return shortlist.sorted(by: Self.fusedFirst)
    }

    private static func fusedFirst(_ lhs: DescriptorCandidate, _ rhs: DescriptorCandidate) -> Bool {
        lhs.fusedScore != rhs.fusedScore ? lhs.fusedScore > rhs.fusedScore : lhs.referenceScore > rhs.referenceScore
    }
}
