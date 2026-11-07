import CoreGraphics
import Foundation
import Synchronization
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
        #expect(result.descriptor.orientation == .upright, "the winner matched upright, so the upright query is reported")
        #expect(result.descriptor.descriptor == (try await rig.extractor.descriptor(for: result.rectifiedCard)))
        #expect(result.engine == rig.fingerprint)
        #expect(result.quad == nil, "the whole image was assumed; there is no detected quad")
    }

    @Test func recognisesAnUpsideDownCard() async throws {
        let deck = rig.standardDeck()
        let index = await rig.buildIndex(deck)
        let recognizer = rig.recognizer(index: index)
        let flipped = try rig.renderer.rotated(deck[4].image, quarterTurnsCounterclockwise: 2)
        let result = try await recognizer.identify(flipped)
        #expect(result.best?.id == deck[4].card.id)
        #expect(result.best?.orientation == .upsideDown)

        // The reported descriptor is the upside-down query: the one computed from
        // the canvas turned through 180°, which is what lines up with the reference.
        #expect(result.descriptor.orientation == .upsideDown)
        let turned = try rig.renderer.rotated(result.rectifiedCard, quarterTurnsCounterclockwise: 2)
        #expect(result.descriptor.descriptor == (try await rig.extractor.descriptor(for: turned)))
        let reference = try #require(index.entries.first { $0.id == deck[4].card.id }).descriptor
        let chosen = result.descriptor.descriptor.featurePrint.similarity(to: reference.featurePrint)
        let upright = try await rig.extractor.descriptor(for: result.rectifiedCard).featurePrint.similarity(to: reference.featurePrint)
        #expect(chosen > 0.99)
        #expect(upright < chosen, "the upright query of a flipped card is the wrong one to keep")
    }

    @Test func identifyingARectifiedCardReportsItsDescriptorAndEngine() async throws {
        let deck = rig.standardDeck()
        let index = await rig.buildIndex(deck)
        let recognizer = rig.recognizer(index: index)
        let result = try await recognizer.identify(rectifiedCard: deck[1].image)
        #expect(result.best?.id == deck[1].card.id)
        #expect(result.descriptor.orientation == .upright)
        #expect(result.descriptor.descriptor == (try await rig.extractor.descriptor(for: deck[1].image)))
        #expect(result.engine == rig.fingerprint)
        #expect(result.location == .assumedWholeImage && result.quad == nil)

        let flipped = try await recognizer.identify(rectifiedCard: try rig.renderer.rotated(deck[1].image, quarterTurnsCounterclockwise: 2))
        #expect(flipped.best?.orientation == .upsideDown)
        #expect(flipped.descriptor.orientation == .upsideDown)
        #expect(flipped.descriptor.descriptor == (try await rig.extractor.descriptor(for: deck[1].image)), "turning the flipped canvas back gives the original")
    }

    @Test func rectifiesALocatedCard() async throws {
        let deck = rig.standardDeck()
        let index = await rig.buildIndex(deck)
        let (photo, quad) = TestImages.photo(of: deck[1].image, at: CGRect(x: 420, y: 160, width: 500, height: 700), canvas: PixelSize(width: 1400, height: 1200))
        let recognizer = rig.recognizer(index: index, locator: FakeCardLocator(quad: quad, confidence: 0.9))
        let result = try await recognizer.identify(photo)
        #expect(result.best?.id == deck[1].card.id)
        #expect(result.location == .detected(quad, confidence: 0.9), "the exact detection beats its frame-expanded variant")
        #expect(result.quad == quad, "a detected placement exposes its corners")
        #expect(result.rectifiedCard.width == 756 && result.rectifiedCard.height == 1056)
        #expect(result.descriptor.descriptor == (try await rig.extractor.descriptor(for: result.rectifiedCard)), "the descriptor belongs to the winning hypothesis")
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
            codeReader: PrintedCodeReader(textRecognizer: fakeOCR, renderer: rig.renderer, canvas: rig.canvas, parser: PrintedCodeParser(vocabulary: index.vocabulary)),
            fingerprint: rig.fingerprint
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
            fingerprint: rig.fingerprint,
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
            codeReader: PrintedCodeReader(textRecognizer: ocr, renderer: rig.renderer, canvas: rig.canvas, parser: PrintedCodeParser(vocabulary: index.vocabulary)),
            fingerprint: rig.fingerprint
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
        #expect(result.codeReading?.source == .edgeBand, "the crop's own bottom band carried the code")
    }

    @Test func aCodeReadOffTheWholePhotoIsMarkedAsSuch() async throws {
        let deck = rig.standardDeck()
        let index = await rig.buildIndex(deck)
        // The same tight crop with a background rectangle, but OCR that finds the
        // code only in a photo-shaped image: every edge band is far too elongated,
        // so the whole-image hypothesis falls back to reading the photo itself.
        let (photo, _) = TestImages.photo(of: deck[3].image, at: CGRect(x: 150, y: 200, width: 756, height: 1056), canvas: PixelSize(width: 1100, height: 1500))
        let wrong = CardQuad(
            topLeft: CGPoint(x: 10, y: 10), topRight: CGPoint(x: 140, y: 10),
            bottomRight: CGPoint(x: 140, y: 190), bottomLeft: CGPoint(x: 10, y: 190)
        )
        let recognizer = CardRecognizer(
            index: index,
            locator: FakeCardLocator(quad: wrong, confidence: 0.7),
            rectifier: rig.rectifier,
            descriptorExtractor: rig.extractor,
            codeReader: PrintedCodeReader(textRecognizer: PhotoShapedTextRecognizer(code: "OGN • 004/298"), renderer: rig.renderer, canvas: rig.canvas, parser: PrintedCodeParser(vocabulary: index.vocabulary)),
            fingerprint: rig.fingerprint
        )
        let result = try await recognizer.identify(photo)
        #expect(result.best?.id == deck[3].card.id)
        #expect(result.best?.codeAgreement == .exact)
        #expect(result.location == .assumedWholeImage)
        let reading = try #require(result.codeReading)
        #expect(reading.source == .fullImage)
        #expect(reading.orientation == .upright)
    }

    @Test func theReaderLabelsWhereACodeCameFrom() async throws {
        let deck = rig.standardDeck()
        let index = await rig.buildIndex(deck)
        let reader = PrintedCodeReader(textRecognizer: StubTextRecognizer(["OGN • 003/298"]), renderer: rig.renderer, canvas: rig.canvas, parser: PrintedCodeParser(vocabulary: index.vocabulary))
        let fromBands = try await reader.readCode(from: deck[2].image)
        #expect(!fromBands.isEmpty && fromBands.allSatisfy { $0.source == .edgeBand })
        let (photo, _) = TestImages.photo(of: deck[2].image, at: CGRect(x: 100, y: 100, width: 378, height: 528), canvas: PixelSize(width: 600, height: 800))
        let fromPhoto = try await reader.readCode(fromFullImage: photo)
        #expect(fromPhoto.first?.source == .fullImage)
        #expect(fromPhoto.first?.code.canonical == "OGN-003/298")
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

@Suite("Card recogniser with learned exemplars (fakes)")
struct CardRecognizerExemplarTests {
    let rig = TestRig()

    @Test func theEmptyOverlayLeavesEveryResultAsItWas() async throws {
        let deck = rig.standardDeck()
        let index = await rig.buildIndex(deck)
        let plain = try await rig.recognizer(index: index, ocr: ["OGN • 003/298"]).identify(deck[2].image)
        let empty = try await rig.recognizer(index: index, ocr: ["OGN • 003/298"], overlay: .empty).identify(deck[2].image)
        #expect(plain.matches == empty.matches)
        #expect(plain.hypotheses == empty.hypotheses)
        #expect(plain.location == empty.location && plain.descriptor == empty.descriptor)
        #expect(plain.matches.allSatisfy { $0.descriptorScore == $0.referenceScore && $0.exemplarSimilarity == nil })
        #expect(plain.hypotheses.allSatisfy { $0.referenceScore == $0.descriptorScore })
    }

    @Test func anExemplarEqualToTheQueryLiftsItsWholeArtGroupWithoutMovingTheReferenceScores() async throws {
        var deck = rig.standardDeck()
        let signature = (
            card: TestRig.card("ogn-003*-298", code: "OGN-299*/298", printing: [.signature, .overnumbered]),
            image: TestImages.card(seed: 3, code: "OGN • 299*/298", size: rig.canvas.size)
        )
        deck.append(signature)
        let index = await rig.buildIndex(deck)
        let baseline = try await rig.recognizer(index: index).identify(deck[0].image)

        // The photo of card 1 is learned (wrongly, for the test's sake) as an exemplar of the ogn-003 pair.
        let query = try await rig.extractor.descriptor(for: deck[0].image).featurePrint
        let overlay = try await rig.overlay(group: ArtGroup(rawValue: "ogn-003"), prints: [query])
        let learned = try await rig.recognizer(index: index, overlay: overlay).identify(deck[0].image)

        #expect(learned.best?.id == deck[0].card.id, "a perfect reference match still beats exemplarScale × 1")
        for id in ["ogn-003-298", "ogn-003*-298"] {
            let before = try #require(baseline.matches.first { $0.id.rawValue == id })
            let after = try #require(learned.matches.first { $0.id.rawValue == id })
            #expect(after.referenceScore == before.referenceScore)
            #expect(before.referenceScore < 0.95)
            #expect(abs((after.exemplarSimilarity ?? 0) - 1) < 1e-6, "\(id): both members of the group see the same exemplar")
            #expect(abs(after.descriptorScore - 0.95) < 1e-6, "\(id): fused = exemplarScale × 1")
            #expect(after.score == after.descriptorScore, "no code was read")
        }
        let unrelated = try #require(learned.matches.first { $0.id == deck[4].card.id })
        #expect(unrelated.exemplarSimilarity == nil && unrelated.descriptorScore == unrelated.referenceScore)
        #expect(Array(learned.matches.dropFirst().prefix(2)).map(\.card.artGroup) == [ArtGroup(rawValue: "ogn-003"), ArtGroup(rawValue: "ogn-003")], "the lifted pair ranks right behind the true card")
    }

    @Test func exemplarsNeverChangeTheWinningHypothesisOrWholeImageEligibility() async throws {
        let deck = rig.standardDeck()
        let index = await rig.buildIndex(deck)
        let (photo, quad) = TestImages.photo(of: deck[1].image, at: CGRect(x: 420, y: 160, width: 500, height: 700), canvas: PixelSize(width: 1400, height: 1200))
        // A second, wrong detection on the background, reported more confidently than the card.
        let wrong = CardQuad(
            topLeft: CGPoint(x: 20, y: 20), topRight: CGPoint(x: 320, y: 20),
            bottomRight: CGPoint(x: 320, y: 440), bottomLeft: CGPoint(x: 20, y: 440)
        )
        let locator = FakeCardLocator([CardCandidate(quad: quad, confidence: 0.9), CardCandidate(quad: wrong, confidence: 0.95)])
        let baseline = try await rig.recognizer(index: index, locator: locator).identify(photo)
        #expect(baseline.best?.id == deck[1].card.id)
        #expect(baseline.location == .detected(quad, confidence: 0.9))
        let wholeBefore = try #require(baseline.hypotheses.first { $0.location == .assumedWholeImage })
        #expect(wholeBefore.referenceScore < ScoringPolicy.default.wholeImageMinimumScore, "the whole photo does not look like a card")

        // Learn the queries of every hypothesis as exemplars of card 6, with an
        // absurd scale, so that card 6's fused score dwarfs every reference score
        // in every hypothesis. Which hypothesis wins, and whether the whole image
        // may compete, must not move.
        var prints: [FeaturePrint] = []
        for candidateQuad in [quad, wrong, CardQuad(fullImageOfSize: PixelSize(width: photo.width, height: photo.height))] {
            let canvas = try rig.rectifier.rectify(photo, quad: candidateQuad)
            prints.append(try await rig.extractor.descriptor(for: canvas).featurePrint)
        }
        let overlay = try await rig.overlay(group: deck[5].card.artGroup, prints: prints)
        var policy = ScoringPolicy.default
        policy.exemplarScale = 3
        let learned = try await rig.recognizer(index: index, locator: locator, policy: policy, overlay: overlay).identify(photo)

        #expect(learned.location == baseline.location)
        #expect(learned.hypotheses.map(\.location) == baseline.hypotheses.map(\.location))
        #expect(learned.hypotheses.map(\.referenceScore) == baseline.hypotheses.map(\.referenceScore))
        #expect(learned.descriptor == baseline.descriptor, "the winning hypothesis's query is unchanged")
        let wholeAfter = try #require(learned.hypotheses.first { $0.location == .assumedWholeImage })
        #expect(wholeAfter.bestCard == deck[5].card.id && wholeAfter.descriptorScore > 2.5, "the whole image now 'matches' card 6 overwhelmingly...")
        #expect(wholeAfter.referenceScore == wholeBefore.referenceScore && learned.location != .assumedWholeImage, "...and is still not eligible")
        // Within the winning hypothesis the exemplar does change the ranking: that is its job.
        let best = try #require(learned.best)
        #expect(best.id == deck[5].card.id && abs((best.exemplarSimilarity ?? 0) - 1) < 1e-6 && best.descriptorScore > 2.5)
        #expect(best.referenceScore == baseline.matches.first { $0.id == deck[5].card.id }?.referenceScore)
    }

    @Test func excludedBatchesAreIgnoredEndToEnd() async throws {
        let deck = rig.standardDeck()
        let index = await rig.buildIndex(deck)
        let query = try await rig.extractor.descriptor(for: deck[0].image).featurePrint
        let batch = UUID()
        let overlay = try await rig.overlay(group: deck[5].card.artGroup, prints: [query], batch: batch)
        let withExemplar = try await rig.recognizer(index: index, overlay: overlay).identify(deck[0].image)
        #expect(abs((withExemplar.matches.first { $0.id == deck[5].card.id }?.exemplarSimilarity ?? 0) - 1) < 1e-6)

        let excluded = try await rig.recognizer(index: index, overlay: overlay, excludedBatches: [batch]).identify(deck[0].image)
        let plain = try await rig.recognizer(index: index).identify(deck[0].image)
        #expect(excluded.matches == plain.matches, "with its only batch excluded the overlay is inert")
        #expect(excluded.matches.allSatisfy { $0.exemplarSimilarity == nil })
    }

    @Test func replacingKeepsTheCollaboratorsAndSwapsTheData() async throws {
        let deck = rig.standardDeck()
        let index = await rig.buildIndex(deck)
        let ocr = CountingTextRecognizer(["OGN • 003/298"])
        let original = CardRecognizer(
            index: index,
            locator: FakeCardLocator(),
            rectifier: rig.rectifier,
            descriptorExtractor: rig.extractor,
            codeReader: PrintedCodeReader(textRecognizer: ocr, renderer: rig.renderer, canvas: rig.canvas, parser: PrintedCodeParser(vocabulary: index.vocabulary)),
            fingerprint: rig.fingerprint
        )
        let first = try await original.identify(rectifiedCard: deck[2].image)
        #expect(first.best?.id == deck[2].card.id)
        #expect(ocr.calls == 4, "one OCR pass per edge band")

        let query = try await rig.extractor.descriptor(for: deck[2].image).featurePrint
        let overlay = try await rig.overlay(group: deck[5].card.artGroup, prints: [query], version: 4)
        var policy = ScoringPolicy.default
        policy.exemplarScale = 0.9
        let replaced = original.replacing(overlay: overlay, policy: policy)
        let second = try await replaced.identify(rectifiedCard: deck[2].image)
        #expect(ocr.calls == 8, "the very same text recogniser instance served the replacement")
        #expect(replaced.fingerprint == original.fingerprint && replaced.fingerprint == rig.fingerprint)
        #expect(replaced.overlay == overlay && replaced.policy == policy)
        #expect(replaced.index.entries == index.entries && replaced.excludedBatches.isEmpty)
        #expect(second.best?.id == deck[2].card.id)
        #expect(abs((second.matches.first { $0.id == deck[5].card.id }?.descriptorScore ?? 0) - 0.9) < 1e-6, "the new overlay and policy are in force")
        #expect(second.engine == rig.fingerprint)

        // Leaving every argument out changes nothing; naming the index swaps the reference data.
        let same = original.replacing()
        #expect(same.overlay == original.overlay && same.policy == original.policy && same.index.entries == original.index.entries)
        let other = (card: TestRig.card("ogn-007-298", code: "OGN-007/298"), image: TestImages.card(seed: 7, code: "OGN • 007/298", size: rig.canvas.size))
        let otherIndex = await rig.buildIndex([other])
        let reindexed = original.replacing(index: otherIndex)
        let third = try await reindexed.identify(rectifiedCard: other.image)
        #expect(third.best?.id == other.card.id && third.matches.count == 1)
        #expect(ocr.calls == 12)
        let excluded = replaced.replacing(excludedBatches: Set(overlay.exemplars.map(\.batchID)))
        #expect(excluded.overlay == overlay && excluded.excludedBatches.count == 1)
        #expect(try await excluded.identify(rectifiedCard: deck[2].image).matches.allSatisfy { $0.exemplarSimilarity == nil })
    }
}

/// A text recogniser with identity: counts the calls it receives so a test can
/// tell whether two recognisers share it.
final class CountingTextRecognizer: TextRecognizing, Sendable {
    private let lines: [TextLine]
    private let count = Mutex(0)

    init(_ strings: [String]) {
        lines = strings.map { TextLine(string: $0, confidence: 1) }
    }

    var calls: Int { count.withLock { $0 } }

    func recognizeText(in image: CGImage) async throws -> [TextLine] {
        count.withLock { $0 += 1 }
        return lines
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

/// Returns the code only for an image shaped like a photo (aspect between 1:2
/// and 2:1): the canvas's edge bands are far more elongated than that, so only
/// the full-image pass of the reader ever sees text.
struct PhotoShapedTextRecognizer: TextRecognizing {
    let code: String

    func recognizeText(in image: CGImage) async throws -> [TextLine] {
        let aspect = Double(image.width) / Double(image.height)
        return (0.5...2).contains(aspect) ? [TextLine(string: code, confidence: 1)] : []
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
