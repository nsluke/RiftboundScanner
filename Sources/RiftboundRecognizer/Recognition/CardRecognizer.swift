import CoreGraphics
import Foundation

/// One ranked candidate.
public struct Match: Hashable, Sendable, Identifiable {
    public let card: Card
    /// Fused descriptor score plus OCR adjustment; higher is better.
    public let score: Double
    /// The fused descriptor score: the reference score lifted by exemplar
    /// evidence for the card's art group, when there is any.
    public let descriptorScore: Double
    /// The descriptor score against the reference index alone.
    public let referenceScore: Double
    /// The best feature-print cosine to an exemplar of the card's art group;
    /// `nil` when none has been learned.
    public let exemplarSimilarity: Double?
    public let components: ScoreComponents
    public let orientation: CardOrientation
    /// `nil` when no code could be read.
    public let codeAgreement: CodeAgreement?

    public var id: Card.ID { card.id }

    public init(
        card: Card,
        score: Double,
        descriptorScore: Double,
        referenceScore: Double,
        exemplarSimilarity: Double?,
        components: ScoreComponents,
        orientation: CardOrientation,
        codeAgreement: CodeAgreement?
    ) {
        self.card = card
        self.score = score
        self.descriptorScore = descriptorScore
        self.referenceScore = referenceScore
        self.exemplarSimilarity = exemplarSimilarity
        self.components = components
        self.orientation = orientation
        self.codeAgreement = codeAgreement
    }

    /// A match with no exemplar evidence, whose reference score is its
    /// descriptor score. Apps and their tests build matches directly, e.g. to
    /// stub a recogniser.
    public init(card: Card, score: Double, descriptorScore: Double, components: ScoreComponents, orientation: CardOrientation, codeAgreement: CodeAgreement?) {
        self.init(
            card: card,
            score: score,
            descriptorScore: descriptorScore,
            referenceScore: descriptorScore,
            exemplarSimilarity: nil,
            components: components,
            orientation: orientation,
            codeAgreement: codeAgreement
        )
    }
}

/// What one card-location hypothesis produced, for diagnostics.
public struct HypothesisSummary: Hashable, Sendable {
    public let location: CardLocation
    public let bestCard: Card.ID?
    /// The best match's ``Match/score`` (fused descriptor score plus code
    /// adjustment): how the matches *within* this hypothesis were ranked. Not
    /// what chose between hypotheses; see ``selectionScore``. With exemplars
    /// present a losing hypothesis can show a higher `bestScore` than the winner.
    /// For a hypothesis that was not OCR'd it is the best reference score.
    public let bestScore: Double
    /// The fused descriptor score of the best match.
    public let descriptorScore: Double
    /// The hypothesis's best reference score over every candidate: what ranked
    /// it for OCR against the other hypotheses and what the whole-image rule
    /// is held to.
    public let referenceScore: Double
    /// The score the winning hypothesis was chosen by: the best
    /// `referenceScore + code adjustment` among its matches, exemplar
    /// evidence excluded. Equals ``referenceScore`` for a hypothesis that was
    /// not OCR'd, and ``bestScore`` whenever no exemplars are in force.
    public let selectionScore: Double
    public let codeRead: PrintedCode?

    public init(location: CardLocation, bestCard: Card.ID?, bestScore: Double, descriptorScore: Double, referenceScore: Double, selectionScore: Double, codeRead: PrintedCode?) {
        self.location = location
        self.bestCard = bestCard
        self.bestScore = bestScore
        self.descriptorScore = descriptorScore
        self.referenceScore = referenceScore
        self.selectionScore = selectionScore
        self.codeRead = codeRead
    }
}

public struct RecognitionResult: Sendable {
    public let matches: [Match]
    public let location: CardLocation
    /// The most confident code reading, if any.
    public let codeReading: CodeReading?
    public let rectifiedCard: CGImage
    /// The query descriptor of the winning hypothesis, in the orientation of
    /// the winning match: the upside-down query when the card matched upside
    /// down, the upright one otherwise (and when nothing matched at all). It is
    /// the descriptor to compare with the matched card's reference, and the one
    /// a confirmed scan contributes as an exemplar.
    public let descriptor: OrientedDescriptor
    /// Which recogniser build and embedding produced this result.
    public let engine: EngineFingerprint
    /// Every hypothesis that was recognised, in the order tried; the result
    /// itself comes from the best-scoring one.
    public let hypotheses: [HypothesisSummary]

