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

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("riftbound-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("index.json")
        try index.write(to: file)
        let reloaded = try CardIndex.read(from: file)
        #expect(reloaded.entries == index.entries)
        #expect(reloaded.canvas == index.canvas)
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
