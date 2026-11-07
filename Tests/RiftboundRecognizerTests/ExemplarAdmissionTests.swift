import Foundation
import Testing
import RiftboundRecognizer

/// Where the shared fixtures live: `Tests/Fixtures`, beside the test target.
enum Fixtures {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/RiftboundRecognizerTests
        .deletingLastPathComponent()   // Tests
        .appendingPathComponent("Fixtures")

    static func url(_ name: String) -> URL { folder.appendingPathComponent(name) }
}

@Suite("Similarity contract")
struct SimilarityContractTests {
    @Test func roundsHalfToEvenOnTheScaledValue() {
        #expect(SimilarityContract.round(0.62005) == 0.62, "6200.5 rounds to the even 6200")
        #expect(SimilarityContract.round(0.62015) == 0.6202, "6201.5 rounds to the even 6202")
        #expect(SimilarityContract.round(0.123449) == 0.1234)
        #expect(SimilarityContract.round(0.123451) == 0.1235)
        #expect(SimilarityContract.round(1) == 1)
        #expect(SimilarityContract.round(0) == 0)
    }

    @Test func accumulatesInFloat64OverTheStoredFloat32Values() {
        // Three Float32 tenths summed in Float64 land on 0.3 after rounding;
        // the inputs are taken as stored, not re-normalised.
        let a = FeaturePrint(normalizedFloat32Data: Data([0.1, 0.1, 0.1, 0].flatMap { Float($0).bitPattern.littleEndian.bytes }))
        let b = FeaturePrint(normalizedFloat32Data: Data([1, 1, 1, 0].flatMap { Float($0).bitPattern.littleEndian.bytes }))
        #expect(SimilarityContract.similarity(a, b) == 0.3)
        #expect(SimilarityContract.similarity(a, a) == 0.03)
    }

    @Test func clampsAndRefusesMismatchedDimensions() {
        let e0 = FeaturePrint(elements: [1, 0, 0])
        #expect(SimilarityContract.similarity(e0, FeaturePrint(elements: [-1, 0, 0])) == 0)
        #expect(SimilarityContract.similarity(e0, FeaturePrint(elements: [1, 0])) == 0)
        #expect(SimilarityContract.similarity(e0, e0) == 1)
    }

    @Test func fixtureVectorsYieldTheirRecordedSimilarities() throws {
        let fixture = try AdmissionFixture.read(from: Fixtures.url("admission-cases.json"))
        #expect(fixture.contract.decimals == SimilarityContract.decimals)
        #expect(fixture.similarityVectors.count >= 14)
        for vector in fixture.similarityVectors {
            #expect(SimilarityContract.similarity(vector.a, vector.b) == vector.expected, "\(vector.name)")
        }
        // The ± 0.00005 pairs straddle each threshold only after Float32 storage
        // and rounding: a port comparing unrounded Float64 values disagrees.
        let names = Set(fixture.similarityVectors.map(\.name))
        for threshold in ["0.6", "0.62", "0.85", "0.9", "0.985"] {
            #expect(names.contains { $0.hasPrefix("threshold-\(threshold)-minus") } && names.contains { $0.hasPrefix("threshold-\(threshold)-plus") }, "fixture pins \(threshold) ± 0.00005")
        }
    }
}

extension UInt32 {
    fileprivate var bytes: [UInt8] { withUnsafeBytes(of: self) { Array($0) } }
}

@Suite("Exemplar admission gate")
struct ExemplarAdmissionTests {
    static let fixture = try! AdmissionFixture.read(from: Fixtures.url("admission-cases.json"))
    static let calibration = fixture.calibrationHash
    static let gate = ExemplarAdmission(policy: fixture.policy, calibrationHash: calibration)
    static let scan1 = UUID(uuidString: "5CA00000-0000-4000-8000-000000000001")!
    static let scan2 = UUID(uuidString: "5CA00000-0000-4000-8000-000000000002")!
    static let batch = UUID(uuidString: "B0000000-0000-4000-8000-000000000001")!

