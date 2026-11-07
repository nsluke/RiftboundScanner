import Foundation
import RiftboundRecognizer

/// Walks a batch's uncertain scans one at a time, writing each verdict as it
/// is given. Loads the batch itself so it can be pushed from anywhere.
@Observable
final class ReviewQueueModel {
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

    let batch: ScanBatch
    let directory: CardDirectory
    private(set) var queue: Loadable<[ScanRecord], ScanProblem> = .idle
    /// Index into the loaded queue of the scan on screen.
    private(set) var position = 0
    private(set) var tally = Tally()
    private(set) var storageProblem: ScanProblem?
    /// The set most of the batch's scans belong to, for prefilling corrections.
    private(set) var dominantSet: SetCode?

    private let store: any ScanStoring
    private let now: @Sendable () -> Date

    init(batch: ScanBatch, store: any ScanStoring, directory: CardDirectory, now: @escaping @Sendable () -> Date) {
        self.batch = batch
        self.store = store
        self.directory = directory
        self.now = now
    }

    var current: ScanRecord? {
        guard let records = queue.value, records.indices.contains(position) else { return nil }
        return records[position]
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
            queue = .loaded(records.filter(\.needsReview))
            position = 0
            tally = Tally()
            dominantSet = Self.dominantSet(in: records)
        } catch {
            queue = .failed(.storage(String(describing: error)))
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

    /// Leaves the scan pending and moves on; it stays in the batch's to-review list.
    func skip() {
        guard current != nil else { return }
        tally.skipped += 1
        position += 1
    }

    func dismissStorageProblem() {
        storageProblem = nil
    }

    private func decide(_ verdict: Verdict, counting: (inout Tally) -> Void) async {
        guard var record = current else { return }
        record.verdict = verdict
        record.verdictAt = now()
        do {
            try await store.update(record)
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
