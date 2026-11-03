import CoreGraphics
import Foundation
import Testing
import RiftboundRecognizer

@Suite("Card recogniser (fakes)")
struct CardRecognizerTests {
    let rig = TestRig()

    @Test func identifiesACardFromItsOwnImage() async throws {
        let deck = rig.standardDeck()
        let index = await rig.buildIndex(deck)
        let recognizer = rig.recognizer(index: index)
        let result = try await recognizer.identify(deck[2].image)
        let best = try #require(result.best)
        #expect(best.id == deck[2].card.id)
        #expect(best.orientation == .upright)
        #expect(best.codeAgreement == nil && result.codeReading == nil)
        #expect(abs(best.descriptorScore - 1) < 1e-6)
        #expect(result.matches.count == min(deck.count, ScoringPolicy.default.rerankedCandidateCount))
        #expect(result.matches[1].score < best.score - 0.1, "other cards are clearly worse")
    }

    @Test func recognisesAnUpsideDownCard() async throws {
        let deck = rig.standardDeck()
        let index = await rig.buildIndex(deck)
        let recognizer = rig.recognizer(index: index)
        let flipped = try rig.renderer.rotated(deck[4].image, quarterTurnsCounterclockwise: 2)
        let result = try await recognizer.identify(flipped)
        #expect(result.best?.id == deck[4].card.id)
        #expect(result.best?.orientation == .upsideDown)
    }

    @Test func rectifiesALocatedCard() async throws {
        let deck = rig.standardDeck()
        let index = await rig.buildIndex(deck)
        let (photo, quad) = TestImages.photo(of: deck[1].image, at: CGRect(x: 420, y: 160, width: 500, height: 700), canvas: PixelSize(width: 1400, height: 1200))
        let recognizer = rig.recognizer(index: index, locator: FakeCardLocator(quad: quad, confidence: 0.9))
        let result = try await recognizer.identify(photo)
        #expect(result.best?.id == deck[1].card.id)
        #expect(result.location == .detected(quad, confidence: 0.9), "the exact detection beats its frame-expanded variant")
        #expect(result.rectifiedCard.width == 756 && result.rectifiedCard.height == 1056)
    }

    @Test func prefersTheHypothesisThatRecoversTheCode() async throws {
        let deck = rig.standardDeck()
        let index = await rig.buildIndex(deck)
        let (photo, quad) = TestImages.photo(of: deck[3].image, at: CGRect(x: 300, y: 200, width: 756, height: 1056), canvas: PixelSize(width: 1400, height: 1500))
        // The detector reports the inner frame; the true card edge is one CardFrame expansion further out.
        let frame = CardFrame.riftbound
        let inner = quad.expanded(
            top: -frame.topInset / (1 + frame.topInset + frame.bottomInset),
            bottom: -frame.bottomInset / (1 + frame.topInset + frame.bottomInset),
            left: -frame.sideInset / (1 + 2 * frame.sideInset),
            right: -frame.sideInset / (1 + 2 * frame.sideInset)
        )
        let fakeOCR = FakeTextRecognizerKeyedByWidth(codeIfWide: "OGN • 004/298")
        let recognizer = CardRecognizer(
            index: index,
            locator: FakeCardLocator(quad: inner, confidence: 0.8),
            rectifier: rig.rectifier,
            descriptorExtractor: CardDescriptorExtractor(featurePrinter: ThumbnailFeaturePrintGenerator(), canvas: rig.canvas),
            codeReader: PrintedCodeReader(textRecognizer: fakeOCR, renderer: rig.renderer, canvas: rig.canvas, parser: PrintedCodeParser(vocabulary: index.vocabulary))
        )
        let result = try await recognizer.identify(photo)
        #expect(result.best?.id == deck[3].card.id)
        guard case .detected(let chosen, _) = result.location else {
            Issue.record("expected a detected location")
            return
        }
        #expect(chosen.cornerError(comparedTo: quad) < chosen.cornerError(comparedTo: inner), "the expanded hypothesis wins")
        #expect(result.best?.codeAgreement == .exact)
    }

    @Test func agreeingCodeBoostsTheMatch() async throws {
        let deck = rig.standardDeck()
        let index = await rig.buildIndex(deck)
        let recognizer = rig.recognizer(index: index, ocr: ["OGN • 003/298", "Kudos Productions"])
        let result = try await recognizer.identify(deck[2].image)
        let best = try #require(result.best)
        #expect(best.id == deck[2].card.id)
        #expect(best.codeAgreement == .exact)
        #expect(best.score > best.descriptorScore)
        #expect(result.codeReading?.code.canonical == "OGN-003/298")
        #expect(result.matches.dropFirst().allSatisfy { $0.codeAgreement == .numberDiffers && $0.score < $0.descriptorScore })
    }

