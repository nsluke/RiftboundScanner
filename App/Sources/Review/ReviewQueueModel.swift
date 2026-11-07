import Foundation
import RiftboundRecognizer

/// Walks a batch's scans that need a person one at a time, writing each
/// verdict as it is given with the source its row calls for: `human` for an
/// uncertain scan, `audit` for a confident one the policy sampled, `spotCheck`
/// for an accepted one re-checked on request. Loads the batch itself so it
/// can be pushed from anywhere.
@Observable
final class ReviewQueueModel {
    /// What the queue holds.
    enum Mode: Hashable {
        /// The batch's pending scans: the uncertain ones in capture order,
        /// then the ones held for audit.
        case pending
        /// Up to `limit` of `candidates`, which must be accepted scans of this
        /// batch; the sampler picks which.
        case spotCheck(candidates: [ScanRecord.ID], limit: Int)

        var isSpotCheck: Bool {
            if case .spotCheck = self { return true }
            return false
        }
    }

    struct Tally: Hashable {
        var confirmed = 0
        var corrected = 0
        var rejected = 0
        var skipped = 0

        var decided: Int { confirmed + corrected + rejected }
    }

    enum Progress: Hashable {
        case reviewing(position: Int, of: Int)
        case done(Tally)
        /// Nothing in the batch needed a look.
        case nothingToReview
    }

    /// Picks which accepted scans a spot-check re-checks; random in the app,
    /// scripted in tests.
    typealias Sampler = @Sendable (_ candidates: [ScanRecord], _ limit: Int) -> [ScanRecord]

    let batch: ScanBatch
    let directory: CardDirectory
    let mode: Mode
    /// The confident tier the queue was opened under; fixed for its lifetime
    /// so a policy change cannot reshuffle rows mid-review.
    let rule: ConfidenceRule
    private(set) var queue: Loadable<[ScanRecord], ScanProblem> = .idle
    /// Index into the loaded queue of the scan on screen.
    private(set) var position = 0
    private(set) var tally = Tally()
    private(set) var storageProblem: ScanProblem?
    /// The set most of the batch's scans belong to, for prefilling corrections.
    private(set) var dominantSet: SetCode?

    private let store: any ScanStoring
    private let sample: Sampler

    init(
        batch: ScanBatch,
        store: any ScanStoring,
        directory: CardDirectory,
        rule: ConfidenceRule = .default,
        mode: Mode = .pending,
        sample: @escaping Sampler = { Array($0.shuffled().prefix($1)) }
    ) {
        self.batch = batch
        self.store = store
        self.directory = directory
        self.rule = rule
        self.mode = mode
        self.sample = sample
    }

    var current: ScanRecord? {
        guard let records = queue.value, records.indices.contains(position) else { return nil }
        return records[position]
    }

    /// Why the scan on screen is here, which is also the source its verdict
    /// will carry. `nil` between rows.
    var currentKind: ReviewKind? {
        current.map(kind(of:))
    }

    var progress: Progress? {
        guard let records = queue.value else { return nil }
        if records.isEmpty { return .nothingToReview }
        if position >= records.count { return .done(tally) }
        return .reviewing(position: position + 1, of: records.count)
    }

    func photoURL(for record: ScanRecord) -> URL {
        store.photoURL(for: record)
    }

    func load() async {
        queue = .loading
        do {
            let records = try await store.records(in: batch.id).sorted { $0.capturedAt < $1.capturedAt }
            queue = .loaded(rows(in: records))
            position = 0
            tally = Tally()
            dominantSet = Self.dominantSet(in: records)
        } catch {
            queue = .failed(.storage(String(describing: error)))
        }
    }

    /// Uncertain scans first, then the audit sample (ADR-002 §6), or the
    /// spot-check sample of accepted scans.
    private func rows(in records: [ScanRecord]) -> [ScanRecord] {
        switch mode {
        case .pending:
            return records.filter { $0.needsReview(under: rule) } + records.filter { $0.isHeldForAudit(under: rule) }
        case .spotCheck(let candidates, let limit):
            let wanted = Set(candidates)
            let accepted = records.filter { wanted.contains($0.id) && $0.lastDecision?.source == .autoAccepted }
            return sample(accepted, limit).sorted { $0.capturedAt < $1.capturedAt }
        }
    }

    /// Why a queued record is in the queue.
    func kind(of record: ScanRecord) -> ReviewKind {
        switch mode {
        case .spotCheck: .spotCheck
        case .pending: record.reviewKind(under: rule) ?? .audit
        }
    }

    // MARK: - Verdicts

    func confirm() async {
        await decide(.correct) { $0.confirmed += 1 }
    }

    func correct(to card: Card.ID) async {
        guard let current else { return }
        if card == current.topCandidate?.card.id {
            await confirm()
        } else {
            await decide(.corrected(card)) { $0.corrected += 1 }
        }
    }

    func reject(_ reason: RejectionReason) async {
        await decide(.rejected(reason)) { $0.rejected += 1 }
    }

    /// Leaves the scan as it is and moves on; a pending one stays in the
    /// batch's to-review list.
    func skip() {
        guard current != nil else { return }
        tally.skipped += 1
        position += 1
    }

    func dismissStorageProblem() {
        storageProblem = nil
    }

    /// Every verdict is appended by the store, with the source the row calls
    /// for: `human`, `audit` or `spotCheck` (ADR-002, decision 6).
    private func decide(_ verdict: Verdict, counting: (inout Tally) -> Void) async {
        guard let record = current else { return }
        do {
            let decided = try await store.decide(record.id, in: batch.id, DecisionInput(verdict, source: kind(of: record).source))
            if var records = queue.value, records.indices.contains(position) {
                records[position] = decided
                queue = .loaded(records)
            }
            counting(&tally)
            position += 1
        } catch {
            storageProblem = .storage(String(describing: error))
        }
    }

    /// The set the most top candidates belong to; ties go to the earlier set code.
    static func dominantSet(in records: [ScanRecord]) -> SetCode? {
        var counts: [SetCode: Int] = [:]
        for record in records {
            if let set = record.topCandidate?.card.code.set {
                counts[set, default: 0] += 1
            }
        }
        return counts.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
        }?.key
    }
}
