import Foundation
import RiftboundRecognizer

/// Walks a batch's scans that need a person one at a time, writing each
/// verdict as it is given with the source its row calls for: `human` for an
/// uncertain scan, a printing to pick, a possible duplicate or an unknown
/// card, `audit` for a confident one the policy sampled, `spotCheck` for an
/// accepted one re-checked on request. Loads the batch itself so it can be
/// pushed from anywhere.
///
/// Finish and printing are record-level state folded from the decision log
/// (ADR-002, decision 3): the screen pre-selects what the log already says
/// (or what `FinishPolicy` and the recognised printing imply) and a decision
/// writes `.set` only when the user changed it, so an audit that agrees
/// never flips an earlier choice.
@Observable
final class ReviewQueueModel {
    /// What the queue holds.
    enum Mode: Hashable {
        /// The batch's pending scans: the ones that need a person in capture
        /// order, then the possible duplicates, then the ones held for audit.
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
        var deleted = 0

        var decided: Int { confirmed + corrected + rejected + deleted }
    }

    /// What happened to one row in this sitting. Kept per scan, so going back
    /// and deciding again replaces the earlier outcome instead of adding one.
    enum Outcome: Hashable {
        case confirmed
        case corrected
        case rejected
        case skipped
        case deleted
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
    let vault: CardVault
    let mode: Mode
    /// The confident tier the queue was opened under; fixed for its lifetime
    /// so a policy change cannot reshuffle rows mid-review.
    let rule: ConfidenceRule
    private(set) var queue: Loadable<[ScanRecord], ScanProblem> = .idle
    /// Index into the loaded queue of the scan on screen.
    private(set) var position = 0 {
        didSet { resetSelection() }
    }
    private(set) var outcomes: [ScanRecord.ID: Outcome] = [:]
    private(set) var storageProblem: ScanProblem?
    /// The set most of the batch's scans belong to, for prefilling corrections.
    private(set) var dominantSet: SetCode?
    /// The set of the last card this sitting corrected to; a run is usually
    /// fed a set at a time, so the next fix looks there first.
    private(set) var lastFixSet: SetCode?
    /// Scans the triage grid flagged as wrong: they lead the queue and open
    /// straight into the fix panel.
    let flagged: Set<ScanRecord.ID>
    /// The printing the ledger gets for the scan on screen; starts as the
    /// inherited one and changes only when the user taps a chip.
    var selectedPrinting: PrintingKey? {
        didSet {
            guard selectedPrinting != oldValue else { return }
            selectedFinish = inheritedFinish
        }
    }
    /// The finish the ledger gets for the scan on screen when the printing
    /// comes in both; starts as the inherited one.
    var selectedFinish: Finish?

    /// Every record of the batch as loaded, for looking up what a duplicate repeats.
    private var records: [ScanRecord] = []
    private let store: any ScanStoring
    private let sample: Sampler

    init(
        batch: ScanBatch,
        store: any ScanStoring,
        directory: CardDirectory,
        vault: CardVault,
        rule: ConfidenceRule = .default,
        mode: Mode = .pending,
        flagged: Set<ScanRecord.ID> = [],
        sample: @escaping Sampler = { Array($0.shuffled().prefix($1)) }
    ) {
        self.batch = batch
        self.store = store
        self.directory = directory
        self.vault = vault
        self.rule = rule
        self.mode = mode
        self.flagged = flagged
        self.sample = sample
    }

    var tally: Tally {
        outcomes.values.reduce(into: Tally()) { tally, outcome in
            switch outcome {
            case .confirmed: tally.confirmed += 1
            case .corrected: tally.corrected += 1
            case .rejected: tally.rejected += 1
            case .skipped: tally.skipped += 1
            case .deleted: tally.deleted += 1
            }
        }
    }

    /// Where a bare collector number is looked up first in the fix panel.
    var fixSet: SetCode? {
        lastFixSet ?? dominantSet
    }

