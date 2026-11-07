import Foundation
import Testing
import RiftboundRecognizer

@Suite("Art groups")
struct ArtGroupTests {
    @Test("strips the total and the a/* suffix", arguments: [
        ("ogn-001-298", "ogn-001"),
        ("ogn-007a-298", "ogn-007"),
        ("sfd-227*-221", "sfd-227"),
        ("ven-038a-166", "ven-038"),
        ("rad-r01a", "rad-r01"),
        ("rad-r01", "rad-r01"),
        ("unl-t01", "unl-t01"),
        ("sfd-t03", "sfd-t03"),
        ("ogn-299*-298", "ogn-299"),
    ])
    func groups(id: String, expected: String) {
        #expect(ArtGroup(Card.ID(rawValue: id)).rawValue == expected)
    }

    @Test("leaves an id it does not understand alone", arguments: ["", "OGN-001/298", "ogn-001-298-extra", "ogn--298", "og1-001", "ogn-0001-298"])
    func unknownShapes(id: String) {
        #expect(ArtGroup(Card.ID(rawValue: id)).rawValue == id)
    }

    @Test func agreesBetweenIdAndPrintedCode() {
        let card = TestRig.card("sfd-227*-221", code: "SFD-227*/221", printing: [.signature])
        #expect(card.artGroup == ArtGroup(code: card.code))
        #expect(ArtGroup(code: TestRig.code("RAD-R01")) == ArtGroup(rawValue: "rad-r01"))
        #expect(ArtGroup(code: TestRig.code("OGN • 007a/298")) == ArtGroup(Card.ID(rawValue: "ogn-007a-298")))
    }

    @Test func encodesAsItsString() throws {
        let encoded = try JSONEncoder().encode([ArtGroup(rawValue: "ogn-007")])
        #expect(String(decoding: encoded, as: UTF8.self) == #"["ogn-007"]"#)
        #expect(try JSONDecoder().decode([ArtGroup].self, from: encoded) == [ArtGroup(rawValue: "ogn-007")])
    }
}

@Suite("Exemplar index")
struct ExemplarIndexTests {
    static let calibration = FeaturePrint(elements: [3, 4, 0])
    static let batchA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    static let batchB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
    static let admitted = Date(timeIntervalSince1970: 1_762_000_000.5)

    static func exemplar(_ group: String, print: [Float], scan: Int, batch: UUID = batchA) -> ExemplarIndex.Exemplar {
        ExemplarIndex.Exemplar(
            artGroup: ArtGroup(rawValue: group),
            featurePrint: FeaturePrint(elements: print),
            scanID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", scan))!,
            batchID: batch,
            admittedAt: admitted.addingTimeInterval(Double(scan))
        )
    }

    static let sample = ExemplarIndex(version: 7, calibrationPrint: calibration, exemplars: [
        exemplar("ogn-003", print: [1, 0, 0], scan: 1),
        exemplar("ogn-003", print: [0.8, 0.6, 0], scan: 2, batch: batchB),
        exemplar("ogn-005", print: [0, 0, 1], scan: 3, batch: batchB),
    ])

    @Test func emptyHasNothing() {
        #expect(ExemplarIndex.empty.isEmpty)
        #expect(ExemplarIndex.empty.version == 0)
        #expect(ExemplarIndex.empty.calibrationPrint == nil && ExemplarIndex.empty.calibrationHash == nil)
        #expect(ExemplarIndex.empty.dimension == nil)
        #expect(ExemplarIndex.empty.formatVersion == 2)
    }

    @Test func roundTripsThroughTheDocumentedJSON() throws {
        let data = try Self.sample.encoded()
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["formatVersion"] as? Int == 2)
        #expect(json["version"] as? Int == 7)
        #expect(json["calibrationPrint"] is String, "base64 Float32 bytes like every print")
        let exemplars = try #require(json["exemplars"] as? [[String: Any]])
        #expect(exemplars.count == 3)
        #expect(Set(exemplars[0].keys) == ["artGroup", "featurePrint", "scanID", "batchID", "admittedAt"])
        #expect(exemplars[0]["artGroup"] as? String == "ogn-003")
        #expect(exemplars[0]["scanID"] as? String == "00000000-0000-0000-0000-000000000001")
        #expect((exemplars[0]["admittedAt"] as? String)?.hasPrefix("2025-11-01T") == true, "ISO 8601")

