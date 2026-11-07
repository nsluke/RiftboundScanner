import Foundation
import RiftboundRecognizer

/// Which printings a scan of `card` may be ledgered as, and whether the user
/// has to say which (ADR-002, decision 13). The chips are the vault's
/// siblings of the recognised printing: same set and collector number, any
/// suffix. A sealed box holds no promos, so a sealed-box batch keeps its promo
/// siblings behind "Other printings…"; a loose pile shows them up front.
nonisolated struct PrintingOptions: Hashable, Sendable {
    /// The printing the recogniser named, as the ledger would key it.
    let recognized: PrintingKey
    /// The chips shown up front, in vault order; the recognised printing's
    /// row leads when the vault has one.
    let shown: [VaultCard]
    /// Promo siblings a sealed-box batch folds away.
    let hidden: [VaultCard]
    /// Whether one of the shown printings is one the recogniser can never
    /// tell from the recognised one (a promo, a rune back), so a person must
    /// choose before the scan ledgers. Always false for a calibration batch:
    /// nothing in it reaches the ledger, so there is nothing to pick.
    let needsChoice: Bool

    init(card: Card, batch: ScanBatch, vault: CardVault, directory: CardDirectory) {
        let recognized = PrintingKey(card.code)
        let siblings = vault.siblings(of: vault.vaultCode(for: card.id) ?? "")
        var shown: [VaultCard] = []
        var hidden: [VaultCard] = []
        for row in siblings {
            if batch.product?.hidesPromoPrintings == true, row.promo, row.key != recognized {
                hidden.append(row)
            } else {
                shown.append(row)
            }
        }
        // The recognised printing is always the first chip.
        if let position = shown.firstIndex(where: { $0.key == recognized }), position != 0 {
            shown.insert(shown.remove(at: position), at: 0)
        }
        self.recognized = recognized
        self.shown = shown
        self.hidden = hidden
        needsChoice = batch.purpose == .collection && shown.contains { $0.key != recognized && directory.card(forKey: $0.key) == nil }
    }

    /// Every printing on offer, shown first.
    var all: [VaultCard] { shown + hidden }

    /// Whether there is anything to pick at all.
    var hasAlternatives: Bool { all.count > 1 }

    func row(for key: PrintingKey) -> VaultCard? {
        all.first { $0.key == key }
    }
}

nonisolated extension BatchProduct {
    /// A sealed box contains no promo printings, so they are folded away
    /// rather than offered (ADR-002, decision 13).
    var hidesPromoPrintings: Bool {
        if case .sealedBox = self { return true }
        return false
    }
}

/// What a pending scan needs next (ADR-002 §6). One of five, so the
/// run-complete strip, the review queue and bulk acceptance agree on which
/// scans a person has to see.
nonisolated enum ScanTier: Hashable, Sendable, CaseIterable {
    /// Code read literally, exact agreement, score over the bar, printing
    /// settled: accepted without a look unless the audit sample holds it.
    case confident
    /// The recogniser was not sure (`UncertaintyReason`).
    case needsALook
    /// The card is known but which printing is not: the code's variant
    /// disagreed, or a sibling the recogniser cannot see is possible here.
    case pickPrinting
    /// Looks like a card fed moments ago (ADR-002, decision 16).
    case possibleDuplicate
    /// Nothing in the index resembled the photo.
    case unknown

    /// The tier of a pending scan. `printingOptions` is what the review
    /// screen would offer for the top candidate; `nil` when there is none.
    init(_ record: ScanRecord, rule: ConfidenceRule, printingOptions: PrintingOptions?) {
        if record.analysis?.duplicateOf != nil {
            self = .possibleDuplicate
            return
        }
        guard record.topCandidate != nil else {
            self = .unknown
            return
        }
        switch record.confidence(under: rule) {
        case .uncertain(.variantOnly):
            self = .pickPrinting
        case .uncertain:
            self = .needsALook
        case .confident:
            self = printingOptions?.needsChoice == true ? .pickPrinting : .confident
        }
    }

    var label: String {
        switch self {
        case .confident: String(localized: "Confident")
        case .needsALook: String(localized: "Needs a look")
        case .pickPrinting: String(localized: "Pick printing")
        case .possibleDuplicate: String(localized: "Possible duplicate")
        case .unknown: String(localized: "Unknown")
        }
    }

    /// Whether the review queue shows the scan without the audit sample's say.
    var needsAPerson: Bool {
        switch self {
        case .confident: false
        case .needsALook, .pickPrinting, .possibleDuplicate, .unknown: true
        }
    }
}