    /// A unit print whose cosine to `e0` is `c`.
    static func print(_ c: Float, axis: Int = 1) -> FeaturePrint {
        var elements: [Float] = [c, 0, 0, 0]
        elements[axis] = (max(0, 1 - c * c)).squareRoot()
        return FeaturePrint(normalizedFloat32Data: Data(elements.flatMap { withUnsafeBytes(of: $0.bitPattern.littleEndian) { Array($0) } }))
    }

    static let e0 = print(1)

    static func input(
        scan: UUID = scan1,
        source: AdmissionInput.DecisionSource = .human,
        kind: AdmissionInput.DecisionKind = .correct,
        card: String? = "ogn-003-298",
        placement: AdmissionInput.Placement = .detected,
        calibration: FeaturePrint.Digest = calibration,
        quality: AdmissionInput.CaptureQuality = .standard,
        training: AdmissionInput.CaptureQuality = .standard,
        code: AdmissionInput.CodeEvidence? = AdmissionInput.CodeEvidence(source: .edgeBand, origin: .literal, agreement: .exact),
        reference: Double = 0.80,
        alternatives: [AdmissionInput.CodeAlternative] = [],
        print: FeaturePrint = e0
    ) -> AdmissionInput {
        AdmissionInput(
            scanID: scan, batchID: batch, decisionSource: source, decisionKind: kind, cardID: card.map(Card.ID.init(rawValue:)),
            placement: placement, calibrationHash: calibration, captureQuality: quality, trainingQuality: training,
            code: code, referenceSimilarity: reference, codeAlternatives: alternatives, featurePrint: print
        )
    }

    // MARK: The shared fixture

    @Test func everyFixtureCaseYieldsItsExpectedOutcome() {
        let fixture = Self.fixture
        #expect(fixture.gateVersion == ExemplarAdmission.gateVersion)
        #expect(fixture.cases.count >= 50)
        for fixtureCase in fixture.cases {
            let outcome = fixture.request(for: fixtureCase).decide()
            #expect(outcome == fixtureCase.expected, "\(fixtureCase.name): got \(outcome)")
        }
    }

    @Test func fixtureCoversEveryRejectionReasonAndOutcome() {
        let outcomes = Self.fixture.cases.map(\.expected)
        for reason in AdmissionOutcome.RejectionReason.allCases {
            #expect(outcomes.contains(.rejected(reason)), "no fixture case rejects with \(reason)")
        }
        #expect(outcomes.contains(.needsSecondWitness))
        #expect(outcomes.contains { if case .blocked = $0 { true } else { false } })
        #expect(outcomes.contains { if case .duplicate = $0 { true } else { false } })
        #expect(outcomes.contains { $0.tier == .code } && outcomes.contains { $0.tier == .artCorroborated })
        #expect(Self.fixture.cases.filter { $0.name.hasPrefix("edge-") }.count >= 10, "threshold-edge vectors are part of the fixture")
        let names = Set(Self.fixture.cases.map(\.name))
        #expect(names.contains("code-alternative-margin-0.70-vs-0.65-admits") && names.contains("code-alternative-margin-0.70-vs-0.6501-rejected"), "the fixture pins the rounded margin difference, which a port comparing raw doubles fails")
    }

