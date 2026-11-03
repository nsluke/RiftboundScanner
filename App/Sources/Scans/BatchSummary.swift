/// Tallies of one batch's verdicts, the headline numbers of a test sitting.
nonisolated struct BatchSummary: Hashable, Sendable {
    let total: Int
    let pending: Int
    let correct: Int
    let corrected: Int
    let rejected: Int
    /// Judged scans whose confirmed card was among the top three candidates.
    let topThreeHits: Int

    init(records: [ScanRecord]) {
        var pending = 0, correct = 0, corrected = 0, rejected = 0, topThreeHits = 0
        for record in records {
            switch record.verdict {
            case .pending: pending += 1
            case .correct: correct += 1
            case .corrected: corrected += 1
            case .rejected: rejected += 1
            }
            if let confirmed = record.confirmedCardID, record.candidates.prefix(3).contains(where: { $0.card.id == confirmed }) {
                topThreeHits += 1
            }
        }
        total = records.count
        self.pending = pending
        self.correct = correct
        self.corrected = corrected
        self.rejected = rejected
        self.topThreeHits = topThreeHits
    }

    /// Scans where the user named the card, so the recogniser can be scored.
    var judged: Int { correct + corrected }

    var topOneAccuracy: Double? { judged > 0 ? Double(correct) / Double(judged) : nil }
    var topThreeAccuracy: Double? { judged > 0 ? Double(topThreeHits) / Double(judged) : nil }
}
