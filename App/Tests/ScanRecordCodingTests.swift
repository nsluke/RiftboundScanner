import Foundation
import RiftboundRecognizer
import Testing
@testable import RiftboundScannerApp

@Suite("Scan record coding")
struct ScanRecordCodingTests {
    private static func storeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func storeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    @Test("verdicts round-trip", arguments: [Verdict.pending, .correct, .corrected(Fixtures.jinx.id), .rejected(.notACard), .voided])
    func verdictRoundTrips(verdict: Verdict) throws {
        let data = try JSONEncoder().encode(verdict)
        #expect(try JSONDecoder().decode(Verdict.self, from: data) == verdict)
    }

    @Test func verdictJSONUsesAKindDiscriminator() throws {
        let data = try JSONEncoder().encode(Verdict.corrected(Fixtures.jinx.id))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: String]
        #expect(object?["kind"] == "corrected")
        #expect(object?["cardID"] == "ogn-002-298")
        let voided = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(Verdict.voided)) as? [String: String]
        #expect(voided == ["kind": "voided"])
    }

    @Test func recordRoundTripsThroughTheStoreEncoding() throws {
        let result = Fixtures.result(cards: [Fixtures.vi, Fixtures.jinx], codeReading: Fixtures.viCodeReading)
        let record = Fixtures.record(
            batch: ScanBatch.ID(rawValue: UUID()),
            decisions: [
                Fixtures.decision(.correct, cardID: Fixtures.vi.id, source: .autoAccepted),
                Fixtures.decision(.corrected(Fixtures.jinx.id), cardID: Fixtures.jinx.id, source: .spotCheck, seq: 2, at: Fixtures.epoch.addingTimeInterval(60), finish: .set(.foil), ledgerPrintingCode: .set(PrintingKey(rawValue: "OGN-002-P"))),
            ],
            analysis: Fixtures.analysis(for: result),
            engine: Fixtures.engineStamp,
            captureQuality: .standard
        )
        let decoded = try Self.storeDecoder().decode(ScanRecord.self, from: try Self.storeEncoder().encode(record))
        #expect(decoded == record)
        #expect(decoded.candidates.first?.card.code.canonical == "OGN-001/298")
        #expect(decoded.verdict == .corrected(Fixtures.jinx.id))
        #expect(decoded.verdictAt == Fixtures.epoch.addingTimeInterval(60))
        #expect(decoded.analysis?.codeSource == .edgeBand)
        #expect(decoded.analysis?.codeAlternatives == [CodeAlternative(code: Fixtures.viCodeReading.code, origin: .literal)])
    }

    @Test func identifiersEncodeAsPlainStrings() throws {
        let batch = Fixtures.batch()
        let object = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(batch)) as? [String: Any]
        #expect(object?["id"] as? String == batch.id.rawValue.uuidString)
        let record = Fixtures.record(batch: batch.id, verdict: .correct)
        let recordObject = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(record)) as? [String: Any]
        #expect(recordObject?["batchID"] as? String == batch.id.rawValue.uuidString)
        let decision = (recordObject?["decisions"] as? [[String: Any]])?.first
        #expect(decision?["id"] as? String == record.decisions.first?.id.rawValue.uuidString)
        #expect(decision?["cardID"] as? String == "ogn-001-298")
        #expect(decision?["source"] as? String == "human")
        #expect(decision?["finish"] as? [String: Bool] == ["inherit": true])
    }

    @Test func overridesEncodeAsInheritOrValue() throws {
        let inherit = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(Override<Finish>.inherit)) as? [String: Bool]
        #expect(inherit == ["inherit": true])
        let set = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(Override<Finish>.set(.foil))) as? [String: String]
        #expect(set == ["value": "foil"])
        for override in [Override<Finish>.inherit, .set(.normal), .set(.foil)] {
            #expect(try JSONDecoder().decode(Override<Finish>.self, from: try JSONEncoder().encode(override)) == override)
        }
        let key = try JSONDecoder().decode(Override<PrintingKey>.self, from: Data(#"{"value":"OGN-066-P"}"#.utf8))
        #expect(key == .set(PrintingKey(rawValue: "OGN-066-P")))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Override<Finish>.self, from: Data("{}".utf8))
        }
    }

    @Test func confirmedCardFollowsTheVerdict() {
        let batch = ScanBatch.ID(rawValue: UUID())
        #expect(Fixtures.record(batch: batch, verdict: .correct).confirmedCardID == Fixtures.vi.id)
        #expect(Fixtures.record(batch: batch, verdict: .corrected(Fixtures.jinx.id)).confirmedCardID == Fixtures.jinx.id)
        #expect(Fixtures.record(batch: batch, verdict: .rejected(.notACard)).confirmedCardID == nil)
        #expect(Fixtures.record(batch: batch, verdict: .voided).confirmedCardID == nil)
        #expect(Fixtures.record(batch: batch).confirmedCardID == nil)
    }

    @Test func confirmedCardIsASnapshotThatSurvivesReorderedCandidates() {
        let batch = ScanBatch.ID(rawValue: UUID())
        let decisions = [Fixtures.decision(.correct, cardID: Fixtures.vi.id)]
        let original = Fixtures.record(batch: batch, decisions: decisions, candidates: [Fixtures.vi, Fixtures.jinx])
        let reranked = Fixtures.record(id: original.id.rawValue, batch: batch, decisions: decisions, candidates: [Fixtures.jinx, Fixtures.vi])
        #expect(original.confirmedCardID == Fixtures.vi.id)
        #expect(reranked.topCandidate?.card.id == Fixtures.jinx.id)
        #expect(reranked.confirmedCardID == Fixtures.vi.id, "the label is what was confirmed, not whoever ranks first now")
    }

    @Test func verdictIsDerivedFromTheLastDecision() {
        let batch = ScanBatch.ID(rawValue: UUID())
        let later = Fixtures.epoch.addingTimeInterval(90)
        let record = Fixtures.record(batch: batch, decisions: [
            Fixtures.decision(.correct, cardID: Fixtures.vi.id, source: .autoAccepted),
            Fixtures.decision(.voided, cardID: nil, source: .human, seq: 2, at: later),
        ])
        #expect(record.verdict == .voided)
        #expect(record.verdictAt == later)
        #expect(record.lastDecision?.seq == 2)
        #expect(record.confirmedCardID == nil)
        #expect(Fixtures.record(batch: batch).verdict == .pending)
        #expect(Fixtures.record(batch: batch).verdictAt == nil)
    }

    @Test func overridesFoldAcrossTheDecisionLog() {
        let batch = ScanBatch.ID(rawValue: UUID())
        let promo = PrintingKey(rawValue: "OGN-001-P")
        let record = Fixtures.record(batch: batch, decisions: [
            Fixtures.decision(.correct, cardID: Fixtures.vi.id, finish: .set(.foil), ledgerPrintingCode: .set(promo)),
            Fixtures.decision(.correct, cardID: Fixtures.vi.id, source: .audit, seq: 2, at: Fixtures.epoch.addingTimeInterval(1)),
            Fixtures.decision(.correct, cardID: Fixtures.vi.id, source: .spotCheck, seq: 3, at: Fixtures.epoch.addingTimeInterval(2), finish: .set(.normal)),
        ])
        #expect(record.effectiveFinish == .normal, "the last set wins; inherit leaves the earlier value")
        #expect(record.effectivePrintingCode == promo, "an audit that inherits keeps the promo choice")
        #expect(Fixtures.record(batch: batch, verdict: .correct).effectiveFinish == nil)
        #expect(Fixtures.record(batch: batch, verdict: .correct).effectivePrintingCode == nil)
    }

    @Test func decidingNumbersAndSnapshotsTheDecision() {
        let batch = ScanBatch.ID(rawValue: UUID())
        let pending = Fixtures.record(batch: batch)
        let id = Decision.ID(rawValue: UUID())
        let first = pending.deciding(DecisionInput(.correct, source: .autoAccepted), id: id, at: Fixtures.epoch)
        #expect(first.decisions == [Decision(id: id, seq: 1, verdict: .correct, cardID: Fixtures.vi.id, source: .autoAccepted, decidedAt: Fixtures.epoch)])
        #expect(first.verdict == .correct)
        let second = first.deciding(DecisionInput(.corrected(Fixtures.jinx.id), source: .human, finish: .set(.foil)), id: Decision.ID(rawValue: UUID()), at: Fixtures.epoch.addingTimeInterval(5))
        #expect(second.decisions.map(\.seq) == [1, 2])
        #expect(second.confirmedCardID == Fixtures.jinx.id)
        #expect(second.effectiveFinish == .foil)
        #expect(pending.isExtended(by: first))
        #expect(first.isExtended(by: second))
        #expect(first.isExtended(by: first))
        #expect(!first.isExtended(by: pending), "dropping a decision is not an extension")
        let rival = pending.deciding(DecisionInput(.rejected(.notACard), source: .human), id: Decision.ID(rawValue: UUID()), at: Fixtures.epoch)
        #expect(!first.isExtended(by: rival), "a different seq-1 decision is not an extension")
    }

    @Test func summaryCountsVerdictsAndAccuracy() {
        let batch = ScanBatch.ID(rawValue: UUID())
        let records = [
            Fixtures.record(batch: batch, verdict: .correct),
            Fixtures.record(batch: batch, verdict: .correct),
            Fixtures.record(batch: batch, verdict: .corrected(Fixtures.jinx.id)),
            Fixtures.record(batch: batch, verdict: .corrected(Card.ID(rawValue: "ogn-099-298"))),
            Fixtures.record(batch: batch, verdict: .rejected(.notACard)),
            Fixtures.record(batch: batch, verdict: .voided),
            Fixtures.record(batch: batch),
        ]
        let summary = BatchSummary(records: records)
        #expect(summary.total == 7)
        #expect(summary.correct == 2)
        #expect(summary.corrected == 2)
        #expect(summary.rejected == 1)
        #expect(summary.voided == 1)
        #expect(summary.pending == 1)
        #expect(summary.judged == 4)
        #expect(summary.topOneAccuracy == 0.5)
        #expect(summary.topThreeAccuracy == 0.75)
    }

    // MARK: - Analysis, engine and capture quality

    @Test func theEncodedShortlistCarriesNoImagesOrURLs() throws {
        let result = Fixtures.result(cards: [Fixtures.vi, Fixtures.jinx], codeReading: Fixtures.viCodeReading)
        let analysis = ScanAnalysis(result, at: Fixtures.epoch)
        let json = String(decoding: try Self.storeEncoder().encode(analysis), as: UTF8.self)
        #expect(!json.contains("imageURL"))
        #expect(!json.contains("http"))
        #expect(json.contains("\"cardID\" : \"ogn-001-298\""))
        #expect(analysis.shortlist.map(\.cardID) == [Fixtures.vi.id, Fixtures.jinx.id])
        #expect(analysis.shortlist.first?.referenceScore == 0.9)
        #expect(analysis.shortlist.first?.fusedScore == 0.9)
        #expect(analysis.shortlist.first?.exemplarSimilarity == nil)
        #expect(analysis.descriptor.orientation == .upright)
        #expect(analysis.quad == result.quad)
    }

    @Test func theShortlistIsCappedAtTwelve() {
        let cards = (0..<20).map { Fixtures.card(id: "ogn-\($0 + 100)-298", code: "OGN-\($0 + 100)/298", name: "Card \($0)") }
        let analysis = ScanAnalysis(Fixtures.result(cards: cards), at: Fixtures.epoch)
        #expect(analysis.shortlist.count == ScanAnalysis.shortlistLimit)
        #expect(analysis.shortlist.first?.cardID == cards[0].id)
    }

    @Test func engineStampCopiesTheFingerprint() throws {
        let stamp = EngineStamp(Fixtures.engine, overlayVersion: 3)
        #expect(stamp.packageVersion == "test")
        #expect(stamp.calibrationHash == Fixtures.engine.calibrationHash.hex)
        #expect(stamp.calibrationHash.count == 32)
        #expect(stamp.platform == "iOS")
        #expect(stamp.overlayVersion == 3)
        #expect(stamp.policyVersion == nil)
        let object = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(stamp)) as? [String: Any]
        #expect(object?["policyVersion"] == nil, "absent, not null")
        #expect(try JSONDecoder().decode(EngineStamp.self, from: try JSONEncoder().encode(stamp)) == stamp)
    }

    @Test func captureQualityIsStandardOnlyForGuideCropsAtFullResolution() {
        let crop = CropDebug(crop: GuideCrop(guideFrame: .init(x: 0, y: 0, width: 63, height: 88), previewFrame: .init(x: 0, y: 0, width: 100, height: 200)), photoWidth: 3024, photoHeight: 4032, pixelRect: .init(x: 0, y: 0, width: 1454, height: 2030))
        #expect(CaptureQuality(crop: crop, photoSize: PixelSize(width: 1454, height: 2030)) == .standard)
        #expect(CaptureQuality(crop: crop, photoSize: PixelSize(width: 1460, height: 2040)) == .standard)
        #expect(CaptureQuality(crop: nil, photoSize: PixelSize(width: 1454, height: 2030)) == .legacy, "no crop record means the guide was not used")
        #expect(CaptureQuality(crop: crop, photoSize: PixelSize(width: 1536, height: 2048)) == .legacy, "a whole frame is not card-shaped")
        #expect(CaptureQuality(crop: crop, photoSize: PixelSize(width: 2892, height: 2030)) == .legacy, "a landscape crop came from a wrong-shaped guide")
        #expect(CaptureQuality(crop: crop, photoSize: PixelSize(width: 727, height: 1015)) == .legacy, "card-shaped but half the resolution")
    }

    @Test func captureQualityTableForTheTestingBatch() throws {
        struct Table: Decodable {
            struct Row: Decodable {
                let id: String
                let hasCrop: Bool
                let photoWidth: Int
                let photoHeight: Int
            }
            let records: [Row]
        }
        let table = try JSONDecoder().decode(Table.self, from: try Fixtures.fixtureData("capture-table-1CAED0F4", extension: "json"))
        let stubCrop = CropDebug(crop: GuideCrop(guideFrame: .init(x: 0, y: 0, width: 1, height: 1), previewFrame: .init(x: 0, y: 0, width: 1, height: 1)), photoWidth: 3024, photoHeight: 4032, pixelRect: .zero)
        var standard = 0, legacy = 0
        for row in table.records {
            switch CaptureQuality(crop: row.hasCrop ? stubCrop : nil, photoSize: PixelSize(width: row.photoWidth, height: row.photoHeight)) {
            case .standard: standard += 1
            case .legacy: legacy += 1
            }
        }
        #expect(table.records.count == 86)
        #expect(standard == 15)
        #expect(legacy == 71)
    }

    // MARK: - Version 1 files

    @Test func aV1BatchIsACalibrationSittingThatNeverTrains() throws {
        let batch = try Self.storeDecoder().decode(ScanBatch.self, from: try Fixtures.fixtureData("batch-v1", extension: "json"))
        #expect(batch.purpose == .calibration)
        #expect(batch.trainingQuality == .legacy)
        #expect(batch.product == nil)
        #expect(batch.defaultFinish == nil)
        #expect(batch.label == "Testing")
        #expect(batch.index.entryCount == 1408)
        let reencoded = try JSONSerialization.jsonObject(with: try Self.storeEncoder().encode(batch)) as? [String: Any]
        #expect(reencoded?["purpose"] as? String == "calibration")
        #expect(reencoded?["trainingQuality"] as? String == "legacy")
        #expect(reencoded?["label"] as? String == "Testing")
    }

    @Test func v1RecordsDecodeWithSynthesisedLegacyDecisions() throws {
        let records = try Self.storeDecoder().decode([ScanRecord].self, from: try Fixtures.fixtureData("scans-v1", extension: "json"))
        #expect(records.count == 5)
        for record in records {
            #expect(record.analysis == nil)
            #expect(record.engine == nil)
            #expect(record.captureQuality == .legacy)
            switch record.verdict {
            case .pending:
                #expect(record.decisions.isEmpty)
                #expect(record.confirmedCardID == nil)
            case .correct:
                #expect(record.decisions.count == 1)
                #expect(record.decisions.first?.seq == 1)
                #expect(record.decisions.first?.source == .legacy)
                #expect(record.decisions.first?.cardID == record.topCandidate?.card.id)
                #expect(record.decisions.first?.decidedAt == record.verdictAt)
                #expect(record.decisions.first?.finish == .inherit)
                #expect(record.decisions.first?.id == .legacy(for: record.id))
            case .corrected(let id):
                #expect(record.decisions.map(\.source) == [.legacy])
                #expect(record.decisions.first?.cardID == id)
                #expect(record.confirmedCardID == id)
            case .rejected, .voided:
                Issue.record("the fixture has no rejected or voided records")
            }
        }
        #expect(records.map(\.verdict).filter { $0 == .pending }.count == 1)
        #expect(records.filter { if case .corrected = $0.verdict { true } else { false } }.count == 1)
        #expect(records.first { $0.id.rawValue.uuidString == "62F63796-C35E-44AA-ABF3-6B65277BB7A8" }?.confirmedCardID == Card.ID(rawValue: "sfd-121-221"))
    }

    @Test func legacyDecisionIDsAreStableAcrossDecodes() throws {
        let data = try Fixtures.fixtureData("scans-v1", extension: "json")
        let first = try Self.storeDecoder().decode([ScanRecord].self, from: data)
        let second = try Self.storeDecoder().decode([ScanRecord].self, from: data)
        #expect(first == second)
        let ids = Set(first.flatMap(\.decisions).map(\.id))
        #expect(ids.count == 4, "one distinct id per judged record")
    }

    @Test func reencodingAV1RecordKeepsEveryV1Field() throws {
        let data = try Fixtures.fixtureData("scans-v1", extension: "json")
        let originals = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        let records = try Self.storeDecoder().decode([ScanRecord].self, from: data)
        let reencoded = try Self.storeEncoder().encode(records)
        let objects = try JSONSerialization.jsonObject(with: reencoded) as? [[String: Any]]
        let decodedAgain = try Self.storeDecoder().decode([ScanRecord].self, from: reencoded)
        #expect(decodedAgain == records)
        for (original, object) in zip(try #require(originals), try #require(objects)) {
            for (key, value) in original {
                let kept = try #require(object[key], "v1 key \(key) was dropped")
                #expect(NSDictionary(dictionary: [key: value]).isEqual(to: [key: kept]), "v1 key \(key) changed")
            }
            #expect(object["decisions"] != nil)
            #expect(object["captureQuality"] as? String == "legacy")
            #expect(object["analysis"] == nil)
            #expect(object["engine"] == nil)
        }
    }

    // MARK: - Version 2 fixture, shared with the Python reader

    @Test func theV2FixtureDecodesAsWritten() throws {
        let batch = try Self.storeDecoder().decode(ScanBatch.self, from: try Fixtures.fixtureData("batch-v2", extension: "json"))
        #expect(batch.purpose == .collection)
        #expect(batch.product == .sealedBox(set: SetCode(rawValue: "OGN")!))
        #expect(batch.defaultFinish == .normal)
        #expect(batch.trainingQuality == .standard)

        let records = try Self.storeDecoder().decode([ScanRecord].self, from: try Fixtures.fixtureData("scans-v2", extension: "json"))
        #expect(records.count == 4)
        #expect(records.map(\.verdict) == [.correct, .corrected(Card.ID(rawValue: "ogn-002-298")), .voided, .pending])
        #expect(records.map { $0.decisions.map(\.source) } == [[.autoAccepted], [.human], [.human, .human], []])
        #expect(records[1].effectiveFinish == .foil)
        #expect(records[1].effectivePrintingCode == PrintingKey(rawValue: "OGN-002-P"))
        #expect(records[2].decisions.map(\.seq) == [1, 2])
        #expect(records[2].confirmedCardID == nil)
        #expect(records[0].captureQuality == .standard)
        #expect(records[0].engine?.calibrationHash == "c9008e0eafa62e6827a43aea9bd2f524")
        #expect(records[0].analysis?.shortlist.count == 2)
        #expect(records[0].analysis?.descriptor.descriptor.featurePrint.elements.count == 3)
        #expect(records[3].analysis?.codeSource == .fullImage)
        #expect(records[3].analysis?.codeAlternatives.map(\.origin) == [.literal, .alternative])
    }
}