    @Test func fixtureRoundTripsThroughItsCodableShapes() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for fixtureCase in Self.fixture.cases {
            let request = Self.fixture.request(for: fixtureCase)
            let decoded = try JSONDecoder().decode(AdmissionRequest.self, from: try encoder.encode(request))
            #expect(decoded == request, "\(fixtureCase.name)")
            let outcome = try JSONDecoder().decode(AdmissionOutcome.self, from: try encoder.encode(fixtureCase.expected))
            #expect(outcome == fixtureCase.expected, "\(fixtureCase.name)")
        }
        let json = try #require(try JSONSerialization.jsonObject(with: try encoder.encode(Self.fixture.request(for: Self.fixture.cases[0]))) as? [String: Any])
        #expect(Set(json.keys) == ["gateVersion", "calibrationHash", "policy", "candidate", "witnesses", "existing"])
        let candidate = try #require(json["candidate"] as? [String: Any])
        #expect(candidate["featurePrint"] is String, "prints travel as base64 Float32 like every other print")
        #expect(candidate["calibrationHash"] as? String == Self.calibration.hex)
    }

    @Test func outcomeJSONIsFlat() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let admitted = String(decoding: try encoder.encode(AdmissionOutcome.admitted(tier: .code, corroborators: [], evicted: [Self.scan2])), as: UTF8.self)
        #expect(admitted == #"{"corroborators":[],"evicted":["5CA00000-0000-4000-8000-000000000002"],"outcome":"admitted","tier":"code"}"#)
        let rejected = String(decoding: try encoder.encode(AdmissionOutcome.rejected(.placement)), as: UTF8.self)
        #expect(rejected == #"{"outcome":"rejected","reason":"placement"}"#)
        let blocked = String(decoding: try encoder.encode(AdmissionOutcome.blocked(by: Self.scan2, similarity: 0.93)), as: UTF8.self)
        #expect(blocked == #"{"blockingScanID":"5CA00000-0000-4000-8000-000000000002","outcome":"blocked","similarity":0.93}"#)
        #expect(String(decoding: try encoder.encode(AdmissionOutcome.needsSecondWitness), as: UTF8.self) == #"{"outcome":"needsSecondWitness"}"#)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(AdmissionOutcome.self, from: Data(#"{"outcome":"maybe"}"#.utf8)) }
    }

    @Test func gateDiffInputsAreToldApartByShapeAndReportTheirOwnErrors() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("admission-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        guard case .fixture(let fixture) = try AdmissionFile.read(from: Fixtures.url("admission-cases.json")) else {
            Issue.record("the shared fixture reads as a fixture")
            return
        }
        #expect(fixture.cases.count == Self.fixture.cases.count)

        // A fixture with one hand-edited bad outcome is still a fixture: the error names the outcome, not the dump format.
        var object = try #require(try JSONSerialization.jsonObject(with: try Data(contentsOf: Fixtures.url("admission-cases.json"))) as? [String: Any])
        var cases = try #require(object["cases"] as? [[String: Any]])
        cases[0]["expected"] = ["outcome": "maybe"]
        object["cases"] = cases
        let malformed = folder.appendingPathComponent("malformed.json")
        try JSONSerialization.data(withJSONObject: object).write(to: malformed)
        let error = #expect(throws: DecodingError.self) { try AdmissionFile.read(from: malformed) }
        #expect("\(try #require(error))".contains("maybe"), "the fixture's own decoding error surfaces")

        // A dump is recognised by its keys and decoded with its date strategy.
        let engine = EngineFingerprint(packageVersion: "test", calibrationHash: Self.calibration, platform: "test", osVersion: "0")
        let dumpURL = folder.appendingPathComponent("admissions.json")
        try AdmissionDump(generatedAt: Date(timeIntervalSince1970: 0), engine: engine, policy: Self.fixture.policy, analyses: [], folds: []).write(to: dumpURL)
        guard case .dump(let dump) = try AdmissionFile.read(from: dumpURL) else {
            Issue.record("a build-overlay dump reads as a dump")
            return
        }
        #expect(dump.policy == Self.fixture.policy && dump.assumptions.isStrict)

        // Anything else is refused by name.
        let other = folder.appendingPathComponent("other.json")
        try Data(#"{"hello": 1}"#.utf8).write(to: other)
        #expect(throws: AdmissionFile.UnrecognisedShape.self) { try AdmissionFile.read(from: other) }
    }

    @Test func assumptionsSubstituteTheDerivedCaptureQualityOnlyWhenAsked() throws {
        let legacy = Self.input(source: .legacy, quality: .legacy, training: .legacy)
        let analysed = AnalysedScan(input: legacy, file: "x.jpg", group: "Testing", bestOtherReferenceSimilarity: 0.5, bestOtherArtGroup: nil, topCardID: nil, codeRead: nil, derivedCaptureQuality: .standard)
        #expect(AdmissionDump.Assumptions.none.apply(to: analysed) == legacy, "strict: the input as the app would see it")
        let derived = AdmissionDump.Assumptions(deriveCaptureQuality: true).apply(to: analysed)
        #expect(derived.captureQuality == .standard && derived.decisionSource == .legacy && derived.trainingQuality == .legacy)
        let relaxed = AdmissionDump.Assumptions(acceptLegacyDecisions: true, trainingQuality: .standard, deriveCaptureQuality: true).apply(to: analysed)
        #expect(relaxed.decisionSource == .human && relaxed.captureQuality == .standard && relaxed.trainingQuality == .standard)
        #expect(Self.gate.decide(derived) == .rejected(.decisionSource) && Self.gate.decide(relaxed).isAdmitted)
        let unknown = AnalysedScan(input: legacy, file: "x.jpg", group: "Testing", bestOtherReferenceSimilarity: 0.5, bestOtherArtGroup: nil, topCardID: nil, codeRead: nil, derivedCaptureQuality: nil)
        #expect(AdmissionDump.Assumptions(deriveCaptureQuality: true).apply(to: unknown).captureQuality == .legacy, "nothing derivable keeps the record's quality")
        let encoded = try JSONEncoder().encode(AdmissionDump.Assumptions(acceptLegacyDecisions: true, deriveCaptureQuality: true))
        #expect(try JSONDecoder().decode(AdmissionDump.Assumptions.self, from: encoded).deriveCaptureQuality)
        let old = try JSONDecoder().decode(AdmissionDump.Assumptions.self, from: Data(#"{"acceptLegacyDecisions":true}"#.utf8))
        #expect(old.acceptLegacyDecisions && !old.deriveCaptureQuality, "a dump written before the flag existed reads")
        #expect(AdmissionDump.Assumptions(deriveCaptureQuality: true).description.contains("derived"))
    }

    // MARK: Acceptance clauses, spelled out

    @Test func aTrayCanvasAt055IsRejectedByTheFloor() {
        #expect(Self.gate.decide(Self.input(reference: 0.55)) == .rejected(.referenceBelowFloor))
        #expect(Self.gate.decide(Self.input(reference: 0.62)).isAdmitted, "the floor is inclusive")
    }

    @Test func wholeImagePlacementIsRejected() {
        #expect(Self.gate.decide(Self.input(placement: .wholeImage)) == .rejected(.placement))
        #expect(Self.gate.ineligibility(of: Self.input(placement: .wholeImage)) == .placement)
    }

    @Test func machineAndLegacyDecisionsNeverAdmit() {
        for source in [AdmissionInput.DecisionSource.autoAccepted, .legacy] {
            #expect(Self.gate.decide(Self.input(source: source)) == .rejected(.decisionSource))
        }
        for source in [AdmissionInput.DecisionSource.human, .audit, .spotCheck] {
            #expect(Self.gate.decide(Self.input(source: source)).tier == .code)
        }
    }

    @Test func exactLiteralEdgeBandCodeAt080NeedsAMarginOverOtherGroupAlternatives() {
        func alternatives(_ other: Double) -> [AdmissionInput.CodeAlternative] {
            [
                AdmissionInput.CodeAlternative(code: TestRig.code("SFD-014/221"), origin: .literal, referenceSimilarity: 0.80),
                AdmissionInput.CodeAlternative(code: TestRig.code("SFD-024/221"), origin: .alternative, referenceSimilarity: other),
            ]
        }
        let margin16 = Self.input(card: "sfd-014-221", reference: 0.80, alternatives: alternatives(0.64))
        #expect(Self.gate.decide(margin16) == .admitted(tier: .code, corroborators: [], evicted: []))
        let margin04 = Self.input(card: "sfd-014-221", reference: 0.80, alternatives: alternatives(0.76))
        #expect(Self.gate.decide(margin04) == .rejected(.alternativeMargin))
        let sameGroup = Self.input(card: "sfd-014-221", reference: 0.80, alternatives: [
            AdmissionInput.CodeAlternative(code: TestRig.code("SFD-014a/221"), origin: .alternative, referenceSimilarity: 0.79),
        ])
        #expect(Self.gate.decide(sameGroup).isAdmitted, "a sibling printing of the same art is not an impostor")
    }

    @Test func theAlternativeMarginIsRoundedBeforeItMeetsTheThreshold() {
        // In binary doubles 0.85 - 0.80, 0.70 - 0.65 and 0.95 - 0.90 are all
        // 0.04999..., while 0.80 - 0.75 is 0.05000...04: an unrounded
        // comparison admits by operand luck. The contract rounds the
        // difference, so every exact 0.05 margin admits and 0.0499 does not.
        func decide(reference: Double, other: Double) -> AdmissionOutcome {
            Self.gate.decide(Self.input(card: "sfd-014-221", reference: reference, alternatives: [
                AdmissionInput.CodeAlternative(code: TestRig.code("SFD-014/221"), origin: .literal, referenceSimilarity: reference),
                AdmissionInput.CodeAlternative(code: TestRig.code("SFD-024/221"), origin: .alternative, referenceSimilarity: other),
            ]))
        }
        for (reference, other) in [(0.85, 0.80), (0.70, 0.65), (0.95, 0.90), (0.73, 0.68), (0.80, 0.75)] {
            #expect(reference - other < 0.05 || reference - other > 0.05, "\(reference) - \(other) is not exactly 0.05 in binary")
            #expect(decide(reference: reference, other: other) == .admitted(tier: .code, corroborators: [], evicted: []), "\(reference) vs \(other) is a 0.05 margin")
        }
        #expect(decide(reference: 0.70, other: 0.6501) == .rejected(.alternativeMargin), "0.0499 is under the margin")
        #expect(decide(reference: 0.70, other: 0.65005) == .admitted(tier: .code, corroborators: [], evicted: []), "0.65005 rounds (half to even) to 0.65")
        #expect(decide(reference: 0.70, other: 0.65015) == .rejected(.alternativeMargin), "0.65015 rounds to 0.6502")
    }

    @Test func anAlternativeWonCodeIsRejected() {
        let repaired = AdmissionInput.CodeEvidence(source: .edgeBand, origin: .alternative, agreement: .exact)
        #expect(Self.gate.decide(Self.input(code: repaired)) == .rejected(.codeNotLiteral))
        let fullImage = AdmissionInput.CodeEvidence(source: .fullImage, origin: .literal, agreement: .exact)
        #expect(Self.gate.decide(Self.input(code: fullImage)) == .rejected(.codeSource))
        let disagreeing = AdmissionInput.CodeEvidence(source: .edgeBand, origin: .literal, agreement: .numberDiffers)
        #expect(Self.gate.decide(Self.input(code: disagreeing)) == .rejected(.codeDisagrees))
    }

    @Test func aCodelessCorrectedScanNeedsASecondWitnessAndIsArtCorroboratedWithOne() {
        let candidate = Self.input(kind: .corrected, code: nil, reference: 0.70)
        #expect(Self.gate.decide(candidate) == .needsSecondWitness)
        let witness = Self.input(scan: Self.scan2, kind: .corrected, code: nil, reference: 0.66, print: Self.print(0.90))
        #expect(Self.gate.decide(candidate, witnesses: [witness]) == .admitted(tier: .artCorroborated, corroborators: [Self.scan2], evicted: []))
        #expect(Self.gate.decide(witness, witnesses: [candidate]) == .admitted(tier: .artCorroborated, corroborators: [Self.scan1], evicted: []), "the witness is admitted together with it")

        let farWitness = Self.input(scan: Self.scan2, kind: .corrected, code: nil, reference: 0.66, print: Self.print(0.80))
        #expect(Self.gate.decide(candidate, witnesses: [farWitness]) == .needsSecondWitness)
        let weakWitness = Self.input(scan: Self.scan2, kind: .corrected, code: nil, reference: 0.59, print: Self.print(0.90))
        #expect(Self.gate.decide(candidate, witnesses: [weakWitness]) == .needsSecondWitness)
        let sameCapture = Self.input(scan: Self.scan1, kind: .corrected, code: nil, reference: 0.66, print: Self.print(0.90))
        #expect(Self.gate.decide(candidate, witnesses: [sameCapture]) == .needsSecondWitness, "a witness must be another capture")
        let codedWitness = Self.input(scan: Self.scan2, kind: .corrected, reference: 0.66, print: Self.print(0.90))
        #expect(Self.gate.decide(candidate, witnesses: [codedWitness]) == .needsSecondWitness, "a scan with a code is not a codeless witness")
        #expect(Self.gate.decide(Self.input(kind: .corrected, code: nil, reference: 0.59), witnesses: [witness]) == .rejected(.witnessReferenceBelowFloor))
    }

    @Test func impostorsBlockAndDuplicatesAreNamed() {
        let group = ArtGroup(rawValue: "ogn-003")
        let other = ArtGroup(rawValue: "ogn-250")
        let impostor = ExistingExemplar(scanID: Self.scan2, artGroup: other, featurePrint: Self.print(0.93, axis: 2), referenceSimilarity: 0.7)
        let blocked = Self.gate.decide(Self.input(), existing: [impostor])
        guard case .blocked(let by, let similarity) = blocked else {
            Issue.record("expected blocked, got \(blocked)")
            return
        }
        #expect(by == Self.scan2 && abs(similarity - 0.93) < 0.0002)
        let twin = ExistingExemplar(scanID: Self.scan2, artGroup: group, featurePrint: Self.print(0.99, axis: 2), referenceSimilarity: 0.7)
        guard case .duplicate(let of, _) = Self.gate.decide(Self.input(), existing: [twin]) else {
            Issue.record("expected duplicate")
            return
        }
        #expect(of == Self.scan2)
        let near = ExistingExemplar(scanID: Self.scan2, artGroup: group, featurePrint: Self.print(0.97, axis: 2), referenceSimilarity: 0.7)
        #expect(Self.gate.decide(Self.input(), existing: [near]).isAdmitted)
        let far = ExistingExemplar(scanID: Self.scan2, artGroup: other, featurePrint: Self.print(0.85, axis: 2), referenceSimilarity: 0.7)
        #expect(Self.gate.decide(Self.input(), existing: [far]).isAdmitted)
    }

    @Test func theCapKeepsTheMedoid() {
        let group = ArtGroup(rawValue: "ogn-003")
        let t = Float(20 * Double.pi / 180)
        func unit(_ e: [Float]) -> FeaturePrint {
            FeaturePrint(normalizedFloat32Data: Data(e.flatMap { withUnsafeBytes(of: $0.bitPattern.littleEndian) { Array($0) } }))
        }
        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "E0000000-0000-4000-8000-%012d", n))! }
        let medoid = ExistingExemplar(scanID: id(1), artGroup: group, featurePrint: unit([1, 0, 0, 0]), referenceSimilarity: 0.70)
        let members = [
            medoid,
            ExistingExemplar(scanID: id(2), artGroup: group, featurePrint: unit([cos(t), sin(t), 0, 0]), referenceSimilarity: 0.75),
            ExistingExemplar(scanID: id(3), artGroup: group, featurePrint: unit([cos(t), -sin(t), 0, 0]), referenceSimilarity: 0.72),
            ExistingExemplar(scanID: id(4), artGroup: group, featurePrint: unit([cos(t), 0, sin(t), 0]), referenceSimilarity: 0.68),
            ExistingExemplar(scanID: id(5), artGroup: group, featurePrint: unit([cos(t), 0, -sin(t), 0]), referenceSimilarity: 0.66),
            ExistingExemplar(scanID: id(6), artGroup: group, featurePrint: unit([cos(t), 0, 0, sin(t)]), referenceSimilarity: 0.64),
        ]
        let varied = Self.input(scan: id(7), reference: 0.80, print: unit([cos(t), 0, 0, -sin(t)]))
        let outcome = Self.gate.decide(varied, existing: members)
        #expect(outcome == .admitted(tier: .code, corroborators: [], evicted: [id(6)]), "\(outcome)")
        let kept = ExemplarAdmission.select(from: members + [ExistingExemplar(admitting: varied, artGroup: group)], cap: 6)
        #expect(kept.contains(medoid.scanID) && kept.contains(id(7)) && !kept.contains(id(6)) && kept.count == 6)

        let u = Float(32 * Double.pi / 180)
        let crowded = Self.input(scan: id(7), reference: 0.63, print: unit([cos(u), sin(u), 0, 0]))
        #expect(Self.gate.decide(crowded, existing: members) == .rejected(.capReached))
        let keptWithoutIt = ExemplarAdmission.select(from: members + [ExistingExemplar(admitting: crowded, artGroup: group)], cap: 6)
        #expect(keptWithoutIt == Set(members.map(\.scanID)), "the medoid and every existing member stay")
        #expect(Self.gate.decide(crowded, existing: Array(members.prefix(5))).isAdmitted, "below the cap nothing is selected away")
        #expect(ExemplarAdmission.select(from: members, cap: 6) == Set(members.map(\.scanID)), "a group at the cap is left alone")
    }

    // MARK: Runs

    @Test func aRunGatesCodedScansFirstThenCodelessOnesWithWitnesses() {
        let scan3 = UUID(uuidString: "5CA00000-0000-4000-8000-000000000003")!
        let scan4 = UUID(uuidString: "5CA00000-0000-4000-8000-000000000004")!
        let inputs = [
            Self.input(scan: Self.scan1, kind: .corrected, code: nil, reference: 0.70),
            Self.input(scan: Self.scan2, kind: .corrected, code: nil, reference: 0.66, print: Self.print(0.90)),
            Self.input(scan: scan3, card: "ogn-005-298", print: Self.print(0.2, axis: 2)),
            Self.input(scan: scan4, source: .autoAccepted),
        ]
        let run = Self.gate.run(inputs)
        #expect(run.records.map(\.scanID) == inputs.map(\.scanID), "records come back in input order")
        #expect(run.records[0].outcome == .admitted(tier: .artCorroborated, corroborators: [Self.scan2], evicted: []))
        #expect(run.records[1].outcome == .admitted(tier: .artCorroborated, corroborators: [Self.scan1], evicted: []), "the witness is admitted together with the first (0.90 is under the 0.985 dedupe)")
        #expect(run.records[2].outcome == .admitted(tier: .code, corroborators: [], evicted: []))
        #expect(run.records[3].outcome == .rejected(.decisionSource))
        #expect(run.exemplars.map(\.scanID).contains(scan3) && run.exemplars.map(\.scanID).contains(Self.scan1))
        let steps = Self.gate.replay(inputs)
        #expect(steps.map(\.request.candidate.scanID) == [scan3, scan4, Self.scan1, Self.scan2], "coded scans are gated first")
        #expect(steps[2].request.witnesses.map(\.scanID) == [Self.scan2])
        #expect(steps[3].request.existing.map(\.scanID) == [scan3, Self.scan1], "the second codeless scan sees the first as an existing exemplar")
    }
}