    public init(
        matches: [Match],
        location: CardLocation,
        codeReading: CodeReading?,
        rectifiedCard: CGImage,
        descriptor: OrientedDescriptor,
        engine: EngineFingerprint,
        hypotheses: [HypothesisSummary] = []
    ) {
        self.matches = matches
        self.location = location
        self.codeReading = codeReading
        self.rectifiedCard = rectifiedCard
        self.descriptor = descriptor
        self.engine = engine
        self.hypotheses = hypotheses
    }

    public var best: Match? { matches.first }

    /// The card's corners in the photo when a card was located; `nil` when the
    /// whole image was assumed to be the card.
    public var quad: CardQuad? {
        if case .detected(let quad, _) = location { quad } else { nil }
    }

    func summary(referenceScore: Double, selectionScore: Double) -> HypothesisSummary {
        HypothesisSummary(
            location: location,
            bestCard: best?.id,
            bestScore: best?.score ?? 0,
            descriptorScore: best?.descriptorScore ?? 0,
            referenceScore: referenceScore,
            selectionScore: selectionScore,
            codeRead: codeReading?.code
        )
    }
}

/// The recognition pipeline: locate → rectify → describe → nearest neighbours → OCR re-ranking.
///
/// Every collaborator arrives through the initializer; ``live(index:renderer:policy:)``
/// wires the production graph. The data it matches against (the reference
/// ``index``, the learned ``overlay`` and the ``policy``) can be swapped
/// without rebuilding the collaborators through ``replacing(index:overlay:policy:excludedBatches:)``.
public struct CardRecognizer: Sendable {
    public let index: CardIndex
    /// Learned exemplars fused into descriptor scores; ``ExemplarIndex/empty``
    /// leaves every result exactly as the reference index alone would.
    public let overlay: ExemplarIndex
    /// Batches whose exemplars are ignored (on-device re-identification of a
    /// batch must not benefit from what that batch taught).
    public let excludedBatches: Set<UUID>
    public let policy: ScoringPolicy
    /// Stamped on every result; see ``EngineFingerprint``.
    public let fingerprint: EngineFingerprint
    private let locator: any CardLocating
    private let rectifier: CardRectifier
    private let descriptorExtractor: CardDescriptorExtractor
    private let codeReader: PrintedCodeReader
    private let frame: CardFrame
    private let matcher: DescriptorMatcher

    /// `fingerprint` should come from the same feature printer as
    /// `descriptorExtractor` (``EngineFingerprint/current(calibrating:)``), so
    /// that results are stamped with the embedding that produced them.
    public init(
        index: CardIndex,
        locator: any CardLocating,
        rectifier: CardRectifier,
        descriptorExtractor: CardDescriptorExtractor,
        codeReader: PrintedCodeReader,
        fingerprint: EngineFingerprint,
        frame: CardFrame = .riftbound,
        policy: ScoringPolicy = .default,
        overlay: ExemplarIndex = .empty,
        excludedBatches: Set<UUID> = []
    ) {
        self.index = index
        self.overlay = overlay
        self.excludedBatches = excludedBatches
        self.fingerprint = fingerprint
        self.locator = locator
        self.rectifier = rectifier
        self.descriptorExtractor = descriptorExtractor
        self.codeReader = codeReader
        self.frame = frame
        self.policy = policy
        self.matcher = DescriptorMatcher(policy: policy, exemplars: overlay, excluding: excludedBatches)
    }

