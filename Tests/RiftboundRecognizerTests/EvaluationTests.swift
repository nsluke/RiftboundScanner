import Foundation
import Testing
import RiftboundRecognizer

@Suite("Evaluation tally")
struct EvaluationTallyTests {
    private func id(_ raw: String) -> Card.ID { Card.ID(rawValue: raw) }

    @Test func countsTop1AndTop3PerGroup() {
        var tally = EvaluationTally()
        tally.record(EvaluationCase(file: "a.jpg", expected: id("a"), group: "mild"), ranked: [id("a"), id("b")], duration: .seconds(1))
        tally.record(EvaluationCase(file: "b.jpg", expected: id("b"), group: "mild"), ranked: [id("a"), id("c"), id("b")], duration: .seconds(3))
        tally.record(EvaluationCase(file: "c.jpg", expected: id("c"), group: "harsh"), ranked: [id("a"), id("b"), id("d"), id("c")], duration: .seconds(2))

        #expect(tally.overall.total == 3 && tally.overall.top1 == 1 && tally.overall.top3 == 2)
        #expect(abs(tally.overall.top1Rate - 1.0 / 3) < 1e-9)
        #expect(tally.overall.meanDuration == .seconds(2))
        #expect(tally.groups["mild"]?.top1 == 1 && tally.groups["mild"]?.top3 == 2)
        #expect(tally.groups["harsh"]?.top3 == 0)
        #expect(tally.groupNames == ["harsh", "mild"])
        #expect(tally.failures.map(\.file) == ["b.jpg", "c.jpg"])
        #expect(tally.failures[0].rank == 2 && tally.failures[1].rank == 3)
    }

    @Test func labelsSamplesByFileName() {
        let index = CardIndex(canvas: .standard, builtAt: Date(timeIntervalSince1970: 0), entries: [
            CardIndex.Entry(card: TestRig.card("ogn-001-298", code: "OGN-001/298"), descriptor: Self.descriptor),
            CardIndex.Entry(card: TestRig.card("ogn-007a-298", code: "OGN-007a/298"), descriptor: Self.descriptor),
            CardIndex.Entry(card: TestRig.card("rad-r01", code: "RAD-R01"), descriptor: Self.descriptor),
        ])
        #expect(SampleLabel.cardID(forFileName: "ogn-001-298.jpg", in: index)?.rawValue == "ogn-001-298")
        #expect(SampleLabel.cardID(forFileName: "OGN-001-298 (kitchen).HEIC", in: index)?.rawValue == "ogn-001-298")
        #expect(SampleLabel.cardID(forFileName: "OGN-007a-298_desk.png", in: index)?.rawValue == "ogn-007a-298")
        #expect(SampleLabel.cardID(forFileName: "RAD-R01.jpg", in: index)?.rawValue == "rad-r01")
        #expect(SampleLabel.cardID(forFileName: "IMG_0001.jpg", in: index) == nil)
        #expect(SampleLabel.cardID(forFileName: "OGN-999-298.jpg", in: index) == nil)
    }

    private static let descriptor = CardDescriptor(
        wholeDifferenceHash: ImageHash(bits: 0), wholePerceptualHash: ImageHash(bits: 0), artDifferenceHash: ImageHash(bits: 0), featurePrint: FeaturePrint(elements: [1])
    )
}
