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

@Suite("Card recogniser: OCR hygiene (fakes)")
struct CardRecognizerCodeHygieneTests {
    let rig = TestRig()

    /// Spiritforged 014 and 024 (distinct art), the two Vendetta/Unleashed 040s
    /// (same art, different sets) and a few more printings to fill the shortlist.
    func deck() -> [(card: Card, image: CGImage)] {
        var deck = rig.standardDeck()
        deck.append((TestRig.card("sfd-014-221", code: "SFD-014/221"), TestImages.card(seed: 14, code: "SFD • 014/221", size: rig.canvas.size)))
        deck.append((TestRig.card("sfd-024-221", code: "SFD-024/221"), TestImages.card(seed: 24, code: "SFD • 024/221", size: rig.canvas.size)))
        deck.append((TestRig.card("ven-040-166", code: "VEN-040/166"), TestImages.card(seed: 40, code: "VEN • 040/166", size: rig.canvas.size)))
        deck.append((TestRig.card("unl-040-219", code: "UNL-040/219"), TestImages.card(seed: 40, code: "UNL • 040/219", size: rig.canvas.size)))
        return deck
    }

    func card(_ id: String, in deck: [(card: Card, image: CGImage)]) throws -> (card: Card, image: CGImage) {
        try #require(deck.first { $0.card.id.rawValue == id })
    }

    @Test func aDigitAlternativeLetsTheDescriptorsOverruleAMisreadCode() async throws {
        let deck = deck()
        let index = await rig.buildIndex(deck)
        let sfd014 = try card("sfd-014-221", in: deck)
        // The photo is of 014; the OCR read 024, the misread measured on real scans.
        let recognizer = rig.recognizer(index: index, ocr: ["SFD - 024/221"])
        let result = try await recognizer.identify(sfd014.image)

        let reading = try #require(result.codeReading)
        #expect(reading.code.canonical == "SFD-024/221")
        #expect(reading.origin == .literal, "024 is in the index, so the literal reading stands")
        #expect(reading.alternatives.map(\.canonical) == ["SFD-024/221", "SFD-014/221"])

        let best = try #require(result.best)
        #expect(best.id == sfd014.card.id)
        #expect(best.codeAgreement == .exact)
        #expect(best.codeOrigin == .alternative, "exact, but via the alternative")
        #expect(best.codeEvidence == CodeEvidence(agreement: .exact, origin: .alternative))
        let policy = ScoringPolicy.default
        #expect(abs(best.score - (best.descriptorScore + policy.codeAlternativeBonus * reading.confidence)) < 1e-9)
        let literalWouldGive = best.descriptorScore + policy.codeExactBonus * reading.confidence
        #expect(abs(literalWouldGive - best.score - 0.2) < 1e-9, "0.5 for a literal exact, 0.3 via an alternative")

        let literal = try #require(result.matches.first { $0.id.rawValue == "sfd-024-221" })
        #expect(literal.codeAgreement == .exact && literal.codeOrigin == .literal)
        #expect(abs(literal.score - (literal.descriptorScore + policy.codeExactBonus * reading.confidence)) < 1e-9)
        #expect(literal.score < best.score, "its own art beats the misread code's smaller margin")
        #expect(result.matches.filter { $0.codeAgreement == .exact }.count == 2)
        #expect(result.matches.first { $0.id.rawValue == "ogn-001-298" }?.codeEvidence == CodeEvidence(agreement: .unrelated, origin: .literal))
    }

    @Test func aLiteralExactStillOutranksAnAlternativeOnEqualArt() async throws {
        let deck = deck()
        let index = await rig.buildIndex(deck)
        let sfd024 = try card("sfd-024-221", in: deck)
        // The photo is of 024 and the OCR read 024: the literal match wins by the full margin.
        let result = try await rig.recognizer(index: index, ocr: ["SFD - 024/221"]).identify(sfd024.image)
        let best = try #require(result.best)
        #expect(best.id == sfd024.card.id)
        #expect(best.codeOrigin == .literal)
        let alternative = try #require(result.matches.first { $0.id.rawValue == "sfd-014-221" })
        #expect(alternative.codeAgreement == .exact && alternative.codeOrigin == .alternative)
        #expect(best.score - alternative.score > 0.2)
    }