nonisolated extension ScanRecord {
    /// The printings this scan's top candidate could be ledgered as; `nil`
    /// without a top candidate.
    func printingOptions(in batch: ScanBatch, vault: CardVault, directory: CardDirectory) -> PrintingOptions? {
        topCandidate.map { PrintingOptions(card: $0.card, batch: batch, vault: vault, directory: directory) }
    }

    /// The tier of this scan while it is pending; `nil` once decided.
    func tier(under rule: ConfidenceRule, in batch: ScanBatch, vault: CardVault, directory: CardDirectory) -> ScanTier? {
        guard verdict == .pending else { return nil }
        return ScanTier(self, rule: rule, printingOptions: printingOptions(in: batch, vault: vault, directory: directory))
    }

    /// Confident, pending and not sampled: what "Accept the confident"
    /// accepts. The tier, not `ScanConfidence` alone, decides, so a possible
    /// duplicate or an unsettled printing is never accepted in bulk.
    func isAcceptable(under rule: ConfidenceRule, in batch: ScanBatch, vault: CardVault, directory: CardDirectory) -> Bool {
        tier(under: rule, in: batch, vault: vault, directory: directory) == .confident && !isAuditSample(rate: rule.auditRate)
    }

    /// Confident, pending, but sampled for audit.
    func isHeldForAudit(under rule: ConfidenceRule, in batch: ScanBatch, vault: CardVault, directory: CardDirectory) -> Bool {
        tier(under: rule, in: batch, vault: vault, directory: directory) == .confident && isAuditSample(rate: rule.auditRate)
    }

    /// Why this pending scan needs a person under the five tiers, or `nil`
    /// when it can be accepted without one.
    func reviewKind(under rule: ConfidenceRule, in batch: ScanBatch, vault: CardVault, directory: CardDirectory) -> ReviewKind? {
        guard let tier = tier(under: rule, in: batch, vault: vault, directory: directory) else { return nil }
        switch tier {
        case .possibleDuplicate: return .possibleDuplicate
        case .unknown: return .unknown
        case .pickPrinting: return .pickPrinting
        case .needsALook: return confidence(under: rule).reason.map(ReviewKind.uncertain) ?? .unknown
        case .confident: return isAuditSample(rate: rule.auditRate) ? .audit : nil
        }
    }
}

/// Counts per tier for a set of scans, for the run-complete strip.
nonisolated struct TierCounts: Hashable, Sendable {
    private(set) var counts: [ScanTier: Int] = [:]
    /// Confident scans the audit sample holds back.
    private(set) var heldForAudit = 0
    /// Scans that already have a verdict.
    private(set) var decided = 0

    /// Counts nothing without a batch: tiers are relative to one.
    init(records: [ScanRecord], rule: ConfidenceRule, batch: ScanBatch?, vault: CardVault, directory: CardDirectory) {
        guard let batch else { return }
        for record in records {
            guard let tier = record.tier(under: rule, in: batch, vault: vault, directory: directory) else {
                decided += 1
                continue
            }
            counts[tier, default: 0] += 1
            if tier == .confident, record.isAuditSample(rate: rule.auditRate) {
                heldForAudit += 1
            }
        }
    }

    subscript(tier: ScanTier) -> Int { counts[tier] ?? 0 }

    /// Confident and not sampled: what one tap accepts.
    var acceptable: Int { self[.confident] - heldForAudit }

    /// Pending rows the review queue will show.
    var toReview: Int { ScanTier.allCases.filter(\.needsAPerson).reduce(0) { $0 + self[$1] } + heldForAudit }
}
