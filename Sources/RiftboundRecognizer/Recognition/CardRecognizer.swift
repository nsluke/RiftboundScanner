import CoreGraphics

/// One ranked candidate.
public struct Match: Hashable, Sendable, Identifiable {
    public let card: Card
    /// Descriptor score plus OCR adjustment; higher is better.
    public let score: Double
    public let descriptorScore: Double
    public let components: ScoreComponents
    public let orientation: CardOrientation
    /// `nil` when no code could be read.
    public let codeAgreement: CodeAgreement?

    public var id: Card.ID { card.id }

    /// Apps and their tests build matches directly, e.g. to stub a recogniser.
    public init(card: Card, score: Double, descriptorScore: Double, components: ScoreComponents, orientation: CardOrientation, codeAgreement: CodeAgreement?) {
        self.card = card
        self.score = score
        self.descriptorScore = descriptorScore
        self.components = components
        self.orientation = orientation
        self.codeAgreement = codeAgreement
    }
}

/// What one card-location hypothesis produced, for diagnostics.
public struct HypothesisSummary: Hashable, Sendable {
    public let location: CardLocation
    public let bestCard: Card.ID?
    public let bestScore: Double
    public let descriptorScore: Double
    public let codeRead: PrintedCode?
}

public struct RecognitionResult: Sendable {
    public let matches: [Match]
    public let location: CardLocation
    /// The most confident code reading, if any.
    public let codeReading: CodeReading?
    public let rectifiedCard: CGImage
    /// Every hypothesis that was recognised, in the order tried; the result
    /// itself comes from the best-scoring one.
    public let hypotheses: [HypothesisSummary]

    public init(matches: [Match], location: CardLocation, codeReading: CodeReading?, rectifiedCard: CGImage, hypotheses: [HypothesisSummary] = []) {
        self.matches = matches
        self.location = location
        self.codeReading = codeReading
        self.rectifiedCard = rectifiedCard
        self.hypotheses = hypotheses
    }

    public var best: Match? { matches.first }

    var summary: HypothesisSummary {
        HypothesisSummary(
            location: location,
            bestCard: best?.id,
            bestScore: best?.score ?? 0,
            descriptorScore: best?.descriptorScore ?? 0,
            codeRead: codeReading?.code
        )
    }
}

/// The recognition pipeline: locate → rectify → describe → nearest neighbours → OCR re-ranking.
///
/// Every collaborator arrives through the initializer; ``live(index:renderer:policy:)``
/// wires the production graph.
public struct CardRecognizer: Sendable {
    public let index: CardIndex
    private let locator: any CardLocating
    private let rectifier: CardRectifier
    private let descriptorExtractor: CardDescriptorExtractor
    private let codeReader: PrintedCodeReader
    private let frame: CardFrame
    private let policy: ScoringPolicy

    public init(
        index: CardIndex,
        locator: any CardLocating,
        rectifier: CardRectifier,
        descriptorExtractor: CardDescriptorExtractor,
        codeReader: PrintedCodeReader,
        frame: CardFrame = .riftbound,
        policy: ScoringPolicy = .default
    ) {
        self.index = index
        self.locator = locator
        self.rectifier = rectifier
        self.descriptorExtractor = descriptorExtractor
        self.codeReader = codeReader
        self.frame = frame
        self.policy = policy
    }