    @Test func anAlternativePullsItsCardIntoTheCandidates() async throws {
        let deck = deck()
        let index = await rig.buildIndex(deck)
        var policy = ScoringPolicy.default
        policy.rerankedCandidateCount = 2
        let recognizer = CardRecognizer(
            index: index,
            locator: FakeCardLocator(),
            rectifier: rig.rectifier,
            descriptorExtractor: rig.extractor,
            codeReader: PrintedCodeReader(textRecognizer: StubTextRecognizer(["SFD - 024/221"]), renderer: rig.renderer, canvas: rig.canvas, parser: PrintedCodeParser(vocabulary: index.vocabulary)),
            fingerprint: rig.fingerprint,
            policy: policy
        )
        // A photo of an unrelated card: neither Spiritforged printing makes the two-card shortlist.
        let result = try await recognizer.identify(deck[0].image)
        #expect(result.matches.count == 4, "two descriptor candidates plus the literal card and its alternative")
        #expect(result.matches.first { $0.id.rawValue == "sfd-024-221" }?.codeOrigin == .literal)
        #expect(result.matches.first { $0.id.rawValue == "sfd-014-221" }?.codeOrigin == .alternative)
    }

    @Test func aReadingWhoseLiteralIsUnknownIsReportedAsAnAlternative() async throws {
        let deck = deck()
        let index = await rig.buildIndex(deck)
        let sfd014 = try card("sfd-014-221", in: deck)
        // 074 is no printing; 7->1 gives 014. The reading itself is a guess and says so.
        let result = try await rig.recognizer(index: index, ocr: ["SFD - 074/221"]).identify(sfd014.image)
        let reading = try #require(result.codeReading)
        #expect(reading.code.canonical == "SFD-014/221")
        #expect(reading.origin == .alternative)
        #expect(reading.alternatives.map(\.canonical) == ["SFD-014/221"])
        let best = try #require(result.best)
        #expect(best.id == sfd014.card.id)
        #expect(best.codeOrigin == .alternative, "matching the guessed code is never a literal match")
        #expect(abs(best.score - (best.descriptorScore + ScoringPolicy.default.codeAlternativeBonus)) < 1e-9)
        // A guess is positive evidence only: no other candidate is penalised for disagreeing with it.
        #expect(result.matches.dropFirst().allSatisfy { $0.codeEvidence == nil && $0.score == $0.descriptorScore })
    }

    @Test func anUnindexedCodeReadsAsNoCode() async throws {
        let deck = deck()
        let index = await rig.buildIndex(deck)
        // VEN-R040 is shape-valid but no printing; the vocabulary now knows that.
        let result = try await rig.recognizer(index: index, ocr: ["VEN • R04D •"]).identify(deck[1].image)
        #expect(result.codeReading == nil)
        #expect(result.best?.id == deck[1].card.id)
        #expect(result.best?.codeAgreement == nil && result.best?.codeOrigin == nil)
        // So does a denominator that belongs to another set.
        let wrongTotal = try await rig.recognizer(index: index, ocr: ["VEN • 040/221"]).identify(deck[1].image)
        #expect(wrongTotal.codeReading == nil)
    }

    @Test func anExpectedSetSuppressesARepairIntoAnotherSet() async throws {
        let deck = deck()
        let index = await rig.buildIndex(deck)
        let ven040 = try card("ven-040-166", in: deck)
        let unl = RecognitionHints(expectedSet: SetCode(rawValue: "UNL"))
        // "O4O" needs a shape repair: without a hint it yields VEN-040; expecting UNL, the repair is refused.
        let unhinted = try await rig.recognizer(index: index, ocr: ["VEN • O4O/166"]).identify(ven040.image)
        #expect(unhinted.codeReading?.code.canonical == "VEN-040/166")
        #expect(unhinted.best?.id == ven040.card.id && unhinted.best?.codeAgreement == .exact)

        let hinted = try await rig.recognizer(index: index, ocr: ["VEN • O4O/166"]).identify(ven040.image, hints: unl)
        #expect(hinted.codeReading == nil, "the VEN repair is suppressed")
        #expect(hinted.best?.codeAgreement == nil)

        // A clean VEN reading is evidence and survives the hint.
        let clean = try await rig.recognizer(index: index, ocr: ["VEN • 040/166"]).identify(ven040.image, hints: unl)
        #expect(clean.codeReading?.code.canonical == "VEN-040/166")
        #expect(clean.best?.id == ven040.card.id)
    }