        let decoded = try ExemplarIndex.decode(data)
        #expect(decoded.version == 7)
        #expect(decoded.calibrationPrint == Self.calibration)
        #expect(decoded.calibrationHash == Self.calibration.digest)
        #expect(decoded.exemplars.map(\.artGroup) == Self.sample.exemplars.map(\.artGroup))
        #expect(decoded.exemplars.map(\.featurePrint) == Self.sample.exemplars.map(\.featurePrint))
        #expect(decoded.exemplars.map(\.scanID) == Self.sample.exemplars.map(\.scanID))
        #expect(decoded.exemplars.map(\.batchID) == Self.sample.exemplars.map(\.batchID))
        // ISO 8601 carries whole seconds; the half second is lost on the wire by design.
        #expect(decoded.exemplars.map { $0.admittedAt.timeIntervalSince1970 } == Self.sample.exemplars.map { $0.admittedAt.timeIntervalSince1970.rounded(.down) })
        #expect(decoded.exemplarsByGroup[ArtGroup(rawValue: "ogn-003")]?.count == 2)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("riftbound-overlay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("overlay.json")
        try Self.sample.write(to: file)
        #expect(try ExemplarIndex.read(from: file) == decoded)
    }

    @Test func refusesOtherFormatVersions() {
        let data = Data(#"{"formatVersion":1,"version":1,"exemplars":[]}"#.utf8)
        #expect(throws: ExemplarIndexError.unsupportedFormat(found: 1, expected: 2)) {
            try ExemplarIndex.decode(data)
        }
    }

    @Test func excludingBatchesDropsTheirExemplars() {
        let without = Self.sample.excluding(batches: [Self.batchB])
        #expect(without.exemplars.map(\.scanID) == [Self.sample.exemplars[0].scanID])
        #expect(without.version == 7 && without.calibrationPrint == Self.calibration, "only the exemplars change")
        #expect(Self.sample.excluding(batches: []) == Self.sample)
        #expect(Self.sample.excluding(batches: [Self.batchA, Self.batchB]).isEmpty)
        #expect(Self.sample.excluding(batches: [UUID()]) == Self.sample, "an unknown batch excludes nothing")
    }

    @Test func compatibilityNeedsTheSamePrintAndDimension() {
        let same = FeaturePrint(elements: [3, 4, 0])
        let scaled = FeaturePrint(elements: [6, 8, 0])
        let other = FeaturePrint(elements: [0, 0, 1])
        let nearby = FeaturePrint(elements: [3, 4, 0.5])
        let wider = FeaturePrint(elements: [3, 4, 0, 0])

        #expect(Self.sample.isCompatible(calibrationPrint: same, minimum: 0.95))
        #expect(Self.sample.compatibility(with: scaled, minimum: 0.95) == .compatible(similarity: 1), "prints are unit-normalised")
        #expect(Self.sample.isCompatible(calibrationPrint: other, minimum: 0.95) == false)
        #expect(Self.sample.compatibility(with: other, minimum: 0.95) == .embeddingChanged(similarity: 0))
        #expect(Self.sample.isCompatible(calibrationPrint: wider, minimum: 0.95) == false)
        #expect(Self.sample.compatibility(with: wider, minimum: 0.95) == .dimensionMismatch(overlay: 3, device: 4))

        let similarity = Self.calibration.similarity(to: nearby)
        #expect(similarity > 0.99 && similarity < 1)
        #expect(Self.sample.isCompatible(calibrationPrint: nearby, minimum: 0.99))
        #expect(Self.sample.isCompatible(calibrationPrint: nearby, minimum: 1.0) == false, "the minimum is a policy value")
        #expect(Self.sample.isCompatible(calibrationPrint: nearby, minimum: LearningPolicy.default.calibrationMinimum))

        #expect(ExemplarIndex.empty.isCompatible(calibrationPrint: wider, minimum: 1), "nothing to compare")
        let uncalibrated = ExemplarIndex(version: 1, calibrationPrint: nil, exemplars: Self.sample.exemplars)
        #expect(uncalibrated.compatibility(with: same, minimum: 0.5) == .uncalibrated)
        #expect(uncalibrated.isCompatible(calibrationPrint: same, minimum: 0) == false)

        let mixed = ExemplarIndex(version: 1, calibrationPrint: Self.calibration, exemplars: [Self.exemplar("x", print: [1, 0, 0, 0], scan: 9)])
        #expect(mixed.compatibility(with: same, minimum: 0.5) == .dimensionMismatch(overlay: 4, device: 3), "an exemplar in another dimension is just as incompatible")
    }

    @Test func appliesADelta() throws {
        let replacement = Self.exemplar("ogn-003", print: [0, 1, 0], scan: 2)
        let added = Self.exemplar("ogn-009", print: [0.6, 0, 0.8], scan: 4)
        let delta = ExemplarDelta(baseVersion: 7, version: 9, added: [replacement, added], revoked: [Self.sample.exemplars[2].scanID])
        let patched = try Self.sample.applying(delta)
        #expect(patched.version == 9)
        #expect(patched.calibrationPrint == Self.calibration)
        #expect(patched.exemplars.map(\.scanID) == [Self.sample.exemplars[0].scanID, replacement.scanID, added.scanID])
        #expect(patched.exemplars[1].featurePrint == FeaturePrint(elements: [0, 1, 0]), "an added exemplar replaces the one of the same scan")

        #expect(throws: ExemplarIndexError.deltaBaseMismatch(expected: 7, found: 6)) {
            try Self.sample.applying(ExemplarDelta(baseVersion: 6, version: 8, added: [], revoked: []))
        }
        let restated = try Self.sample.applying(ExemplarDelta(baseVersion: nil, version: 8, calibrationPrint: FeaturePrint(elements: [0, 0, 1]), added: [], revoked: []))
        #expect(restated.calibrationPrint == FeaturePrint(elements: [0, 0, 1]) && restated.exemplars == Self.sample.exemplars)

        let deltaJSON = try JSONEncoder().encode(delta)
        #expect(try JSONDecoder().decode(ExemplarDelta.self, from: deltaJSON) == delta)
    }

    @Test func binaryStoreRoundTripsBitForBit() throws {
        let data = try BinaryExemplarStore.encode(Self.sample)
        #expect(data.prefix(4) == Data("RBEX".utf8))
        #expect(data.count == 4 + 4 + 4 + 8 + 4 + 4 + 1 + 3 * 4 + 3 * 3 * 4 + 3 * (2 + 7 + 16 + 16 + 8), "header, prints, id table")
        let decoded = try BinaryExemplarStore.decode(data)
        #expect(decoded == Self.sample, "the binary form keeps the exact floats and sub-second dates")

        #expect(try BinaryExemplarStore.decode(try BinaryExemplarStore.encode(.empty)) == .empty)
        let uncalibrated = ExemplarIndex(version: 3, calibrationPrint: nil, exemplars: Self.sample.exemplars)
        #expect(try BinaryExemplarStore.decode(try BinaryExemplarStore.encode(uncalibrated)) == uncalibrated)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("riftbound-overlay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("overlay.bin")
        try BinaryExemplarStore.write(Self.sample, to: file)
        #expect(try BinaryExemplarStore.read(from: file) == Self.sample)
    }

    @Test func binaryStoreRejectsDamage() throws {
        let data = try BinaryExemplarStore.encode(Self.sample)
        #expect(throws: BinaryExemplarStoreError.truncated) { try BinaryExemplarStore.decode(data.prefix(data.count - 5)) }
        #expect(throws: BinaryExemplarStoreError.corrupt("trailing bytes")) { try BinaryExemplarStore.decode(data + Data([0])) }
        #expect(throws: BinaryExemplarStoreError.corrupt("not an exemplar store")) { try BinaryExemplarStore.decode(Data("JSON{}".utf8) + data.dropFirst(6)) }
        let mixed = ExemplarIndex(version: 1, calibrationPrint: Self.calibration, exemplars: [Self.exemplar("x", print: [1, 0, 0, 0], scan: 9)])
        #expect(throws: BinaryExemplarStoreError.inconsistentDimension(expected: 4, found: 3)) { try BinaryExemplarStore.encode(mixed) }
    }

    @Test func binaryStorePatchesAFileInPlace() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("riftbound-overlay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("overlay.bin")

        // No file yet: a delta from version 0 seeds it.
        let seed = ExemplarDelta(baseVersion: 0, version: 1, calibrationPrint: Self.calibration, added: Array(Self.sample.exemplars.prefix(2)), revoked: [])
        let seeded = try BinaryExemplarStore.patch(fileAt: file, with: seed)
        #expect(seeded.version == 1 && seeded.exemplars.count == 2 && seeded.calibrationPrint == Self.calibration)
        #expect(try BinaryExemplarStore.read(from: file) == seeded)

        let next = ExemplarDelta(baseVersion: 1, version: 2, added: [Self.sample.exemplars[2]], revoked: [Self.sample.exemplars[0].scanID])
        let patched = try BinaryExemplarStore.patch(fileAt: file, with: next)
        #expect(patched.version == 2)
        #expect(patched.exemplars.map(\.scanID) == [Self.sample.exemplars[1].scanID, Self.sample.exemplars[2].scanID])
        #expect(try BinaryExemplarStore.read(from: file) == patched)

        #expect(throws: ExemplarIndexError.deltaBaseMismatch(expected: 2, found: 1)) {
            try BinaryExemplarStore.patch(fileAt: file, with: next)
        }
        #expect(try BinaryExemplarStore.read(from: file) == patched, "a refused delta leaves the file alone")
    }
}

