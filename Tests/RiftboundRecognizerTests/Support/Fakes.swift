import CoreGraphics
import Foundation
import RiftboundRecognizer

struct FakeCardLocator: CardLocating {
    let candidates: [CardCandidate]

    init(_ candidates: [CardCandidate] = []) {
        self.candidates = candidates
    }

    init(quad: CardQuad, confidence: Double = 1) {
        candidates = [CardCandidate(quad: quad, confidence: confidence)]
    }

    func locateCards(in image: CGImage) async throws -> [CardCandidate] { candidates }
}

/// A deterministic stand-in for Vision's feature print: the 32 × 32 grayscale
/// thumbnail as a vector, so similar images get similar prints. A fake rather
/// than a stub, because scoring behaviour depends on it being image-derived.
struct ThumbnailFeaturePrintGenerator: FeaturePrintGenerating {
    func featurePrint(for image: CGImage) async throws -> FeaturePrint {
        let bitmap = try GrayscaleBitmap(rendering: image, width: 32, height: 32)
        return FeaturePrint(elements: bitmap.pixels.map { Float($0) / 255 })
    }
}

struct StubTextRecognizer: TextRecognizing {
    let lines: [TextLine]

    init(_ strings: [String], confidence: Double = 1) {
        lines = strings.map { TextLine(string: $0, confidence: confidence) }
    }

    func recognizeText(in image: CGImage) async throws -> [TextLine] { lines }
}

/// Fixtures for building small indexes from procedural cards.
struct TestRig {
    let renderer = ImageRenderer()
    let canvas = CanvasSpecification.standard
    let fixedDate = Date(timeIntervalSince1970: 1_762_000_000)
    /// A fixed stamp for hand-wired recognisers; tests check it is passed through.
    let fingerprint = EngineFingerprint(
        packageVersion: "test",
        calibrationHash: FeaturePrint(elements: [1, 0, 0]).digest,
        platform: "test",
        osVersion: "0.0.0"
    )

    var rectifier: CardRectifier { CardRectifier(renderer: renderer, canvas: canvas) }

    var extractor: CardDescriptorExtractor { CardDescriptorExtractor(featurePrinter: ThumbnailFeaturePrintGenerator(), canvas: canvas) }

    static func code(_ text: String) -> PrintedCode {
        guard let code = PrintedCode(parsing: text) else { fatalError("bad fixture code \(text)") }
        return code
    }

    static func card(
        _ id: String,
        code: String,
        name: String? = nil,
        orientation: Card.Orientation = .portrait,
        printing: PrintingTraits = []
    ) -> Card {
        Card(
            id: Card.ID(rawValue: id),
            name: name ?? "Card \(id)",
            displayName: name ?? "Card \(id)",
            code: Self.code(code),
            setName: "Origins",
            rarity: .common,
            kind: orientation == .landscape ? .battlefield : .unit,
            printing: printing,
            orientation: orientation,
            imageURL: URL(fileURLWithPath: "/fixtures/\(id).png")
        )
    }

    /// Six portrait cards with distinct illustrations, numbered 001...006.
    func standardDeck() -> [(card: Card, image: CGImage)] {
        (1...6).map { number in
            let id = String(format: "ogn-%03d-298", number)
            let printed = String(format: "OGN • %03d/298", number)
            return (Self.card(id, code: String(format: "OGN-%03d/298", number)),
                    TestImages.card(seed: UInt64(number), code: printed, size: canvas.size))
        }
    }

    func buildIndex(_ deck: [(card: Card, image: CGImage)]) async -> CardIndex {
        let images = Dictionary(uniqueKeysWithValues: deck.map { ($0.card.id, $0.image) })
        let builder = CardIndexBuilder(
            rectifier: rectifier,
            extractor: CardDescriptorExtractor(featurePrinter: ThumbnailFeaturePrintGenerator(), canvas: canvas),
            maxConcurrency: 2,
            now: { [fixedDate] in fixedDate }
        )
        return await builder.build(cards: deck.map(\.card), image: { images[$0.id] }).index
    }

    func recognizer(
        index: CardIndex,
        locator: any CardLocating = FakeCardLocator(),
        ocr: [String] = [],
        policy: ScoringPolicy = .default,
        overlay: ExemplarIndex = .empty,
        excludedBatches: Set<UUID> = []
    ) -> CardRecognizer {
        CardRecognizer(
            index: index,
            locator: locator,
            rectifier: rectifier,
            descriptorExtractor: extractor,
            codeReader: PrintedCodeReader(textRecognizer: StubTextRecognizer(ocr), renderer: renderer, canvas: canvas, parser: PrintedCodeParser(vocabulary: index.vocabulary)),
            fingerprint: fingerprint,
            policy: policy,
            overlay: overlay,
            excludedBatches: excludedBatches
        )
    }

    /// An overlay holding one exemplar per print, all for `group`, all from `batch`.
    func overlay(group: ArtGroup, prints: [FeaturePrint], batch: UUID = UUID(), version: Int = 1) async throws -> ExemplarIndex {
        let calibration = try await ThumbnailFeaturePrintGenerator().calibrationPrint()
        return ExemplarIndex(version: version, calibrationPrint: calibration, exemplars: prints.enumerated().map { offset, print in
            ExemplarIndex.Exemplar(artGroup: group, featurePrint: print, scanID: UUID(), batchID: batch, admittedAt: fixedDate.addingTimeInterval(Double(offset)))
        })
    }
}
