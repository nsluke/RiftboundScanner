import Foundation
import Testing
import RiftboundRecognizer

@Suite("Descriptor matcher with exemplars")
struct DescriptorMatcherTests {
    static func descriptor(bits: UInt64, print: [Float]) -> CardDescriptor {
        CardDescriptor(wholeDifferenceHash: ImageHash(bits: bits), wholePerceptualHash: ImageHash(bits: bits), artDifferenceHash: ImageHash(bits: bits), featurePrint: FeaturePrint(elements: print))
    }

    static let batchA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    static let batchB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!

    static func exemplar(_ group: String, print: [Float], batch: UUID = batchA) -> ExemplarIndex.Exemplar {
        ExemplarIndex.Exemplar(artGroup: ArtGroup(rawValue: group), featurePrint: FeaturePrint(elements: print), scanID: UUID(), batchID: batch, admittedAt: Date(timeIntervalSince1970: 0))
    }

    /// Three illustrations; `ogn-003` has a standard and a signature printing.
    static let index = CardIndex(canvas: .standard, builtAt: Date(timeIntervalSince1970: 0), entries: [
        CardIndex.Entry(card: TestRig.card("ogn-001-298", code: "OGN-001/298"), descriptor: descriptor(bits: 0x0F0F_0F0F_0F0F_0F0F, print: [1, 0, 0, 0])),
        CardIndex.Entry(card: TestRig.card("ogn-002-298", code: "OGN-002/298"), descriptor: descriptor(bits: 0xF0F0_F0F0_F0F0_F0F0, print: [0, 1, 0, 0])),
        CardIndex.Entry(card: TestRig.card("ogn-003-298", code: "OGN-003/298"), descriptor: descriptor(bits: 0xFFFF_0000_FFFF_0000, print: [0, 0, 1, 0])),
        CardIndex.Entry(card: TestRig.card("ogn-003*-298", code: "OGN-003*/298", printing: [.signature]), descriptor: descriptor(bits: 0xFFFF_0000_FFFF_0001, print: [0, 0, 0.98, 0.2])),
    ])

    /// Looks like card 1, and nothing like the ogn-003 pair.
    static let query = [OrientedDescriptor(descriptor: descriptor(bits: 0x0F0F_0F0F_0F0F_0F0F, print: [1, 0, 0, 0]), orientation: .upright)]

    @Test func anExemplarEqualToTheQueryLiftsEveryMemberOfItsGroupToTheScaledScore() throws {
        let overlay = ExemplarIndex(version: 1, calibrationPrint: nil, exemplars: [Self.exemplar("ogn-003", print: [1, 0, 0, 0])])
        let plain = DescriptorMatcher(policy: .default).rank(Self.query, in: Self.index, limit: 4)
        let learned = DescriptorMatcher(policy: .default, exemplars: overlay).rank(Self.query, in: Self.index, limit: 4)

        func candidate(_ id: String, in ranked: [DescriptorCandidate]) throws -> DescriptorCandidate {
            try #require(ranked.first { $0.entry.id.rawValue == id })
        }
        for id in ["ogn-003-298", "ogn-003*-298"] {
            let before = try candidate(id, in: plain)
            let after = try candidate(id, in: learned)
            #expect(after.referenceScore == before.referenceScore, "\(id): the reference score is untouched")
            #expect(before.referenceScore < 0.5)
            #expect(after.exemplarSimilarity == 1, "\(id): every member of the group sees the same exemplar")
            #expect(after.fusedScore == 0.95, "\(id): exemplarScale × 1.0")
            #expect(after.components == before.components && after.orientation == before.orientation)
        }
        let unrelated = try candidate("ogn-002-298", in: learned)
        #expect(unrelated.exemplarSimilarity == nil && unrelated.fusedScore == unrelated.referenceScore, "other groups are unaffected")
        let top = try candidate("ogn-001-298", in: learned)
        #expect(top.fusedScore == 1 && top.referenceScore == 1 && top.exemplarSimilarity == nil)
        #expect(learned.map(\.entry.id.rawValue) == ["ogn-001-298", "ogn-003*-298", "ogn-003-298", "ogn-002-298"] || learned.map(\.entry.id.rawValue) == ["ogn-001-298", "ogn-003-298", "ogn-003*-298", "ogn-002-298"], "ranked by fused score, the lifted pair second")
    }

    @Test func theGroupSimilarityIsTheBestOverItsExemplarsAndTheQueryRotations() {
        let overlay = ExemplarIndex(version: 1, calibrationPrint: nil, exemplars: [
            Self.exemplar("ogn-003", print: [0, 1, 0, 0]),
            Self.exemplar("ogn-003", print: [0.6, 0.8, 0, 0]),
        ])
        let matcher = DescriptorMatcher(policy: .default, exemplars: overlay)
        let upright = Self.query[0]
        let flipped = OrientedDescriptor(descriptor: Self.descriptor(bits: 0, print: [0, 1, 0, 0]), orientation: .upsideDown)
        #expect(abs((matcher.exemplarSimilarity(for: ArtGroup(rawValue: "ogn-003"), queries: [upright]) ?? 0) - 0.6) < 1e-6)
        #expect(matcher.exemplarSimilarity(for: ArtGroup(rawValue: "ogn-003"), queries: [upright, flipped]) == 1)
        #expect(matcher.exemplarSimilarity(for: ArtGroup(rawValue: "ogn-001"), queries: [upright]) == nil)
    }