    @Test func disagreeingCodeDemotesTheDescriptorMatch() async throws {
        let deck = rig.standardDeck()
        let index = await rig.buildIndex(deck)
        let recognizer = rig.recognizer(index: index, ocr: ["OGN • 005/298"])
        let result = try await recognizer.identify(deck[2].image)
        let third = try #require(result.matches.first { $0.id == deck[2].card.id })
        let fifth = try #require(result.matches.first { $0.id == deck[4].card.id })
        #expect(third.codeAgreement == .numberDiffers && third.score < third.descriptorScore)
        #expect(fifth.codeAgreement == .exact && fifth.score > fifth.descriptorScore)
        #expect(result.best?.id == fifth.id, "a confident code reading outranks an unconfirmed descriptor match")
    }

    @Test func codeSeparatesPrintingsThatShareAnIllustration() async throws {
        var deck = rig.standardDeck()
        let signature = (
            card: TestRig.card("ogn-003*-298", code: "OGN-299*/298", printing: [.signature, .overnumbered]),
            image: TestImages.card(seed: 3, code: "OGN • 299*/298", size: rig.canvas.size)
        )
        deck[2] = (TestRig.card("ogn-003-298", code: "OGN-299/298"), TestImages.card(seed: 3, code: "OGN • 299/298", size: rig.canvas.size))
        deck.append(signature)
        let index = await rig.buildIndex(deck)

        let readsStar = rig.recognizer(index: index, ocr: ["OGN • 299*/298"])
        let starResult = try await readsStar.identify(signature.image)
        #expect(starResult.best?.id == signature.card.id)
        #expect(starResult.matches.first { $0.id == deck[2].card.id }?.codeAgreement == .variantDiffers)

        let readsPlain = rig.recognizer(index: index, ocr: ["OGN • 299/298"])
        let plainResult = try await readsPlain.identify(deck[2].image)
        #expect(plainResult.best?.id == deck[2].card.id)
        #expect(plainResult.matches.first { $0.id == signature.card.id }?.codeAgreement == .variantDiffers)
    }

    @Test func landscapeCardsAreIndexedUpright() async throws {
        var deck = rig.standardDeck()
        let landscapeImage = TestImages.card(seed: 77, code: "OGN • 275/298", size: PixelSize(width: 1056, height: 756))
        let battlefield = TestRig.card("ogn-275-298", code: "OGN-275/298", orientation: .landscape)
        deck.append((battlefield, landscapeImage))
        let index = await rig.buildIndex(deck)

        // A sideways photo of the battlefield, as the feeder's camera would see it.
        let (photo, quad) = TestImages.photo(of: landscapeImage, at: CGRect(x: 100, y: 300, width: 1056, height: 756), canvas: PixelSize(width: 1300, height: 1300))
        let recognizer = rig.recognizer(index: index, locator: FakeCardLocator(quad: quad))
        let result = try await recognizer.identify(photo)
        #expect(result.best?.id == battlefield.id)
        #expect(result.rectifiedCard.width == 756 && result.rectifiedCard.height == 1056)

        // Fed the other way round, the same card matches upside down.
        let (turned, turnedQuad) = TestImages.photo(of: try rig.renderer.rotated(landscapeImage, quarterTurnsCounterclockwise: 2), at: CGRect(x: 100, y: 300, width: 1056, height: 756), canvas: PixelSize(width: 1300, height: 1300))
        let turnedResult = try await rig.recognizer(index: index, locator: FakeCardLocator(quad: turnedQuad)).identify(turned)
        #expect(turnedResult.best?.id == battlefield.id)
        #expect(turnedResult.best?.orientation == .upsideDown)
    }
}

/// Pretends the code is legible only when the strip is as wide as a full-card
/// strip would be, i.e. only for the hypothesis that includes the card border.
struct FakeTextRecognizerKeyedByWidth: TextRecognizing {
    let codeIfWide: String

    func recognizeText(in image: CGImage) async throws -> [TextLine] {
        // Strips are rendered at twice the canvas width; an inner-frame crop has the same
        // pixel width, so key on the mean brightness of the strip instead: the real card
        // border is dark, the inner-frame crop's bottom band is the pale text box.
        let bitmap = try GrayscaleBitmap(rendering: image, width: 16, height: 4)
        let mean = bitmap.pixels.reduce(0) { $0 + Int($1) } / bitmap.pixels.count
        return mean < 90 ? [TextLine(string: codeIfWide, confidence: 1)] : []
    }
}