    /// Identifies the card in a photo. Runs off the caller's actor: Vision,
    /// Core Image and hashing are far too heavy for the main actor.
    ///
    /// Each located rectangle is tried as found and expanded from the printed
    /// frame to the card edge (saliency-fitted candidates are already the card's
    /// outline), and the whole image is tried last (it wins for inputs that are
    /// already cropped to the card). Every hypothesis is
    /// rectified and scored on descriptors; the best few also get OCR, and the
    /// hypothesis whose best match scores highest is returned, with every
    /// hypothesis summarised in ``RecognitionResult/hypotheses``. The whole-image
    /// hypothesis is held to ``ScoringPolicy/wholeImageMinimumScore``.
    @concurrent
    public func identify(_ photo: CGImage) async throws -> RecognitionResult {
        let candidates = try await locator.locateCards(in: photo)
        var locations: [CardLocation] = []
        for candidate in candidates {
            locations.append(.detected(candidate.quad, confidence: candidate.confidence))
            if candidate.source == .rectangleDetector {
                locations.append(.detected(frame.outerQuad(from: candidate.quad), confidence: candidate.confidence))
            }
        }
        locations = Array(locations.prefix(max(0, policy.maximumLocationHypotheses)))
        locations.append(.assumedWholeImage)
        let fullImage = CardQuad(fullImageOfSize: PixelSize(width: photo.width, height: photo.height))

        // Phase 1: rectify and score every hypothesis on descriptors, in parallel.
        let described = try await withThrowingTaskGroup(of: DescribedHypothesis.self) { group in
            for (order, location) in locations.enumerated() {
                let quad: CardQuad = switch location {
                case .detected(let quad, _): quad
                case .assumedWholeImage: fullImage
                }
                group.addTask {
                    let canvas = try rectifier.rectify(photo, quad: quad)
                    let (queries, candidates) = try await describe(canvas)
                    return DescribedHypothesis(order: order, location: location, canvas: canvas, queries: queries, candidates: candidates)
                }
            }
            var collected: [DescribedHypothesis] = []
            for try await hypothesis in group {
                collected.append(hypothesis)
            }
            return collected.sorted { $0.order < $1.order }
        }

        // Phase 2: OCR the most promising few and re-rank them. The whole image
        // is always read as well: when the photo is already a tight crop (a
        // feeder stand, a scanner bed) its printed code is legible there even
        // when the rectangle detector has latched onto something else.
        let located = described.filter { if case .assumedWholeImage = $0.location { false } else { true } }
        let wholeImage = described.first { if case .assumedWholeImage = $0.location { true } else { false } }
        var shortlist = Array(located.sorted { $0.descriptorScore > $1.descriptorScore }.prefix(max(1, policy.ocrHypothesisCount)))
        if let wholeImage {
            shortlist.append(wholeImage)
        }
        var results: [Int: RecognitionResult] = [:]
        for hypothesis in shortlist {
            var reading = try await codeReader.readCode(from: hypothesis.canvas).first
            if reading == nil, case .assumedWholeImage = hypothesis.location {
                // The edge bands of the whole image miss a code that sits inside
                // a crop; read the photo itself before giving up on it.
                reading = try await codeReader.readCode(fromFullImage: photo).first
            }
            results[hypothesis.order] = RecognitionResult(
                matches: rerank(hypothesis.candidates, with: reading, queries: hypothesis.queries),
                location: hypothesis.location,
                codeReading: reading,
                rectifiedCard: hypothesis.canvas
            )
        }

        // The whole image only competes when it looks like a cropped card (a
        // high descriptor score, or a code read off it), or when nothing else
        // was found: a photo's background routinely scores 0.6–0.7 against some
        // unrelated printing, which must not outrank a located card.
        let eligible = results.values.filter { result in
            guard case .assumedWholeImage = result.location else { return true }
            return located.isEmpty
                || result.codeReading != nil
                || (result.best?.descriptorScore ?? 0) >= policy.wholeImageMinimumScore
        }
        guard let winner = eligible.max(by: { ($0.best?.score ?? -1) < ($1.best?.score ?? -1) }) else {
            throw RecognitionError.noHypotheses
        }
        let summaries = described.map { hypothesis in
            results[hypothesis.order]?.summary ?? HypothesisSummary(
                location: hypothesis.location,
                bestCard: hypothesis.candidates.first?.entry.id,
                bestScore: hypothesis.descriptorScore,
                descriptorScore: hypothesis.descriptorScore,
                codeRead: nil
            )
        }
        return RecognitionResult(
            matches: winner.matches,
            location: winner.location,
            codeReading: winner.codeReading,
            rectifiedCard: winner.rectifiedCard,
            hypotheses: summaries
        )
    }

