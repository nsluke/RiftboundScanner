import Foundation
import RiftboundRecognizer

/// The grid that settles a batch's uncertain scans in one pass: every scan
/// beside its match, presumed right. The user flags the wrong ones (and marks
/// foils), then confirms the rest at once; the flagged ones go on to the
/// one-at-a-time queue, which opens each straight into the fix panel.
///
/// Only scans whose sole problem is the recogniser's doubt (`ScanTier.needsALook`
/// with a match) are tiles. A printing to pick, a possible duplicate, an
/// unknown card and an audit each need their own look, and an audit's
/// verdict feeds the precision bound, so it is never confirmed in bulk
/// (ADR-002, decision 6). Each confirmation is the same `human` decision
/// the queue's Return writes.
@Observable
final class ReviewTriageModel {
    enum Phase: Hashable {
        case triaging
        /// Writing the confirmations; `done` of `total` so far.
        case confirming(done: Int, of: Int)
        /// Every unflagged tile was confirmed.
        case confirmed(Int)
    }

    let batch: ScanBatch
    let directory: CardDirectory
    let vault: CardVault
    let rule: ConfidenceRule
    private(set) var tiles: Loadable<[ScanRecord], ScanProblem> = .idle
    private(set) var flagged: Set<ScanRecord.ID> = []
    /// The tile the keyboard is on, shown large beside the grid.
    var focusedID: ScanRecord.ID?
    private(set) var phase: Phase = .triaging
    private(set) var storageProblem: ScanProblem?
    /// Pending scans the grid leaves to the queue: printings to pick,
    /// possible duplicates, unknown cards and audits.
    private(set) var leftForQueue = 0

    /// Finishes the user changed from the inherited one, by tile.
    private var chosenFinish: [ScanRecord.ID: Finish] = [:]
    private let store: any ScanStoring

    init(batch: ScanBatch, store: any ScanStoring, directory: CardDirectory, vault: CardVault, rule: ConfidenceRule = .default) {
        self.batch = batch
        self.store = store
        self.directory = directory
        self.vault = vault
        self.rule = rule
    }

    func load() async {
        tiles = .loading
        do {
            let records = try await store.records(in: batch.id).sorted { $0.capturedAt < $1.capturedAt }
            var grid: [ScanRecord] = []
            var others = 0
            for record in records {
                switch record.tier(under: rule, in: batch, vault: vault, directory: directory) {
                case .needsALook where record.topCandidate != nil:
                    grid.append(record)
                case .needsALook, .pickPrinting, .unknown, .possibleDuplicate:
                    others += 1
                case .confident:
                    if record.isAuditSample(rate: rule.auditRate) { others += 1 }
                case nil:
                    break
                }
            }
            leftForQueue = others
            flagged = []
            chosenFinish = [:]
            phase = .triaging
            focusedID = grid.first?.id
            tiles = .loaded(grid)
        } catch {
            tiles = .failed(.storage(String(describing: error)))
        }
    }

    var focused: ScanRecord? {
        tiles.value?.first { $0.id == focusedID }
    }

    func photoURL(for record: ScanRecord) -> URL {
        store.photoURL(for: record)
    }

    /// Why the recogniser was unsure of this tile, in the review screen's words.
    func doubt(about record: ScanRecord) -> String? {
        guard case .uncertain(let reason) = record.reviewKind(under: rule, in: batch, vault: vault, directory: directory) else { return nil }
        return reason.message(isArtWeak: record.hasWeakArtMatch)
    }

    var unflaggedCount: Int {
        (tiles.value?.count ?? 0) - flagged.count
    }

    func isFlagged(_ record: ScanRecord) -> Bool {
        flagged.contains(record.id)
    }

    func toggleFlag(_ id: ScanRecord.ID) {
        guard phase == .triaging else { return }
        if flagged.remove(id) == nil {
            flagged.insert(id)
        }
    }

    // MARK: - Finish

    /// Whether the tile's printing comes in both finishes (or the vault cannot
    /// say), so the grid lets it be marked foil.
    func asksForFinish(_ record: ScanRecord) -> Bool {
        finishResolution(record).asksUser
    }

    /// The finish the tile will be confirmed with.
    func finish(of record: ScanRecord) -> Finish? {
        chosenFinish[record.id] ?? inheritedFinish(record)
    }

    /// Switches a tile between normal and foil. A tile whose printing has one
    /// finish only is left alone.
    func toggleFoil(_ id: ScanRecord.ID) {
        guard phase == .triaging, let record = tiles.value?.first(where: { $0.id == id }), asksForFinish(record) else { return }
        let next: Finish = finish(of: record) == .foil ? .normal : .foil
        chosenFinish[id] = next == inheritedFinish(record) ? nil : next
    }

    private func finishResolution(_ record: ScanRecord) -> FinishPolicy.Resolution {
        let key = record.effectivePrintingCode ?? record.topCandidate.map { PrintingKey($0.card.code) }
        return FinishPolicy.resolve(card: key.flatMap { vault[$0] }, batchDefault: batch.defaultFinish ?? .normal)
    }

    private func inheritedFinish(_ record: ScanRecord) -> Finish? {
        record.effectiveFinish ?? finishResolution(record).preselectedFinish
    }

    // MARK: - Keyboard

    enum Move {
        case left, right, up, down
    }

    /// Moves the focus one tile, or one row of `columns`, stopping at the edges.
    func moveFocus(_ move: Move, columns: Int) {
        guard let records = tiles.value, !records.isEmpty else { return }
        let index = records.firstIndex { $0.id == focusedID } ?? 0
        let step = switch move {
        case .left: -1
        case .right: 1
        case .up: -max(columns, 1)
        case .down: max(columns, 1)
        }
        let next = index + step
        guard records.indices.contains(next) else { return }
        focusedID = records[next].id
    }

    // MARK: - Confirming

    /// Confirms every tile not flagged, in capture order, as the queue's
    /// Return would: `.correct` from a `human`, with the finish the tile
    /// shows. Stops at the first failure; the tiles confirmed so far leave
    /// the grid and the rest stay to try again.
    func confirmUnflagged() async {
        guard phase == .triaging, let records = tiles.value else { return }
        let toConfirm = records.filter { !flagged.contains($0.id) }
        guard !toConfirm.isEmpty else {
            phase = .confirmed(0)
            return
        }
        var confirmed: Set<ScanRecord.ID> = []
        phase = .confirming(done: 0, of: toConfirm.count)
        for record in toConfirm {
            do {
                _ = try await store.decide(record.id, in: batch.id, DecisionInput(.correct, source: .human, finish: finishOverride(record)))
                confirmed.insert(record.id)
                phase = .confirming(done: confirmed.count, of: toConfirm.count)
            } catch {
                storageProblem = .storage(String(describing: error))
                tiles = .loaded(records.filter { !confirmed.contains($0.id) })
                if let focusedID, confirmed.contains(focusedID) {
                    self.focusedID = tiles.value?.first?.id
                }
                phase = .triaging
                return
            }
        }
        phase = .confirmed(confirmed.count)
    }

    /// `.set` only when the user changed the finish of a printing that asks.
    private func finishOverride(_ record: ScanRecord) -> Override<Finish> {
        guard asksForFinish(record), let chosen = chosenFinish[record.id], chosen != inheritedFinish(record) else { return .inherit }
        return .set(chosen)
    }

    func dismissStorageProblem() {
        storageProblem = nil
    }
}