@Suite("Learning policy")
struct LearningPolicyTests {
    /// The file documented in docs/learning-policy.md.
    static let documented = """
    {
      "version": 3,
      "calibrationMinimum": 0.97,
      "scoring": {
        "featurePrintWeight": 0.5,
        "wholeDifferenceHashWeight": 0.2,
        "wholePerceptualHashWeight": 0.15,
        "artDifferenceHashWeight": 0.15,
        "codeExactBonus": 0.5,
        "codeVariantMismatchBonus": 0.2,
        "codeSetMismatchPenalty": 0.15,
        "codeMismatchPenalty": 0.4,
        "rerankedCandidateCount": 12,
        "codeInjectionMinimumConfidence": 0.3,
        "maximumLocationHypotheses": 6,
        "ocrHypothesisCount": 2,
        "wholeImageMinimumScore": 0.8,
        "exemplarScale": 0.95
      },
      "confidence": {
        "minimumFusedScore": 1.0,
        "requireLiteralCode": true,
        "exemplarDisagreementThreshold": 0.88,
        "exemplarDisagreementMargin": 0.10,
        "auditRate": 0.3,
        "auditRateAfter": 0.1,
        "auditRateSwitchCount": 300
      },
      "admission": {
        "referenceSimilarityFloor": 0.62,
        "alternativeMargin": 0.05,
        "witnessMutualSimilarity": 0.85,
        "witnessReferenceFloor": 0.60,
        "impostorSimilarity": 0.90,
        "duplicateSimilarity": 0.985,
        "maximumPerGroup": 6
      }
    }
    """

