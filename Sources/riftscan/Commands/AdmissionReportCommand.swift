import Foundation
import RiftboundRecognizer

/// Prints what the gate's thresholds rest on, from a `build-overlay --dump`:
/// the impostor similarity distribution between scans of different art
/// groups, the reference floor's ROC and the admit/reject reasons per fold.
enum AdmissionReportCommand {
    static func run(_ arguments: ArraySlice<String>) throws {
        let options = try CommandLineOptions(arguments)
        let path = try options.positional(0, named: "admissions.json")
        let dump = try AdmissionDump.read(from: URL(fileURLWithPath: path))
        let floor = try options.double("floor", default: dump.policy.referenceSimilarityFloor)
        let report = dump.report()

        Console.line("Admission dump \(path): gate v\(dump.gateVersion), \(dump.analyses.count) scans analysed on \(dump.engine.platform) \(dump.engine.osVersion) (calibration \(dump.engine.calibrationHash.hex)), \(dump.assumptions.description)")
        Console.line("Policy: floor \(dump.policy.referenceSimilarityFloor), alternative margin \(dump.policy.alternativeMargin), witness \(dump.policy.witnessMutualSimilarity)/\(dump.policy.witnessReferenceFloor), impostor \(dump.policy.impostorSimilarity), duplicate \(dump.policy.duplicateSimilarity), cap \(dump.policy.maximumPerGroup)")
        Console.line()
        Console.line("Impostor similarity (feature-print cosine between scans of different art groups, \(report.impostorPairCount) pairs over \(report.scanCount) scans):")
        Console.line("  p50 \(String(format: "%.4f", report.impostorP50))  p95 \(String(format: "%.4f", report.impostorP95))  p99 \(String(format: "%.4f", report.impostorP99))  max \(String(format: "%.4f", report.impostorMax))  pairs at or above \(dump.policy.impostorSimilarity): \(report.impostorCollisions)")
        Console.line("Genuine reference similarity (scan to its confirmed card's reference): p50 \(String(format: "%.4f", report.genuineP50))")
        Console.line()
        Console.line("Reference floor ROC (genuine = similarity to the confirmed card; impostor = best similarity to another art group's reference):")
        Console.line("  \(Console.pad("floor", 8))\(Console.pad("genuine pass", 14))impostor pass")
        for point in report.roc {
            let marker = abs(point.threshold - floor) < 1e-9 ? "  <- floor" : ""
            Console.line("  \(Console.pad(String(format: "%.2f", point.threshold), 8))\(Console.pad(Console.percent(point.genuinePassRate), 14))\(Console.percent(point.impostorPassRate))\(marker)")
        }
        Console.line()
        for fold in dump.folds {
            let reasons = (report.reasonsByFold[fold.name] ?? [:]).sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            Console.line("Fold \(fold.name): \(fold.records.count) scans gated, \(fold.exemplarCount) exemplars in \(fold.exemplarsByGroup.count) groups\(fold.overlayFile.map { " → \($0)" } ?? "")")
            for (reason, count) in reasons {
                Console.line("  \(Console.pad(reason, 36))\(count)")
            }
            let admitted = fold.records.filter(\.outcome.isAdmitted)
            if !admitted.isEmpty {
                let tiers = Dictionary(grouping: admitted, by: { $0.outcome.tier?.rawValue ?? "?" }).mapValues(\.count).sorted { $0.key < $1.key }
                Console.line("  admitted by tier: \(tiers.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
            }
        }
    }
}
