/// A printing's finish as the ledger records it (ADR-002 §4.2).
nonisolated enum Finish: String, Hashable, Sendable, Codable, CaseIterable {
    case normal
    case foil
}
