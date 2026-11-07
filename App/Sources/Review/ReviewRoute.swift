/// Where the review flow can go from the Scan tab and from History.
enum ReviewRoute: Hashable {
    /// The batch's uncertain scans, one at a time.
    case queue(ScanBatch)
    /// Every scan in the batch, grouped by what it needs.
    case overview(ScanBatch)
}