    /// The same collaborators (locator, rectifier, descriptor extractor and the
    /// code reader with its single text recogniser) matching against new data.
    /// Arguments left `nil` keep the current value.
    ///
    /// A replacement index must use the same canvas specification and sets as
    /// the current one: the rectifier, extractor and OCR vocabulary were built
    /// for it. Changing those means wiring a fresh recogniser.
    public func replacing(
        index: CardIndex? = nil,
        overlay: ExemplarIndex? = nil,
        policy: ScoringPolicy? = nil,
        excludedBatches: Set<UUID>? = nil
    ) -> CardRecognizer {
        CardRecognizer(
            index: index ?? self.index,
            locator: locator,
            rectifier: rectifier,
            descriptorExtractor: descriptorExtractor,
            codeReader: codeReader,
            fingerprint: fingerprint,
            frame: frame,
            policy: policy ?? self.policy,
            overlay: overlay ?? self.overlay,
            excludedBatches: excludedBatches ?? self.excludedBatches
        )
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
    ///
    /// Everything that chooses between hypotheses (their ordering for OCR, the
    /// whole-image rule and the final winner) uses reference scores only, so
    /// learned exemplars can change which card wins but never where the card
    /// was found (ADR-002, decision 7). ``HypothesisSummary/selectionScore``
    /// reports the number each hypothesis was judged by.
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
        var shortlist = Array(located.sorted { $0.referenceScore > $1.referenceScore }.prefix(max(1, policy.ocrHypothesisCount)))
        if let wholeImage {
            shortlist.append(wholeImage)
        }
        var recognised: [Int: RecognisedHypothesis] = [:]
        for hypothesis in shortlist {
            var reading = try await codeReader.readCode(from: hypothesis.canvas).first
            if reading == nil, case .assumedWholeImage = hypothesis.location {
                // The edge bands of the whole image miss a code that sits inside
                // a crop; read the photo itself before giving up on it.
                reading = try await codeReader.readCode(fromFullImage: photo).first
            }
            let reranked = rerank(hypothesis.candidates, with: reading, queries: hypothesis.queries)
            let result = RecognitionResult(
                matches: reranked.map(\.match),
                location: hypothesis.location,
                codeReading: reading,
                rectifiedCard: hypothesis.canvas,
                descriptor: Self.winningDescriptor(for: reranked.map(\.match), among: hypothesis.queries),
                engine: fingerprint
            )
            recognised[hypothesis.order] = RecognisedHypothesis(
                result: result,
                referenceScore: hypothesis.referenceScore,
                selectionScore: reranked.map(\.selectionScore).max() ?? -1
            )
        }

        // The whole image only competes when it looks like a cropped card (a
        // high reference score, or a code read off it), or when nothing else
        // was found: a photo's background routinely scores 0.6–0.7 against some
        // unrelated printing, which must not outrank a located card.
        let eligible = recognised.sorted { $0.key < $1.key }.map(\.value).filter { hypothesis in
            guard case .assumedWholeImage = hypothesis.result.location else { return true }
            return located.isEmpty
                || hypothesis.result.codeReading != nil
                || hypothesis.referenceScore >= policy.wholeImageMinimumScore
        }
        guard let winner = eligible.max(by: { $0.selectionScore < $1.selectionScore }) else {
            throw RecognitionError.noHypotheses
        }
        let summaries = described.map { hypothesis in
            recognised[hypothesis.order].map { $0.result.summary(referenceScore: $0.referenceScore, selectionScore: $0.selectionScore) } ?? HypothesisSummary(
                location: hypothesis.location,
                bestCard: hypothesis.candidates.first?.entry.id,
                bestScore: hypothesis.referenceScore,
                descriptorScore: hypothesis.candidates.first?.fusedScore ?? 0,
                referenceScore: hypothesis.referenceScore,
                selectionScore: hypothesis.referenceScore,
                codeRead: nil
            )
        }
        return RecognitionResult(
            matches: winner.result.matches,
            location: winner.result.location,
            codeReading: winner.result.codeReading,
            rectifiedCard: winner.result.rectifiedCard,
            descriptor: winner.result.descriptor,
            engine: winner.result.engine,
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
        let matches = rerank(candidates, with: reading, queries: queries).map(\.match)
        return RecognitionResult(
            matches: matches,
            location: location,
            codeReading: reading,
            rectifiedCard: canvas,
            descriptor: Self.winningDescriptor(for: matches, among: queries),
            engine: fingerprint
        )
    }

    /// The query in the orientation of the best match, or the upright query
    /// when there is no match (an empty index) or, defensively, no such query.
    private static func winningDescriptor(for matches: [Match], among queries: [OrientedDescriptor]) -> OrientedDescriptor {
        let orientation = matches.first?.orientation ?? .upright
        guard let chosen = queries.first(where: { $0.orientation == orientation }) ?? queries.first(where: { $0.orientation == .upright }) ?? queries.first else {
            preconditionFailure("a hypothesis is always described in at least one orientation")
        }
        return chosen
    }

    private struct DescribedHypothesis: Sendable {
        let order: Int
        let location: CardLocation
        let canvas: CGImage
        let queries: [OrientedDescriptor]
        let candidates: [DescriptorCandidate]

        /// The best reference score over every candidate: the hypothesis's
        /// standing against the other hypotheses, untouched by exemplars.
        var referenceScore: Double { candidates.map(\.referenceScore).max() ?? 0 }
    }

    private struct RecognisedHypothesis: Sendable {
        let result: RecognitionResult
        let referenceScore: Double
        /// The best reference-plus-code score among the matches: what decides
        /// the winning hypothesis. Identical to the best match's `score` when
        /// there are no exemplars.
        let selectionScore: Double
    }

    /// A match together with the score the hypothesis is chosen by.
    private struct RerankedMatch: Sendable {
        let match: Match
        let selectionScore: Double
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
        return (queries, matcher.rank(queries, in: index, limit: policy.rerankedCandidateCount))
    }

    /// Applies the OCR evidence to each candidate and sorts by the fused score.
    ///
    /// A confidently read code names a card outright, so every index entry whose
    /// code it matches joins the candidates even when the descriptors ranked it
    /// outside the shortlist: a poorly located card (the whole feeder tray, say)
    /// can still carry a legible code while its art matches nothing.
    private func rerank(_ candidates: [DescriptorCandidate], with reading: CodeReading?, queries: [OrientedDescriptor]) -> [RerankedMatch] {
        var candidates = candidates
        if let reading, reading.confidence >= policy.codeInjectionMinimumConfidence {
            let present = Set(candidates.map(\.entry.id))
            for entry in index.entries where !present.contains(entry.id) {
                switch CodeAgreement(reading: reading.code, candidate: entry.card.code) {
                case .exact, .variantDiffers:
                    if let candidate = matcher.candidate(for: entry, queries: queries) {
                        candidates.append(candidate)
                    }
                default:
                    continue
                }
            }
        }
        return candidates.map { candidate -> RerankedMatch in
            let agreement = reading.map { CodeAgreement(reading: $0.code, candidate: candidate.entry.card.code) }
            var adjustment = 0.0
            if let reading, let agreement {
                adjustment = policy.codeAdjustment(for: agreement, confidence: reading.confidence)
            }
            let match = Match(
                card: candidate.entry.card,
                score: candidate.fusedScore + adjustment,
                descriptorScore: candidate.fusedScore,
                referenceScore: candidate.referenceScore,
                exemplarSimilarity: candidate.exemplarSimilarity,
                components: candidate.components,
                orientation: candidate.orientation,
                codeAgreement: agreement
            )
            return RerankedMatch(match: match, selectionScore: candidate.referenceScore + adjustment)
        }.sorted { $0.match.score > $1.match.score }
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
    ///
    /// Calibrates Vision's feature printer first (one feature print of the
    /// ``CalibrationCanvas``), which is why this runs asynchronously and can fail.
    public static func live(index: CardIndex, renderer: ImageRenderer = ImageRenderer(), policy: ScoringPolicy = .default, overlay: ExemplarIndex = .empty) async throws -> CardRecognizer {
        let featurePrinter = VisionFeaturePrintGenerator()
        return CardRecognizer(
            index: index,
            locator: VisionCardLocator(),
            rectifier: CardRectifier(renderer: renderer, canvas: index.canvas),
            descriptorExtractor: CardDescriptorExtractor(featurePrinter: featurePrinter, canvas: index.canvas),
            codeReader: PrintedCodeReader(
                textRecognizer: VisionTextRecognizer(),
                renderer: renderer,
                canvas: index.canvas,
                parser: PrintedCodeParser(vocabulary: index.vocabulary)
            ),
            fingerprint: try await EngineFingerprint.current(calibrating: featurePrinter),
            policy: policy,
            overlay: overlay
        )
    }
}
