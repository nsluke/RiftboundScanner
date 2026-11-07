import CoreGraphics
import Foundation
import Testing
import RiftboundRecognizer

@Suite("Vision integration", .tags(.vision))
struct VisionIntegrationTests {
    let rig = TestRig()

    private var reader: PrintedCodeReader {
        PrintedCodeReader(
            textRecognizer: VisionTextRecognizer(), renderer: rig.renderer, canvas: rig.canvas,
            parser: PrintedCodeParser(vocabulary: .init(codes: ["OGN-123/298", "UNL-T01"].map(TestRig.code)))
        )
    }

    @Test func readsTheCodeAndOrientationOfAPortraitCard() async throws {
        let card = TestImages.card(seed: 21, code: "OGN • 123/298", size: rig.canvas.size)
        let upright = try await reader.readCode(from: card)
        let best = try #require(upright.first)
        #expect(best.code.canonical == "OGN-123/298")
        #expect(best.orientation == .upright && best.layout == .portrait)

        let flipped = try await reader.readCode(from: try rig.renderer.rotated(card, quarterTurnsCounterclockwise: 2))
        #expect(flipped.first?.code.canonical == "OGN-123/298")
        #expect(flipped.first?.orientation == .upsideDown)
        #expect(flipped.first?.layout == .portrait)
    }

    @Test func readsTheCodeOfALandscapeCard() async throws {
        let landscape = TestImages.card(seed: 22, code: "UNL • T01", size: PixelSize(width: 1056, height: 756))
        let canonical = try rig.rectifier.canonicalImage(fromReference: landscape, orientation: .landscape)
        let readings = try await reader.readCode(from: canonical)
        let best = try #require(readings.first)
        #expect(best.code.canonical == "UNL-T01")
        #expect(best.orientation == .upright && best.layout == .landscape)

        let other = try await reader.readCode(from: try rig.renderer.rotated(canonical, quarterTurnsCounterclockwise: 2))
        #expect(other.first?.orientation == .upsideDown && other.first?.layout == .landscape)
    }

    @Test func locatesASyntheticPhoto() async throws {
        let card = TestImages.card(seed: 23, code: "OGN • 045/298", size: rig.canvas.size)
        var generator = SeededRandomNumberGenerator(seed: 2026)
        var parameters = SyntheticPhotoParameters.random(severity: .mild, using: &generator)
        parameters.flipped = false
        parameters.sideways = false
        let photo = try SyntheticPhotoRenderer(renderer: rig.renderer).render(card: card, parameters: parameters)

        let candidates = try await VisionCardLocator().locateCards(in: photo.image)
        let first = try #require(candidates.first)
        #expect(first.confidence > 0.5)
        #expect(first.quad.cornerError(comparedTo: photo.quad) < 0.08, "the top candidate is the card or its inner frame")
    }

    @Test func locatesACardInAClutteredPhotoThroughSaliency() async throws {
        let card = TestImages.card(seed: 26, code: "OGN • 046/298", size: rig.canvas.size)
        var generator = SeededRandomNumberGenerator(seed: 99)
        var parameters = SyntheticPhotoParameters.random(severity: .mild, using: &generator)
        parameters.clutterShapeCount = 16
        parameters.sideways = false
        let photo = try SyntheticPhotoRenderer(renderer: rig.renderer).render(card: card, parameters: parameters)
        let candidates = try await VisionCardLocator().locateCards(in: photo.image)
        let salient = candidates.filter { $0.source == .salientObject }
        #expect(!salient.isEmpty)
        // Saliency boxes can be loose when clutter touches the card, so check the
        // overlap of the fitted card with the truth rather than its corners.
        let truth = photo.quad.boundingBox
        let overlaps = salient.map { candidate -> CGFloat in
            let box = candidate.quad.boundingBox
            let intersection = box.intersection(truth)
            let union = box.width * box.height + truth.width * truth.height - intersection.width * intersection.height
            return intersection.isNull ? 0 : intersection.width * intersection.height / union
        }
        #expect((overlaps.max() ?? 0) > 0.75)
        #expect(candidates.contains { $0.quad.cornerError(comparedTo: photo.quad) < 0.08 }, "some candidate is the card")
    }

    @Test func identifiesACardInASyntheticPhotoEndToEnd() async throws {
        let deck = rig.standardDeck()
        let visionRig = CardDescriptorExtractor(featurePrinter: VisionFeaturePrintGenerator(), canvas: rig.canvas)
        let images = Dictionary(uniqueKeysWithValues: deck.map { ($0.card.id, $0.image) })
        let index = await CardIndexBuilder(rectifier: rig.rectifier, extractor: visionRig).build(cards: deck.map(\.card), image: { images[$0.id] }).index
        let recognizer = try await CardRecognizer.live(index: index, renderer: rig.renderer)

        var generator = SeededRandomNumberGenerator(seed: 7)
        for (number, severity) in [Severity.mild, .moderate].enumerated() {
            let parameters = SyntheticPhotoParameters.random(severity: severity, using: &generator)
            let photo = try SyntheticPhotoRenderer(renderer: rig.renderer).render(card: deck[number].image, parameters: parameters)
            let result = try await recognizer.identify(photo.image)
            #expect(result.best?.id == deck[number].card.id, "\(severity)")
            if case .assumedWholeImage = result.location {
                Issue.record("no rectangle detected for the \(severity) photo")
            }
        }
    }

    @Test func featurePrintsAreUnitVectors() async throws {
        let print = try await VisionFeaturePrintGenerator().featurePrint(for: TestImages.card(seed: 24, code: nil))
        #expect(print.elements.count > 100)
        #expect(abs(print.similarity(to: print) - 1) < 1e-4)
        let other = try await VisionFeaturePrintGenerator().featurePrint(for: TestImages.card(seed: 25, code: nil))
        #expect(print.similarity(to: other) < 0.999)
    }
}
