import Foundation
import Testing
import RiftboundRecognizer

@Suite("Scan import")
struct ScanImportTests {
    static let v1Root = Fixtures.url("scans-v1")
    static let v2Root = Fixtures.url("scans-v2")
    static let manifestFolder = Fixtures.url("evaluation")
    static let standardSize = PixelSize(width: 1454, height: 2030)
    static let legacySize = PixelSize(width: 1536, height: 2048)

    /// The v1 fixture's photos are not in the repository: the sizes the
    /// Testing batch's capture table records stand in for them.
    static func v1Size(_ url: URL) -> PixelSize? {
        switch url.lastPathComponent {
        case "0EDBA322-499D-4B42-8CDC-BE2D263D3ECE.jpg", "A137F90D-2ED4-4585-B768-562E2DED1634.jpg", "5D4F851E-81DB-4236-983B-F97CDB689CBB.jpg": standardSize
        case "AD08D71D-D130-426A-A195-272F5D2468C4.jpg": nil
        default: legacySize
        }
    }

    @Test func readsAV1BatchAsLegacyCalibrationData() throws {
        let batch = try ScanImport.readBatch(at: Self.v1Root.appendingPathComponent("1CAED0F4-69FA-4D3D-AC6F-3D45ED54BF93"))
        #expect(batch.label == "Testing" && batch.displayName == "Testing")
        #expect(batch.purpose == "calibration" && batch.trainingQuality == .legacy)
        #expect(batch.scans.count == 5 && batch.judgedScans.count == 4)
        #expect(batch.scans.map(\.capturedAt) == batch.scans.map(\.capturedAt).sorted(), "scans come back in capture order")
        let corrected = try #require(batch.scans.first { $0.id.uuidString == "62F63796-C35E-44AA-ABF3-6B65277BB7A8" })
        #expect(corrected.decision?.source == .legacy && corrected.decision?.kind == .corrected && corrected.decision?.seq == 1)
        #expect(corrected.confirmedCardID?.rawValue == "sfd-121-221", "a corrected v1 verdict names the card")
        #expect(corrected.hasCrop == false && corrected.recordedCaptureQuality == nil && corrected.analysis == nil && corrected.calibrationHash == nil)
        let correct = try #require(batch.scans.first { $0.id.uuidString == "0EDBA322-499D-4B42-8CDC-BE2D263D3ECE" })
        #expect(correct.confirmedCardID?.rawValue == "ven-031-166", "a correct v1 verdict snapshots the top candidate")
        #expect(correct.codeRead?.canonical == "VEN-031/166" && correct.hasCrop)
        let pending = try #require(batch.scans.first { $0.id.uuidString == "5D4F851E-81DB-4236-983B-F97CDB689CBB" })
        #expect(pending.decision == nil)
        let wholeImage = try #require(batch.scans.first { $0.id.uuidString == "A137F90D-2ED4-4585-B768-562E2DED1634" })
        #expect(wholeImage.placement == .wholeImage)
    }

