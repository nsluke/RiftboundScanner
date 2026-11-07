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

    @Test func aReadCodePullsItsCardIntoTheCandidates() async throws {
        let deck = rig.standardDeck()
        let index = await rig.buildIndex(deck)
        // Only two descriptor candidates survive, and the photo is of card 1, so card 6
        // would never be ranked; OCR naming it must still make it the winner.
        var policy = ScoringPolicy.default
        policy.rerankedCandidateCount = 2
        let recognizer = CardRecognizer(
            index: index,
            locator: FakeCardLocator(),
            rectifier: rig.rectifier,
            descriptorExtractor: CardDescriptorExtractor(featurePrinter: ThumbnailFeaturePrintGenerator(), canvas: rig.canvas),
            codeReader: PrintedCodeReader(textRecognizer: StubTextRecognizer(["OGN • 006/298"]), renderer: rig.renderer, canvas: rig.canvas, parser: PrintedCodeParser(vocabulary: index.vocabulary)),
            policy: policy
        )
        let result = try await recognizer.identify(deck[0].image)
        #expect(result.matches.count == 3, "the two descriptor candidates plus the injected card")
        let best = try #require(result.best)
        #expect(best.id == deck[5].card.id)
        #expect(best.codeAgreement == .exact)
        #expect(best.descriptorScore < 1, "its descriptor score is genuine, not assumed")
        #expect(result.matches.contains { $0.id == deck[0].card.id }, "the visually matching card is still listed")
    }

    @Test func wholeImageWinsWhenItsCodeReadsAndTheDetectorMissed() async throws {
        let deck = rig.standardDeck()
        let index = await rig.buildIndex(deck)
        // A tight crop of card 4 with some background, as the feeder stand produces,
        // where the detector reports a background rectangle instead of the card.
        let (photo, _) = TestImages.photo(of: deck[3].image, at: CGRect(x: 150, y: 200, width: 756, height: 1056), canvas: PixelSize(width: 1100, height: 1500))
        let wrong = CardQuad(
            topLeft: CGPoint(x: 10, y: 10), topRight: CGPoint(x: 140, y: 10),
            bottomRight: CGPoint(x: 140, y: 190), bottomLeft: CGPoint(x: 10, y: 190)
        )
        // OCR that only finds text where there is something other than flat background.
        let ocr = BackgroundAwareTextRecognizer(code: "OGN • 004/298")
        let recognizer = CardRecognizer(
            index: index,
            locator: FakeCardLocator(quad: wrong, confidence: 0.7),
            rectifier: rig.rectifier,
            descriptorExtractor: CardDescriptorExtractor(featurePrinter: ThumbnailFeaturePrintGenerator(), canvas: rig.canvas),
            codeReader: PrintedCodeReader(textRecognizer: ocr, renderer: rig.renderer, canvas: rig.canvas, parser: PrintedCodeParser(vocabulary: index.vocabulary))
        )
        let result = try await recognizer.identify(photo)
        let best = try #require(result.best)
        #expect(best.id == deck[3].card.id)
        #expect(best.codeAgreement == .exact)
        // The whole crop is read for its code even though its descriptor score is
        // below the whole-image threshold, and it competes on that evidence.
        let whole = try #require(result.hypotheses.first { $0.location == .assumedWholeImage })
        #expect(whole.codeRead == deck[3].card.code)
        #expect(whole.bestCard == deck[3].card.id)
        #expect(whole.bestScore > 1, "descriptor score plus the exact-code bonus")
    }

    @Test func aReadCodeDoesNotDuplicateAListedCandidate() async throws {
        let deck = rig.standardDeck()
        let index = await rig.buildIndex(deck)
        let recognizer = rig.recognizer(index: index, ocr: ["OGN • 003/298"])
        let result = try await recognizer.identify(deck[2].image)
        #expect(result.matches.map(\.id).filter { $0 == deck[2].card.id }.count == 1)
        #expect(result.matches.count == min(deck.count, ScoringPolicy.default.rerankedCandidateCount))
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

/// Returns the code only for images that are not a flat colour, so a strip of
/// plain background reads as nothing while the card itself reads as its code.
struct BackgroundAwareTextRecognizer: TextRecognizing {
    let code: String

    func recognizeText(in image: CGImage) async throws -> [TextLine] {
        let reference = TestImages.rgb(of: image, x: 0, y: 0)
        let probes = stride(from: 0, to: image.width, by: max(1, image.width / 12)).flatMap { x in
            stride(from: 0, to: image.height, by: max(1, image.height / 12)).map { y in (x, y) }
        }
        let uniform = probes.allSatisfy { x, y in
            let pixel = TestImages.rgb(of: image, x: x, y: y)
            return abs(Int(pixel.red) - Int(reference.red)) < 8 && abs(Int(pixel.green) - Int(reference.green)) < 8 && abs(Int(pixel.blue) - Int(reference.blue)) < 8
        }
        return uniform ? [] : [TextLine(string: code, confidence: 1)]
    }
}