    @Test func decodesTheDocumentedPolicy() throws {
        let policy = try JSONDecoder().decode(LearningPolicy.self, from: Data(Self.documented.utf8))
        #expect(policy.version == 3)
        #expect(policy.calibrationMinimum == 0.97)
        #expect(policy.scoring == .default, "the documented scoring values are today's defaults")
        #expect(policy.confidence.minimumFusedScore == 1.0)
        #expect(policy.confidence.requireLiteralCode)
        #expect(policy.confidence.exemplarDisagreementThreshold == 0.88)
        #expect(policy.confidence.exemplarDisagreementMargin == 0.10)
        #expect(policy.confidence.auditRate == 0.3 && policy.confidence.auditRateAfter == 0.1 && policy.confidence.auditRateSwitchCount == 300)
        #expect(policy.confidence.auditRate(afterRandomAudits: 299) == 0.3)
        #expect(policy.confidence.auditRate(afterRandomAudits: 300) == 0.1)
        #expect(policy.admission.referenceSimilarityFloor == 0.62)
        #expect(policy.admission.alternativeMargin == 0.05)
        #expect(policy.admission.witnessMutualSimilarity == 0.85)
        #expect(policy.admission.witnessReferenceFloor == 0.60)
        #expect(policy.admission.impostorSimilarity == 0.90)
        #expect(policy.admission.duplicateSimilarity == 0.985)
        #expect(policy.admission.maximumPerGroup == 6)

        var expected = LearningPolicy.default
        expected.version = 3
        expected.calibrationMinimum = 0.97
        #expect(policy == expected, "apart from version and calibration minimum the documented file states the defaults")
    }

    @Test func fillsMissingKeysWithDefaultsAtEveryLevel() throws {
        #expect(try JSONDecoder().decode(LearningPolicy.self, from: Data("{}".utf8)) == .default)
        let partial = try JSONDecoder().decode(LearningPolicy.self, from: Data(#"{"version": 5, "confidence": {"auditRate": 0.5}, "admission": {"maximumPerGroup": 4}, "scoring": {"exemplarScale": 0.9}}"#.utf8))
        var expected = LearningPolicy.default
        expected.version = 5
        expected.confidence.auditRate = 0.5
        expected.admission.maximumPerGroup = 4
        expected.scoring.exemplarScale = 0.9
        #expect(partial == expected)
        #expect(partial.confidence.auditRateAfter == 0.1 && partial.admission.duplicateSimilarity == 0.985)
    }

    @Test func roundTripsAndWritesEveryKey() throws {
        var policy = LearningPolicy.default
        policy.version = 2
        policy.confidence.requireLiteralCode = false
        policy.admission.impostorSimilarity = 0.92
        let encoded = try JSONEncoder().encode(policy)
        #expect(try JSONDecoder().decode(LearningPolicy.self, from: encoded) == policy)
        let json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(json.keys) == ["version", "scoring", "confidence", "admission", "calibrationMinimum"])
        #expect((json["confidence"] as? [String: Any])?.count == 7)
        #expect((json["admission"] as? [String: Any])?.count == 7)
        #expect((json["scoring"] as? [String: Any])?.count == 14)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("riftbound-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("policy.json")
        try policy.write(to: file)
        #expect(try LearningPolicy.read(from: file) == policy)
    }
}
