import Foundation

/// How a physical card is finished. The ledger records one per card.
nonisolated enum Finish: String, Hashable, Sendable, Codable, CaseIterable {
    case normal
    case foil
}

/// Decides how a scan gets its finish from the vault's availability flags
/// (ADR-002, decision 3): single-finish printings are forced silently, a
/// both-finish printing takes the batch default and shows a Normal/Foil
/// toggle, and a printing the vault does not know, or lists with neither
/// finish, leaves the choice to the user with no default.
nonisolated enum FinishPolicy {
    enum Resolution: Hashable, Sendable {
        /// Only one finish exists; record it without asking.
        case forced(Finish)
        /// Both finishes exist; pre-select `default` and offer the other.
        case prompt(default: Finish)
        /// The vault lists neither finish or does not know the printing.
        case unknown

        /// The finish a review UI pre-selects, `nil` when there is none.
        var preselectedFinish: Finish? {
            switch self {
            case .forced(let finish): finish
            case .prompt(let finish): finish
            case .unknown: nil
            }
        }

        /// Whether the UI shows a finish control at all.
        var asksUser: Bool {
            switch self {
            case .forced: false
            case .prompt, .unknown: true
            }
        }
    }

    /// `card` is the vault row for the printing, `nil` when the vault does not
    /// have one; `batchDefault` is the run's default finish for both-finish printings.
    static func resolve(card: VaultCard?, batchDefault: Finish) -> Resolution {
        guard let card else { return .unknown }
        switch (card.hasNormal, card.hasFoil) {
        case (true, false): return .forced(.normal)
        case (false, true): return .forced(.foil)
        case (true, true): return .prompt(default: batchDefault)
        case (false, false): return .unknown
        }
    }
}