    /// Whether the scan on screen was flagged as wrong in the triage grid
    /// and has not been decided since.
    var currentIsFlagged: Bool {
        guard let current else { return false }
        return flagged.contains(current.id) && outcomes[current.id] == nil
    }

    var canGoBack: Bool {
        position > 0 && queue.value != nil
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

    /// The scan the one on screen appears to repeat, when it is a possible duplicate.
    var duplicateOf: ScanRecord? {
        guard let id = current?.analysis?.duplicateOf else { return nil }
        return records.first { $0.id == id }
    }

    func photoURL(for record: ScanRecord) -> URL {
        store.photoURL(for: record)
    }

    func load() async {
        queue = .loading
        do {
            let loaded = try await store.records(in: batch.id).sorted { $0.capturedAt < $1.capturedAt }
            records = loaded
            queue = .loaded(rows(in: loaded))
            outcomes = [:]
            dominantSet = Self.dominantSet(in: loaded)
            position = 0
            resetSelection()
        } catch {
            queue = .failed(.storage(String(describing: error)))
        }
    }

    /// The scans that need a person in capture order, then the possible
    /// duplicates, then the audit sample (ADR-002 §6), or the spot-check
    /// sample of accepted scans.
    private func rows(in records: [ScanRecord]) -> [ScanRecord] {
        switch mode {
        case .pending:
            var needPerson: [ScanRecord] = []
            var duplicates: [ScanRecord] = []
            var audits: [ScanRecord] = []
            for record in records {
                switch record.tier(under: rule, in: batch, vault: vault, directory: directory) {
                case .needsALook, .pickPrinting, .unknown: needPerson.append(record)
                case .possibleDuplicate: duplicates.append(record)
                case .confident: if record.isAuditSample(rate: rule.auditRate) { audits.append(record) }
                case nil: break
                }
            }
            let flaggedFirst = needPerson.filter { flagged.contains($0.id) } + needPerson.filter { !flagged.contains($0.id) }
            return flaggedFirst + duplicates + audits
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
        case .pending: record.reviewKind(under: rule, in: batch, vault: vault, directory: directory) ?? .audit
        }
    }

    // MARK: - Finish and printing

    /// The chips for the scan on screen; `nil` without a top candidate.
    var printingOptions: PrintingOptions? {
        current?.printingOptions(in: batch, vault: vault, directory: directory)
    }

    /// The printing the log already settled on, else the recognised one.
    var inheritedPrinting: PrintingKey? {
        guard let current else { return nil }
        return current.effectivePrintingCode ?? current.topCandidate.map { PrintingKey($0.card.code) }
    }

    /// How the selected printing gets its finish.
    var finishResolution: FinishPolicy.Resolution {
        FinishPolicy.resolve(card: (selectedPrinting ?? inheritedPrinting).flatMap { vault[$0] }, batchDefault: batch.defaultFinish ?? .normal)
    }

    /// The finish the ledger would derive with no new override: what the log
    /// already set, else the policy's pre-selection for the selected printing.
    var inheritedFinish: Finish? {
        current?.effectiveFinish ?? finishResolution.preselectedFinish
    }

    /// Whether the Normal/Foil control shows: only when the printing comes in
    /// both (or the vault cannot say).
    var asksForFinish: Bool { finishResolution.asksUser }

    /// `.set` only when the user changed the finish of a printing that asks.
    var finishOverride: Override<Finish> {
        guard asksForFinish, let selectedFinish, selectedFinish != inheritedFinish else { return .inherit }
        return .set(selectedFinish)
    }

    /// `.set` only when the user picked a printing other than the inherited one.
    var printingOverride: Override<PrintingKey> {
        guard let selectedPrinting, selectedPrinting != inheritedPrinting else { return .inherit }
        return .set(selectedPrinting)
    }

    private func resetSelection() {
        selectedPrinting = inheritedPrinting
        selectedFinish = inheritedFinish
    }

    // MARK: - Verdicts

    /// Confirms the scan as the printing and finish on screen. A chip naming
    /// a printing the index also knows (an alternate art the code could not
    /// settle) is a correction to that card; a chip the recogniser cannot see
    /// (a promo) keeps `confirmedCardID` on the recognised card and sets the
    /// ledger printing (ADR-002, decision 13).
    func confirm() async {
        guard let current else { return }
        let recognized = current.topCandidate.map { PrintingKey($0.card.code) }
        if let selectedPrinting, selectedPrinting != recognized,
           let sibling = directory.card(forKey: selectedPrinting), sibling.id != current.topCandidate?.card.id {
            let printing: Override<PrintingKey> = current.effectivePrintingCode == nil ? .inherit : .set(selectedPrinting)
            await decide(.corrected(sibling.id), finish: finishOverride, printing: printing, outcome: .corrected)
        } else {
            await decide(.correct, finish: finishOverride, printing: printingOverride, outcome: .confirmed)
        }
    }

    /// A different card altogether. The finish and printing chips were for
    /// the recognised card, so they are not carried over; an earlier
    /// printing override is replaced by the new card's own key so the fold
    /// cannot keep ledgering the old printing.
    func correct(to card: Card.ID) async {
        guard let current else { return }
        if card == current.topCandidate?.card.id {
            await confirm()
            return
        }
        let printing: Override<PrintingKey> = current.effectivePrintingCode == nil ? .inherit : (PrintingKey(cardID: card).map { .set($0) } ?? .inherit)
        let set = directory[card]?.code.set
        await decide(.corrected(card), finish: .inherit, printing: printing, outcome: .corrected)
        if let set {
            lastFixSet = set
        }
    }

    func reject(_ reason: RejectionReason) async {
        await decide(.rejected(reason), finish: .inherit, printing: .inherit, outcome: .rejected)
    }

    /// "Keep both": the possible duplicate is a second copy after all.
    func keepBoth() async {
        await confirm()
    }

    /// "Drop": the feeder fed this card twice; the earlier scan stands.
    func drop() async {
        await reject(.duplicateCapture)
    }

    /// Takes the scan out of the batch: a misfeed, a blurred photo, a card
    /// that should not be there. It is a `voided` decision like a voided
    /// batch's, so it leaves review, the collection and the label count, its
    /// photo stops uploading, and Previous can still bring it back. Always
    /// `human`: deleting says nothing about whether the recogniser was right,
    /// so it is never an audit or spot-check answer.
    func delete() async {
        await decide(.voided, finish: .inherit, printing: .inherit, outcome: .deleted, source: .human)
    }

    /// Leaves the scan as it is and moves on; a pending one stays in the
    /// batch's to-review list.
    func skip() {
        guard let current else { return }
        outcomes[current.id] = outcomes[current.id] ?? .skipped
        position += 1
    }

    /// Back to the scan before, decided or skipped, so it can be decided
    /// again. Decisions are append-only (ADR-002, decision 2): a new verdict
    /// supersedes the earlier one rather than erasing it.
    func goBack() {
        guard canGoBack else { return }
        position -= 1
    }

    func dismissStorageProblem() {
        storageProblem = nil
    }

    /// Every verdict is appended by the store, with the source the row calls
    /// for: `human`, `audit` or `spotCheck` (ADR-002, decision 6), unless
    /// `source` says otherwise.
    private func decide(_ verdict: Verdict, finish: Override<Finish>, printing: Override<PrintingKey>, outcome: Outcome, source: DecisionSource? = nil) async {
        guard let record = current else { return }
        do {
            let decided = try await store.decide(record.id, in: batch.id, DecisionInput(verdict, source: source ?? kind(of: record).source, finish: finish, ledgerPrintingCode: printing))
            if var rows = queue.value, rows.indices.contains(position) {
                rows[position] = decided
                queue = .loaded(rows)
            }
            records = records.map { $0.id == decided.id ? decided : $0 }
            outcomes[decided.id] = outcome
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
