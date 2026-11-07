import Foundation
import RiftboundRecognizer

/// Catches a card the feeder fed twice (ADR-002, decision 16). At identify
/// time the new scan's oriented descriptor is compared with the last few
/// scans of the same run: a feature-print cosine at or above the threshold
/// to a scan naming the same top `ArtGroup` marks the new scan a possible
/// duplicate, which keeps it out of bulk acceptance and puts "Same card as
/// the previous scan? Keep both / Drop" in the review queue. Two real copies
/// of one common fed back to back are the false positive this accepts: a
/// tap on "Keep both" costs less than a double-counted card.
nonisolated struct DuplicateGuard: Hashable, Sendable {
    /// Feature-print cosine at or above which two scans look like one card.
    var similarityThreshold: Double
    /// How many of the run's latest scans are compared.
    var window: Int

    init(similarityThreshold: Double = 0.985, window: Int = 5) {
        self.similarityThreshold = similarityThreshold
        self.window = window
    }

    /// The ADR's values.
    static let standard = DuplicateGuard()

    /// Compares against nothing; for tests that feed one canned result
    /// repeatedly and are not about duplicates.
    static let off = DuplicateGuard(window: 0)

    /// The most similar same-art scan among the last `window` of `recent`
    /// (oldest first) that clears the threshold, or `nil`.
    func duplicate(of record: ScanRecord, among recent: [ScanRecord]) -> ScanRecord.ID? {
        guard window > 0, let analysis = record.analysis, let group = record.topCandidate?.card.artGroup else { return nil }
        let print = analysis.descriptor.descriptor.featurePrint
        var best: (id: ScanRecord.ID, similarity: Double)?
        for earlier in recent.suffix(window) where earlier.id != record.id {
            guard let other = earlier.analysis, earlier.topCandidate?.card.artGroup == group else { continue }
            let similarity = print.similarity(to: other.descriptor.descriptor.featurePrint)
            guard similarity >= similarityThreshold, similarity > (best?.similarity ?? -1) else { continue }
            best = (earlier.id, similarity)
        }
        return best?.id
    }

    /// `record` with `analysis.duplicateOf` set when it repeats one of
    /// `recent`, else unchanged.
    func marking(_ record: ScanRecord, among recent: [ScanRecord]) -> ScanRecord {
        guard let match = duplicate(of: record, among: recent), let analysis = record.analysis else { return record }
        return record.replacingAnalysis(analysis.markingDuplicate(of: match))
    }
}

nonisolated extension ScanAnalysis {
    /// The same analysis naming the scan this one appears to repeat.
    func markingDuplicate(of scan: ScanRecord.ID) -> ScanAnalysis {
        ScanAnalysis(
            descriptor: descriptor,
            quad: quad,
            codeSource: codeSource,
            codeAlternatives: codeAlternatives,
            shortlist: shortlist,
            duplicateOf: scan,
            analyzedAt: analyzedAt
        )
    }
}

nonisolated extension ScanRecord {
    /// A copy with a different analysis and everything else, decisions
    /// included, unchanged. Used before the record is saved; a saved record's
    /// analysis changes only through re-identification.
    func replacingAnalysis(_ analysis: ScanAnalysis?) -> ScanRecord {
        ScanRecord(
            id: id,
            batchID: batchID,
            capturedAt: capturedAt,
            photoFileName: photoFileName,
            rectifiedFileName: rectifiedFileName,
            processingSeconds: processingSeconds,
            placement: placement,
            codeReading: codeReading,
            candidates: candidates,
            decisions: decisions,
            crop: crop,
            analysis: analysis,
            engine: engine,
            captureQuality: captureQuality
        )
    }
}
