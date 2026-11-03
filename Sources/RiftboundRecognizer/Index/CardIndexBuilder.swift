import CoreGraphics
import Foundation

/// Builds a ``CardIndex`` from reference images, a few cards at a time.
public struct CardIndexBuilder: Sendable {
    public struct Failure: Hashable, Sendable {
        public let id: Card.ID
        public let reason: String
    }

    public struct Outcome: Sendable {
        public let index: CardIndex
        public let missingImages: [Card.ID]
        public let failures: [Failure]
    }

    private let rectifier: CardRectifier
    private let extractor: CardDescriptorExtractor
    private let maxConcurrency: Int
    private let now: @Sendable () -> Date

    public init(
        rectifier: CardRectifier,
        extractor: CardDescriptorExtractor,
        maxConcurrency: Int = 4,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.rectifier = rectifier
        self.extractor = extractor
        self.maxConcurrency = max(1, maxConcurrency)
        self.now = now
    }

    /// Indexes every card for which `image` returns a reference image. Entries
    /// come back sorted by id so the index file is stable.
    public func build(
        cards: [Card],
        image: @escaping @Sendable (Card) throws -> CGImage?,
        progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async -> Outcome {
        var entries: [CardIndex.Entry] = []
        var missing: [Card.ID] = []
        var failures: [Failure] = []
        var completed = 0
        await withTaskGroup(of: Step.self) { group in
            var pending = cards[...]
            for card in pending.prefix(maxConcurrency) {
                group.addTask { await self.step(for: card, image: image) }
            }
            pending = pending.dropFirst(maxConcurrency)
            for await step in group {
                completed += 1
                switch step {
                case .indexed(let entry): entries.append(entry)
                case .missing(let id): missing.append(id)
                case .failed(let failure): failures.append(failure)
                }
                progress?(completed, cards.count)
                if let card = pending.first {
                    pending = pending.dropFirst()
                    group.addTask { await self.step(for: card, image: image) }
                }
            }
        }
        entries.sort { $0.card.id.rawValue < $1.card.id.rawValue }
        return Outcome(
            index: CardIndex(canvas: rectifier.canvas, builtAt: now(), entries: entries),
            missingImages: missing,
            failures: failures
        )
    }

    private enum Step: Sendable {
        case indexed(CardIndex.Entry)
        case missing(Card.ID)
        case failed(Failure)
    }

    private func step(for card: Card, image: @Sendable (Card) throws -> CGImage?) async -> Step {
        do {
            guard let reference = try image(card) else { return .missing(card.id) }
            let canvasImage = try rectifier.canonicalImage(fromReference: reference, orientation: card.orientation)
            let descriptor = try await extractor.descriptor(for: canvasImage)
            return .indexed(CardIndex.Entry(card: card, descriptor: descriptor))
        } catch {
            return .failed(Failure(id: card.id, reason: String(describing: error)))
        }
    }
}
