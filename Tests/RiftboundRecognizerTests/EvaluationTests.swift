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

    @Test func weightsCasesAndTracksTheConfidentTier() {
        var tally = EvaluationTally()
        let reviewed = EvaluationCase(file: "a.jpg", expected: id("a"), group: "box", samplingWeight: 1)
        let audit = EvaluationCase(file: "b.jpg", expected: id("b"), group: "box", samplingWeight: 1 / 0.3)
        let miss = EvaluationCase(file: "c.jpg", expected: id("c"), group: "box", samplingWeight: 1)
        tally.record(reviewed, ranked: [id("a"), id("b")], duration: .seconds(1), confident: true, exemplarHit: true)
        tally.record(audit, ranked: [id("b")], duration: .seconds(1), confident: true, exemplarHit: false)
        tally.record(miss, ranked: [id("x"), id("c")], duration: .seconds(1), confident: true, exemplarHit: false)

        let overall = tally.overall
        #expect(overall.total == 3 && overall.top1 == 2 && overall.top3 == 3)
        #expect(abs(overall.weight - (2 + 1 / 0.3)) < 1e-9)
        #expect(abs(overall.weightedTop1Rate - (1 + 1 / 0.3) / (2 + 1 / 0.3)) < 1e-9, "the audit case counts 1/auditRate")
        #expect(abs(overall.top1Rate - 2.0 / 3) < 1e-9, "the raw rate counts cases")
        #expect(overall.confident == 3 && overall.confidentCorrect == 2)
        #expect(abs(overall.confidentPrecision - 2.0 / 3) < 1e-9 && abs(overall.confidentCoverage - 1) < 1e-9)
        #expect(abs(overall.weightedConfidentPrecision - (1 + 1 / 0.3) / (2 + 1 / 0.3)) < 1e-9)
        #expect(overall.exemplarHits == 1 && abs(overall.exemplarHitRate - 1.0 / 3) < 1e-9)
        #expect(tally.failures.count == 1 && tally.failures[0].confident, "a confident miss is flagged")
        #expect(overall.confidentPrecisionLowerBound < overall.confidentPrecision && overall.confidentPrecisionLowerBound > 0)

        var plain = EvaluationTally()
        plain.record(reviewed, ranked: [id("a")], duration: .zero)
        #expect(plain.overall.confident == 0 && plain.overall.weight == 1, "the old entry point records an unweighted, unjudged case")
    }

    @Test func wilsonLowerBoundMatchesTheDesignFigures() {
        // Decision 9: 150/150 correct audits bound precision to about 97.5 %.
        #expect(abs(Statistics.wilsonLowerBound(successes: 150, trials: 150) - 0.9752) < 0.001)
        #expect(Statistics.wilsonLowerBound(successes: 0, trials: 0) == 0)
        #expect(Statistics.wilsonLowerBound(successes: 0, trials: 10) == 0)
        #expect(Statistics.wilsonLowerBound(successes: 95, trials: 100) < 0.95)
        #expect(Statistics.percentile([0.1, 0.9, 0.5, 0.7], 0.5) == 0.5)
        #expect(Statistics.percentile([0.1, 0.9, 0.5, 0.7], 0.99) == 0.9)
        #expect(Statistics.percentile([], 0.5) == 0)
    }

    @Test func dumpsTallyBackToTheSameNumbers() throws {
        let engine = EngineFingerprint(packageVersion: "test", calibrationHash: FeaturePrint(elements: [1, 0]).digest, platform: "test", osVersion: "0")
        let entry = EvaluationDump.RankedEntry(id: id("a"), score: 1.4, referenceScore: 0.8, fusedScore: 0.9, exemplarSimilarity: 0.95, codeAgreement: .exact)
        let other = EvaluationDump.RankedEntry(id: id("b"), score: 0.5, referenceScore: 0.5, fusedScore: 0.5, exemplarSimilarity: nil, codeAgreement: .unrelated)
        let hit = EvaluationDump.CaseResult(evaluationCase: EvaluationCase(file: "a.jpg", expected: id("a"), group: "box"), ranked: [entry, other], codeRead: TestRig.code("OGN-001/298"), codeSource: .edgeBand, codeConfidence: 1, placement: .detected, verdict: .confident, seconds: 0.5)
        let miss = EvaluationDump.CaseResult(evaluationCase: EvaluationCase(file: "b.jpg", expected: id("b"), group: "box", samplingWeight: 2), ranked: [other, entry], codeRead: nil, codeSource: nil, codeConfidence: nil, placement: .wholeImage, verdict: .uncertain(.noCode), seconds: 0.5)
        #expect(hit.exemplarHit && hit.isCorrect && hit.rank == 0)
        #expect(miss.exemplarHit == false && miss.rank == 0, "the expected card ranked first even though the tally's expected differs")
        let dump = EvaluationDump(generatedAt: Date(timeIntervalSince1970: 0), label: "test", engine: engine, indexEntryCount: 2, overlayVersion: 3, overlayExemplars: 1, excludedBatches: [], policyVersion: 1, cases: [hit, miss])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dump-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try dump.write(to: url)
        let reloaded = try EvaluationDump.read(from: url)
        #expect(reloaded.cases == dump.cases && reloaded.label == "test" && reloaded.overlayVersion == 3)
        let tally = reloaded.tally()
        #expect(tally.overall.total == 2 && tally.overall.top1 == 2 && tally.overall.weight == 3)
        #expect(tally.overall.confident == 1 && tally.overall.confidentCorrect == 1 && tally.overall.exemplarHits == 1)
        let json = try #require(try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        let cases = try #require(json["cases"] as? [[String: Any]])
        #expect(cases[1]["confident"] as? Bool == false && cases[1]["uncertaintyReason"] as? String == "noCode")
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

    @Test func aComparisonTalliesOnlyTheCasesBothDumpsHold() {
        let engine = EngineFingerprint(packageVersion: "test", calibrationHash: FeaturePrint(elements: [1, 0]).digest, platform: "test", osVersion: "0")
        func result(_ file: String, correct: Bool) -> EvaluationDump.CaseResult {
            let expected = id("a")
            let ranked = [EvaluationDump.RankedEntry(id: correct ? expected : id("b"), score: 1, referenceScore: 0.8, fusedScore: 0.8, exemplarSimilarity: nil, codeAgreement: nil)]
            return EvaluationDump.CaseResult(evaluationCase: EvaluationCase(file: file, expected: expected, group: "box"), ranked: ranked, codeRead: nil, codeSource: nil, codeConfidence: nil, placement: .detected, verdict: .uncertain(.noCode), seconds: 0)
        }
        func dump(_ label: String, _ results: [EvaluationDump.CaseResult]) -> EvaluationDump {
            EvaluationDump(generatedAt: Date(timeIntervalSince1970: 0), label: label, engine: engine, indexEntryCount: 2, overlayVersion: 0, overlayExemplars: 0, excludedBatches: [], policyVersion: 1, cases: results)
        }
        // The baseline covers everything; the fold dump was run with a different --limit and holds a case the baseline lacks.
        let baseline = dump("baseline", [result("a.jpg", correct: true), result("b.jpg", correct: false), result("c.jpg", correct: true)])
        let fold = dump("fold", [result("a.jpg", correct: true), result("b.jpg", correct: true), result("z.jpg", correct: false)])
        let (before, after) = EvaluationDump.shared(baseline, fold)
        #expect(before.cases.map(\.evaluationCase.file) == ["a.jpg", "b.jpg"] && after.cases.map(\.evaluationCase.file) == ["a.jpg", "b.jpg"])
        #expect(before.tally().overall.top1Rate == 0.5 && after.tally().overall.top1Rate == 1, "z.jpg, which the baseline never saw, does not drag the fold's rate down")
        #expect(before.label == "baseline" && after.label == "fold" && after.engine == engine)
        #expect(fold.restricted(to: []).cases.isEmpty && fold.restricted(to: ["z.jpg"]).cases.count == 1)
    }

    private static let descriptor = CardDescriptor(
        wholeDifferenceHash: ImageHash(bits: 0), wholePerceptualHash: ImageHash(bits: 0), artDifferenceHash: ImageHash(bits: 0), featurePrint: FeaturePrint(elements: [1])
    )
}