    @Test func excludingBatchesRemovesTheirExemplars() {
        let overlay = ExemplarIndex(version: 1, calibrationPrint: nil, exemplars: [
            Self.exemplar("ogn-003", print: [1, 0, 0, 0], batch: Self.batchA),
            Self.exemplar("ogn-002", print: [1, 0, 0, 0], batch: Self.batchB),
        ])
        let matcher = DescriptorMatcher(policy: .default, exemplars: overlay, excluding: [Self.batchA])
        #expect(matcher.exemplars.exemplars.map(\.batchID) == [Self.batchB])
        let ranked = matcher.rank(Self.query, in: Self.index, limit: 4)
        #expect(ranked.first { $0.entry.id.rawValue == "ogn-003-298" }?.exemplarSimilarity == nil, "batch A's exemplar is gone")
        #expect(ranked.first { $0.entry.id.rawValue == "ogn-002-298" }?.exemplarSimilarity == 1, "batch B's stays")

        let everything = DescriptorMatcher(policy: .default, exemplars: overlay, excluding: [Self.batchA, Self.batchB])
        #expect(everything.exemplars.isEmpty)
        #expect(everything.rank(Self.query, in: Self.index, limit: 4) == DescriptorMatcher(policy: .default).rank(Self.query, in: Self.index, limit: 4))
    }

    @Test func theEmptyOverlayChangesNothing() {
        let plain = DescriptorMatcher(policy: .default)
        let empty = DescriptorMatcher(policy: .default, exemplars: .empty)
        for limit in [1, 2, 4, 12] {
            let a = plain.rank(Self.query, in: Self.index, limit: limit)
            let b = empty.rank(Self.query, in: Self.index, limit: limit)
            #expect(a == b)
            #expect(a.count == min(limit, Self.index.entries.count))
            #expect(a.allSatisfy { $0.fusedScore == $0.referenceScore && $0.exemplarSimilarity == nil })
            #expect(a == a.sorted { $0.referenceScore > $1.referenceScore })
        }
    }

    @Test func anExemplarBringsItsGroupIntoTheShortlistWithoutDroppingTheReferenceLeader() {
        // Shortlist of two: by reference alone cards 1 and 2 would be kept; the
        // exemplar says the photo is of the ogn-003 pair, so one of that pair
        // takes card 2's place while card 1, the reference leader, stays.
        let overlay = ExemplarIndex(version: 1, calibrationPrint: nil, exemplars: [Self.exemplar("ogn-003", print: [1, 0, 0, 0])])
        var policy = ScoringPolicy.default
        policy.exemplarScale = 1.5
        let matcher = DescriptorMatcher(policy: policy, exemplars: overlay)
        let ranked = matcher.rank(Self.query, in: Self.index, limit: 2)
        #expect(ranked.count == 2, "the limit still bounds the shortlist")
        #expect(ranked[0].entry.artGroup == ArtGroup(rawValue: "ogn-003") && ranked[0].fusedScore == 1.5)
        #expect(ranked[1].entry.id.rawValue == "ogn-001-298" && ranked[1].referenceScore == 1, "the best reference match is always listed")
        #expect(ranked.map(\.referenceScore).max() == DescriptorMatcher(policy: .default).rank(Self.query, in: Self.index, limit: 2).first?.referenceScore)

        // Three fused leaders would be the ogn-003 pair and card 1 anyway.
        let three = matcher.rank(Self.query, in: Self.index, limit: 3)
        #expect(three.count == 3 && three.map(\.entry.id.rawValue).contains("ogn-001-298") && !three.map(\.entry.id.rawValue).contains("ogn-002-298"))
        #expect(three == three.sorted { $0.fusedScore > $1.fusedScore })

        // A shortlist of one has room only for the reference leader: the
        // hypothesis's standing against the others must not depend on the overlay.
        let one = matcher.rank(Self.query, in: Self.index, limit: 1)
        #expect(one.map(\.entry.id.rawValue) == ["ogn-001-298"])
        #expect(matcher.rank(Self.query, in: Self.index, limit: 0).isEmpty)
        for limit in [1, 2, 3, 4, 12] {
            #expect(matcher.rank(Self.query, in: Self.index, limit: limit).count == min(limit, Self.index.entries.count), "limit \(limit)")
        }
    }

    @Test func codeInjectedCandidatesCarryExemplarEvidenceToo() throws {
        let overlay = ExemplarIndex(version: 1, calibrationPrint: nil, exemplars: [Self.exemplar("ogn-003", print: [0, 0, 1, 0])])
        let matcher = DescriptorMatcher(policy: .default, exemplars: overlay)
        let entry = Self.index.entries[3]
        let candidate = try #require(matcher.candidate(for: entry, queries: Self.query))
        #expect(candidate.exemplarSimilarity == 0)
        #expect(candidate.fusedScore == candidate.referenceScore, "a dissimilar exemplar never lowers the score")
        let other = try #require(DescriptorMatcher(policy: .default).candidate(for: entry, queries: Self.query))
        #expect(other.exemplarSimilarity == nil && other.referenceScore == candidate.referenceScore)
    }
}