    @Test func anExpectedSetBreaksATieBetweenSameArtPrintings() async throws {
        let deck = deck()
        let index = await rig.buildIndex(deck)
        let ven040 = try card("ven-040-166", in: deck)
        let unl040 = try card("unl-040-219", in: deck)
        // Same illustration in two sets and no code read: the descriptors can barely tell them apart.
        let unhinted = try await rig.recognizer(index: index).identify(ven040.image)
        #expect(unhinted.best?.id == ven040.card.id)
        let ven = try #require(unhinted.matches.first { $0.id == ven040.card.id })
        let unl = try #require(unhinted.matches.first { $0.id == unl040.card.id })
        #expect(ven.score - unl.score < 0.05 && ven.score == ven.descriptorScore)

        let hinted = try await rig.recognizer(index: index).identify(ven040.image, hints: RecognitionHints(expectedSet: SetCode(rawValue: "UNL")))
        #expect(hinted.best?.id == unl040.card.id, "the hint's prior decides the tie")
        let hintedUNL = try #require(hinted.matches.first { $0.id == unl040.card.id })
        let hintedVEN = try #require(hinted.matches.first { $0.id == ven040.card.id })
        #expect(abs(hintedUNL.score - (hintedUNL.descriptorScore + ScoringPolicy.default.expectedSetBonus)) < 1e-9)
        #expect(hintedVEN.score == hintedVEN.descriptorScore, "only the expected set is credited")
        #expect(hintedUNL.codeAgreement == nil, "a hint is not a code reading")

        // A read code outweighs the hint: the VEN code names VEN even when UNL is expected.
        let read = try await rig.recognizer(index: index, ocr: ["VEN • 040/166"]).identify(ven040.image, hints: RecognitionHints(expectedSet: SetCode(rawValue: "UNL")))
        #expect(read.best?.id == ven040.card.id)
    }

    @Test func hintsReachTheRectifiedCardEntryPoint() async throws {
        let deck = deck()
        let index = await rig.buildIndex(deck)
        let ven040 = try card("ven-040-166", in: deck)
        let unl040 = try card("unl-040-219", in: deck)
        let result = try await rig.recognizer(index: index).identify(rectifiedCard: ven040.image, hints: RecognitionHints(expectedSet: SetCode(rawValue: "UNL")))
        #expect(result.best?.id == unl040.card.id)
        let suppressed = try await rig.recognizer(index: index, ocr: ["VEN • O4O/166"]).identify(rectifiedCard: ven040.image, hints: RecognitionHints(expectedSet: SetCode(rawValue: "UNL")))
        #expect(suppressed.codeReading == nil)
    }

    @Test func codeReadingPlacesItsCodeFirstAmongTheAlternatives() throws {
        let code = TestRig.code("SFD-024/221")
        let other = TestRig.code("SFD-014/221")
        let plain = CodeReading(code: code, confidence: 1, orientation: .upright, layout: .portrait, text: "SFD - 024/221", source: .edgeBand)
        #expect(plain.origin == .literal && plain.alternatives == [code])
        let listed = CodeReading(code: code, confidence: 1, orientation: .upright, layout: .portrait, text: "SFD - 024/221", source: .edgeBand, alternatives: [other, code])
        #expect(listed.alternatives == [code, other])
        #expect(listed.evidence(for: code) == CodeEvidence(agreement: .exact, origin: .literal))
        #expect(listed.evidence(for: other) == CodeEvidence(agreement: .exact, origin: .alternative))
        #expect(listed.evidence(for: TestRig.code("SFD-014a/221")) == CodeEvidence(agreement: .numberDiffers, origin: .literal), "alternatives never supply variant-only matches; the literal reading decides")
        #expect(listed.evidence(for: TestRig.code("OGN-014/298")) == CodeEvidence(agreement: .unrelated, origin: .literal), "nor penalties")
        let guessed = CodeReading(code: other, confidence: 1, orientation: .upright, layout: .portrait, text: "SFD - 074/221", source: .edgeBand, origin: .alternative)
        #expect(guessed.evidence(for: other) == CodeEvidence(agreement: .exact, origin: .alternative))
        #expect(guessed.evidence(for: code) == nil, "a guessed reading never penalises")
        #expect(guessed.evidence(for: TestRig.code("SFD-014a/221")) == nil)
        let match = Match(card: TestRig.card("x", code: "SFD-014/221"), score: 1, descriptorScore: 1, components: ScoreComponents(featurePrint: 1, wholeDifferenceHash: 1, wholePerceptualHash: 1, artDifferenceHash: 1), orientation: .upright, codeAgreement: nil, codeOrigin: .alternative)
        #expect(match.codeEvidence == nil && match.codeOrigin == nil, "no reading, no origin")
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