    /// Identifies a card that is already on the canonical canvas.
    @concurrent
    public func identify(rectifiedCard canvas: CGImage, location: CardLocation = .assumedWholeImage) async throws -> RecognitionResult {
        async let described = describe(canvas)
        async let readings = codeReader.readCode(from: canvas)
        let reading = try await readings.first
        let (queries, candidates) = try await described
        let matches = rerank(candidates, with: reading, queries: queries)
        return RecognitionResult(matches: matches, location: location, codeReading: reading, rectifiedCard: canvas)
    }

    private struct DescribedHypothesis: Sendable {
        let order: Int
        let location: CardLocation
        let canvas: CGImage
        let queries: [OrientedDescriptor]
        let candidates: [DescriptorCandidate]

        var descriptorScore: Double { candidates.first?.score ?? 0 }
    }

    /// Descriptor candidates for a canvas, tried upright and upside down, with
    /// the query descriptors they were ranked against.
    private func describe(_ canvas: CGImage) async throws -> (queries: [OrientedDescriptor], candidates: [DescriptorCandidate]) {
        let flipped = try rectifier.renderer.rotated(canvas, quarterTurnsCounterclockwise: 2)
        async let uprightDescriptor = descriptorExtractor.descriptor(for: canvas)
        async let flippedDescriptor = descriptorExtractor.descriptor(for: flipped)
        let queries = [
            OrientedDescriptor(descriptor: try await uprightDescriptor, orientation: .upright),
            OrientedDescriptor(descriptor: try await flippedDescriptor, orientation: .upsideDown),
        ]
        return (queries, DescriptorMatcher(policy: policy).rank(queries, in: index, limit: policy.rerankedCandidateCount))
    }

    /// Applies the OCR evidence to each candidate and sorts by the fused score.
    ///
    /// A confidently read code names a card outright, so every index entry whose
    /// code it matches joins the candidates even when the descriptors ranked it
    /// outside the shortlist: a poorly located card (the whole feeder tray, say)
    /// can still carry a legible code while its art matches nothing.
    private func rerank(_ candidates: [DescriptorCandidate], with reading: CodeReading?, queries: [OrientedDescriptor]) -> [Match] {
        var candidates = candidates
        if let reading, reading.confidence >= policy.codeInjectionMinimumConfidence {
            let present = Set(candidates.map(\.entry.id))
            for entry in index.entries where !present.contains(entry.id) {
                switch CodeAgreement(reading: reading.code, candidate: entry.card.code) {
                case .exact, .variantDiffers:
                    if let candidate = DescriptorMatcher(policy: policy).candidate(for: entry, queries: queries) {
                        candidates.append(candidate)
                    }
                default:
                    continue
                }
            }
        }
        return candidates.map { candidate -> Match in
            let agreement = reading.map { CodeAgreement(reading: $0.code, candidate: candidate.entry.card.code) }
            var adjustment = 0.0
            if let reading, let agreement {
                adjustment = policy.codeAdjustment(for: agreement, confidence: reading.confidence)
            }
            return Match(
                card: candidate.entry.card,
                score: candidate.score + adjustment,
                descriptorScore: candidate.score,
                components: candidate.components,
                orientation: candidate.orientation,
                codeAgreement: agreement
            )
        }.sorted { $0.score > $1.score }
    }
}

/// Recognition produced nothing to rank; should not happen, since the whole image is always a hypothesis.
public enum RecognitionError: Error {
    case noHypotheses
}

extension CardRecognizer {
    /// The production object graph: Vision for detection, OCR and feature
    /// prints, Core Image for rectification. Apps may wire their own graph
    /// instead; every collaborator is an initializer parameter.
    public static func live(index: CardIndex, renderer: ImageRenderer = ImageRenderer(), policy: ScoringPolicy = .default) -> CardRecognizer {
        CardRecognizer(
            index: index,
            locator: VisionCardLocator(),
            rectifier: CardRectifier(renderer: renderer, canvas: index.canvas),
            descriptorExtractor: CardDescriptorExtractor(featurePrinter: VisionFeaturePrintGenerator(), canvas: index.canvas),
            codeReader: PrintedCodeReader(
                textRecognizer: VisionTextRecognizer(),
                renderer: renderer,
                canvas: index.canvas,
                parser: PrintedCodeParser(vocabulary: index.vocabulary)
            ),
            policy: policy
        )
    }
}
