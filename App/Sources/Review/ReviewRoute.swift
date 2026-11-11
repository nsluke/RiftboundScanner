/// Where review goes from the Scan tab and from History. Every way into a
/// batch opens the same screen, `BatchReviewView`.
enum ReviewRoute: Hashable {
    /// The batch: what still needs a look, then every scan in it.
    case batch(ScanBatch)
    /// Scans opened from the batch's screen, walked one at a time from
    /// `start` in the order of `ids`, in the same view the queue uses.
    case scans(ScanBatch, ids: [ScanRecord.ID], start: ScanRecord.ID)
    /// A sample of the batch's accepted scans, re-checked as `spotCheck` decisions.
    case spotCheck(ScanBatch, candidates: [ScanRecord.ID], limit: Int)
}