    @Test func anUnstatedCaptureQualityIsLegacyAsTheAppDecodesIt() throws {
        // The app's `ScanRecord` decode, `Scripts/summarize-scans.py` and this
        // importer must agree on one `scans/` folder: a record that states no
        // `captureQuality` is `legacy`, whatever its crop and photo size say.
        let batch = try ScanImport.readBatch(at: Self.v1Root.appendingPathComponent("1CAED0F4-69FA-4D3D-AC6F-3D45ED54BF93"))
        #expect(batch.scans.allSatisfy { $0.recordedCaptureQuality == nil && $0.captureQuality == .legacy })
        let appSample = try Data(contentsOf: Fixtures.folder.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App/Tests/Fixtures/scans-v1.json"))
        let packageSample = try Data(contentsOf: Self.v1Root.appendingPathComponent("1CAED0F4-69FA-4D3D-AC6F-3D45ED54BF93/scans.json"))
        #expect(try JSONSerialization.jsonObject(with: appSample) as? NSArray == JSONSerialization.jsonObject(with: packageSample) as? NSArray, "the package reads the same frozen v1 sample the app's tests decode")
    }

    @Test func derivesCaptureQualityFromCropAndPhotoSizeOnlyOnRequest() throws {
        let batch = try ScanImport.readBatch(at: Self.v1Root.appendingPathComponent("1CAED0F4-69FA-4D3D-AC6F-3D45ED54BF93"))
        let cropped = try #require(batch.scans.first { $0.hasCrop })
        let uncropped = try #require(batch.scans.first { !$0.hasCrop })
        #expect(cropped.captureQuality == .legacy, "what the app decodes")
        #expect(cropped.derivedCaptureQuality(photoSize: Self.standardSize) == .standard, "what the crop and size would derive")
        #expect(cropped.derivedCaptureQuality(photoSize: Self.legacySize) == .legacy, "a full-frame photo is not a guide crop")
        #expect(cropped.derivedCaptureQuality(photoSize: nil) == .legacy, "nothing to verify against")
        #expect(uncropped.derivedCaptureQuality(photoSize: Self.standardSize) == .legacy)
        #expect(ImportedScan.isStandardSize(PixelSize(width: 1454, height: 2030)))
        #expect(ImportedScan.isStandardSize(PixelSize(width: 2030, height: 1454)) == false, "portrait only")
        #expect(ImportedScan.isStandardSize(PixelSize(width: 1536, height: 2048)) == false, "wrong aspect")
        #expect(ImportedScan.isStandardSize(PixelSize(width: 727, height: 1015)) == false, "too small")
    }

    @Test func importsV1CasesWithLegacyLabelsGroupsAndUnitWeights() throws {
        let result = try ScanImport.importCases(under: Self.v1Root, manifestFolder: Self.manifestFolder, auditRate: 0.3, now: Date(timeIntervalSince1970: 0), imageSize: Self.v1Size)
        #expect(result.cases.count == 4)
        #expect(result.skipped == [.pending: 1])
        #expect(result.unreadablePhotos == ["photos/AD08D71D-D130-426A-A195-272F5D2468C4.jpg"])
        #expect(result.cases.allSatisfy { $0.group == "Testing" && $0.decisionSource == .legacy && $0.samplingWeight == 1 })
        #expect(result.cases.allSatisfy { $0.batchID?.uuidString == "1CAED0F4-69FA-4D3D-AC6F-3D45ED54BF93" })
        #expect(Set(result.cases.map(\.expected.rawValue)) == ["ven-031-166", "sfd-121-221", "unl-097-219", "ven-072-166"])
        let byScan = Dictionary(uniqueKeysWithValues: result.cases.map { ($0.scanID!.uuidString, $0) })
        #expect(result.cases.allSatisfy { $0.captureQuality == .legacy }, "v1 records state no quality, so every case is legacy as the app sees it")
        #expect(byScan["0EDBA322-499D-4B42-8CDC-BE2D263D3ECE"]?.derivedCaptureQuality == .standard, "a guide crop at 1454x2030 is derivable as standard")
        #expect(byScan["0EDBA322-499D-4B42-8CDC-BE2D263D3ECE"]?.imageSize == Self.standardSize)
        #expect(byScan["62F63796-C35E-44AA-ABF3-6B65277BB7A8"]?.derivedCaptureQuality == .legacy, "no crop")
        #expect(byScan["AD08D71D-D130-426A-A195-272F5D2468C4"]?.derivedCaptureQuality == .legacy && byScan["AD08D71D-D130-426A-A195-272F5D2468C4"]?.imageSize == nil, "unreadable photo")
        #expect(byScan["0EDBA322-499D-4B42-8CDC-BE2D263D3ECE"]?.file == "../scans-v1/1CAED0F4-69FA-4D3D-AC6F-3D45ED54BF93/photos/0EDBA322-499D-4B42-8CDC-BE2D263D3ECE.jpg")
        #expect(result.manifest.platform == RecognizerInfo.platform && result.manifest.auditRate == 0.3 && result.manifest.seed == nil)
        #expect(result.manifest.batchIDs.map(\.uuidString) == ["1CAED0F4-69FA-4D3D-AC6F-3D45ED54BF93"])
    }

    @Test func importsV2CasesWithSourcesStatedQualitiesAndAuditWeights() throws {
        let result = try ScanImport.importCases(under: Self.v2Root, manifestFolder: Self.manifestFolder, auditRate: 0.3, now: Date(timeIntervalSince1970: 0), imageSize: { _ in Self.standardSize })
        // Six records: autoAccepted (machine), human corrected, human then voided, pending, audit correct, autoAccepted then spot-check corrected.
        #expect(result.cases.count == 3)
        #expect(result.skipped == [.pending: 1, .noCard: 1, .machineDecided: 1])
        let byScan = Dictionary(uniqueKeysWithValues: result.cases.map { ($0.scanID!.uuidString, $0) })
        let human = try #require(byScan["A0000002-0000-4000-8000-000000000002"])
        #expect(human.decisionSource == .human && human.expected.rawValue == "ogn-002-298" && human.samplingWeight == 1)
        #expect(human.captureQuality == .standard && human.derivedCaptureQuality == .standard, "the stated quality wins on both readings")
        let audit = try #require(byScan["A0000005-0000-4000-8000-000000000005"])
        #expect(audit.decisionSource == .audit && audit.expected.rawValue == "ogn-001-298")
        #expect(abs(audit.samplingWeight - 1 / 0.3) < 1e-9, "an audit case stands for the confident scans it was sampled from")
        let spotCheck = try #require(byScan["A0000006-0000-4000-8000-000000000006"])
        #expect(spotCheck.decisionSource == .spotCheck && spotCheck.expected.rawValue == "ogn-002-298" && spotCheck.samplingWeight == 1, "the latest decision labels the scan")
        #expect(result.cases.allSatisfy { $0.group == "Box 1, v2 fixture" })
        let batch = try #require(result.batches.first)
        #expect(batch.purpose == "collection" && batch.trainingQuality == .standard)
        let analysed = try #require(batch.scans.first { $0.id.uuidString == "A0000001-0000-4000-8000-000000000001" })
        #expect(analysed.analysis?.codeSource == .edgeBand && analysed.analysis?.orientation == .upright)
        #expect(analysed.analysis?.codeAlternatives.map(\.code.canonical) == ["OGN-001/298"])
        #expect(analysed.calibrationHash == "c9008e0eafa62e6827a43aea9bd2f524" && analysed.recordedCaptureQuality == .standard)
    }

    @Test func manifestRoundTripsTheImportedFields() throws {
        let result = try ScanImport.importCases(under: Self.v2Root, manifestFolder: Self.manifestFolder, auditRate: 0.1, now: Date(timeIntervalSince1970: 1_700_000_000), imageSize: { _ in Self.standardSize })
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("scan-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try result.manifest.write(to: folder)
        let reloaded = try EvaluationManifest.read(from: folder)
        #expect(reloaded.cases == result.cases)
        #expect(reloaded.auditRate == 0.1 && reloaded.platform == RecognizerInfo.platform && reloaded.seed == nil)
        let audit = try #require(reloaded.cases.first { $0.decisionSource == .audit })
        #expect(audit.samplingWeight == 10)
        // A synthetic manifest without the new keys still reads, with unit weights.
        let legacy = Data(#"{"generatedAt":"2026-11-03T00:00:00Z","seed":42,"cases":[{"file":"mild/000.jpg","expected":"ogn-001-298","group":"mild"}]}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let synthetic = try decoder.decode(EvaluationManifest.self, from: legacy)
        #expect(synthetic.seed == 42 && synthetic.cases[0].samplingWeight == 1 && synthetic.cases[0].scanID == nil && synthetic.platform == nil)
    }

    @Test func refusesAScanIDThatAppearsInTwoBatchFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scan-import-dupes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = Self.v1Root.appendingPathComponent("1CAED0F4-69FA-4D3D-AC6F-3D45ED54BF93")
        for name in ["A-first", "B-second"] {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source.appendingPathComponent("scans.json"), to: folder.appendingPathComponent("scans.json"))
            try FileManager.default.copyItem(at: source.appendingPathComponent("batch.json"), to: folder.appendingPathComponent("batch.json"))
        }
        let error = #expect(throws: ScanImport.ImportError.self) {
            try ScanImport.importCases(under: root, manifestFolder: root, auditRate: 0.3, imageSize: { _ in nil })
        }
        guard case .duplicateScan(let scanID, let batches) = try #require(error) else {
            Issue.record("expected duplicateScan")
            return
        }
        #expect(scanID.uuidString == "0EDBA322-499D-4B42-8CDC-BE2D263D3ECE" || batches == ["A-first", "B-second"])
        #expect(batches == ["A-first", "B-second"], "names both folders")
        #expect("\(ScanImport.ImportError.duplicateScan(scanID: scanID, batches: batches))".contains(scanID.uuidString))
    }

    @Test func relativePathsClimbToTheSharedRoot() {
        #expect(ScanImport.relativePath(to: URL(fileURLWithPath: "/repo/scans/B/photos/x.jpg"), from: URL(fileURLWithPath: "/repo/evaluation")) == "../scans/B/photos/x.jpg")
        #expect(ScanImport.relativePath(to: URL(fileURLWithPath: "/repo/scans/B/photos/x.jpg"), from: URL(fileURLWithPath: "/repo/scans")) == "B/photos/x.jpg")
        #expect(ScanImport.relativePath(to: URL(fileURLWithPath: "/private/tmp/out/../scans/x.jpg"), from: URL(fileURLWithPath: "/private/tmp/out")) == "../scans/x.jpg", "dot segments fold, /private is not stripped")
    }
}
