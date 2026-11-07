/// Where the review flow can go from the Scan tab and from History.
enum ReviewRoute: Hashable {
    /// The batch's uncertain scans, then the ones held for audit, one at a time.
    case queue(ScanBatch)
    /// Every scan in the batch, grouped by what it needs.
    case overview(ScanBatch)
    /// A sample of the batch's accepted scans, re-checked as `spotCheck` decisions.
    case spotCheck(ScanBatch, candidates: [ScanRecord.ID], limit: Int)
}
