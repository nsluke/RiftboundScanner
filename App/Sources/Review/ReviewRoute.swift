/// Where the review flow can go from the Scan tab and from History.
enum ReviewRoute: Hashable {
    /// The batch's uncertain scans, then the ones held for audit, one at a time.
    case queue(ScanBatch)
    /// The batch's uncertain scans in a grid, flagged or confirmed in one
    /// pass, then the rest one at a time.
    case triage(ScanBatch)
    /// Every scan in the batch, grouped by what it needs.
    case overview(ScanBatch)
    /// A sample of the batch's accepted scans, re-checked as `spotCheck` decisions.
    case spotCheck(ScanBatch, candidates: [ScanRecord.ID], limit: Int)

    /// Where "Review" goes. A Mac window fits a run's scans side by side, so
    /// it triages them in a grid first; the iPhone walks them one at a time.
    static func review(_ batch: ScanBatch) -> ReviewRoute {
        #if os(macOS)
        .triage(batch)
        #else
        .queue(batch)
        #endif
    }
}
