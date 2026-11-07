import CoreGraphics
import Foundation
import Testing
import RiftboundRecognizer

@Suite("Card index")
struct CardIndexTests {
    let rig = TestRig()

    @Test func buildsSavesAndReloads() async throws {
        let deck = rig.standardDeck()
        let index = await rig.buildIndex(deck)
        #expect(index.entries.map(\.id.rawValue) == deck.map(\.card.id.rawValue))
        #expect(index.builtAt == rig.fixedDate)
        #expect(index.vocabulary.sets.map(\.rawValue) == ["OGN"])
        let calibration = try await ThumbnailFeaturePrintGenerator().calibrationPrint()
        #expect(index.calibrationPrint == calibration, "the index records the print of the generator that built it")
        #expect(index.calibrationHash == calibration.digest)
        #expect(index.formatVersion == 1, "the calibration print is an optional addition, not a new format")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("riftbound-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("index.json")
        try index.write(to: file)
        let reloaded = try CardIndex.read(from: file)
        #expect(reloaded.entries == index.entries)
        #expect(reloaded.canvas == index.canvas)
        #expect(reloaded.calibrationPrint == index.calibrationPrint)
        #expect(reloaded.calibrationHash == index.calibrationHash)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(json["formatVersion"] as? Int == 1)
        #expect(json["calibrationPrint"] is String, "stored like every other feature print: base64 Float32 bytes")
    }

    @Test func decodesAnIndexWrittenBeforeCalibrationPrintsExisted() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("riftbound-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("index.json")
        try Data(#"{"formatVersion":1,"canvas":{"size":{"width":756,"height":1056},"artRegion":{"x":0.07,"y":0.06,"width":0.86,"height":0.44},"codeBandFraction":0.09},"builtAt":"2026-01-01T00:00:00Z","entries":[]}"#.utf8).write(to: file)
        let index = try CardIndex.read(from: file)
        #expect(index.calibrationPrint == nil)
        #expect(index.calibrationHash == nil)
        #expect(index.canvas == .standard)
        #expect(index.entries.isEmpty)
    }

    @Test func reportsWhenTheCalibrationPrintCannotBeComputed() async {
        let deck = rig.standardDeck()
        let images = Dictionary(uniqueKeysWithValues: deck.map { ($0.card.id, $0.image) })
        let builder = CardIndexBuilder(
            rectifier: rig.rectifier,
            extractor: CardDescriptorExtractor(featurePrinter: FailingOnCalibrationFeaturePrintGenerator(), canvas: rig.canvas),
            maxConcurrency: 2
        )
        let outcome = await builder.build(cards: deck.map(\.card), image: { images[$0.id] })
        #expect(outcome.index.entries.count == deck.count, "the cards themselves still index")
        #expect(outcome.index.calibrationPrint == nil)
        #expect(outcome.calibrationFailure?.contains("calibration") == true)
    }

    @Test func reportsMissingImages() async {
        let deck = rig.standardDeck()
        let images = Dictionary(uniqueKeysWithValues: deck.dropFirst().map { ($0.card.id, $0.image) })
        let builder = CardIndexBuilder(
            rectifier: rig.rectifier,
            extractor: CardDescriptorExtractor(featurePrinter: ThumbnailFeaturePrintGenerator(), canvas: rig.canvas),
            maxConcurrency: 3
        )
        let outcome = await builder.build(cards: deck.map(\.card), image: { images[$0.id] })
        #expect(outcome.missingImages == [deck[0].card.id])
        #expect(outcome.index.entries.count == deck.count - 1)
        #expect(outcome.failures.isEmpty)
    }

    @Test func rejectsOtherFormatVersions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("riftbound-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("index.json")
        try Data(#"{"formatVersion":99,"canvas":{"size":{"width":1,"height":1},"artRegion":{"x":0,"y":0,"width":1,"height":1},"codeBandFraction":0.1},"builtAt":"2026-01-01T00:00:00Z","entries":[]}"#.utf8).write(to: file)
        #expect(throws: CardIndexError.self) { try CardIndex.read(from: file) }
    }
}

/// Prints cards but refuses the calibration canvas, to exercise the builder's reporting.
struct FailingOnCalibrationFeaturePrintGenerator: FeaturePrintGenerating {
    struct CalibrationRefused: Error, CustomStringConvertible {
        var description: String { "calibration refused" }
    }

    func featurePrint(for image: CGImage) async throws -> FeaturePrint {
        let canvasSize = CanvasSpecification.standard.size
        if image.width == canvasSize.width, image.height == canvasSize.height, try isCalibrationCanvas(image) {
            throw CalibrationRefused()
        }
        return try await ThumbnailFeaturePrintGenerator().featurePrint(for: image)
    }

    private func isCalibrationCanvas(_ image: CGImage) throws -> Bool {
        let bytes = try #require(image.dataProvider?.data) as Data
        let reference = try #require(try CalibrationCanvas.render().dataProvider?.data) as Data
        return bytes == reference
    }
}
