import Foundation
import RiftboundRecognizer

/// Tallies evaluation dumps written by `evaluate --dump`, and compares each
/// against a baseline dump on the cases they share (a fold's dump covers one
/// held-out batch; the baseline covers everything).
enum ReportCommand {
    static func run(_ arguments: ArraySlice<String>) throws {
        let options = try CommandLineOptions(arguments, booleanFlags: ["verbose"])
        guard !options.positionals.isEmpty else { throw UsageError("report needs at least one dump file") }
        let baseline = try options.string("baseline").map { try EvaluationDump.read(from: URL(fileURLWithPath: $0)) }
        for (offset, path) in options.positionals.enumerated() {
            let dump = try EvaluationDump.read(from: URL(fileURLWithPath: path))
            if offset > 0 { Console.line() }
            Console.line("== \(dump.label)  \(path)")
            Console.line("   \(dump.cases.count) cases, engine \(dump.engine.packageVersion) \(dump.engine.platform) \(dump.engine.osVersion) calibration \(dump.engine.calibrationHash.hex), index \(dump.indexEntryCount) printings, overlay v\(dump.overlayVersion) with \(dump.overlayExemplars) exemplars\(dump.excludedBatches.isEmpty ? "" : " excluding \(dump.excludedBatches.map { String($0.uuidString.prefix(8)) }.joined(separator: ","))"), policy v\(dump.policyVersion)")
            Report.print(dump.tally())
            if let baseline {
                Self.compare(dump, against: baseline, verbose: options.bool("verbose"))
            }
            if options.bool("verbose") {
                for result in dump.cases where !result.isCorrect {
                    Console.line("  MISS \(result.evaluationCase.file) expected \(result.evaluationCase.expected) rank \(result.rank.map { String($0 + 1) } ?? "-") → \(result.ranked.prefix(3).map { "\($0.id)(\(String(format: "%.2f", $0.score)))" }.joined(separator: " "))")
                }
            }
        }
    }

    /// Both dumps restricted to the files they share, side by side.
    static func compare(_ dump: EvaluationDump, against baseline: EvaluationDump, verbose: Bool) {
        let (sharedBaseline, sharedDump) = EvaluationDump.shared(baseline, dump)
        let shared = sharedBaseline.cases
        guard !shared.isEmpty else {
            Console.line("   (no cases in common with the baseline)")
            return
        }
        if sharedDump.cases.count != dump.cases.count {
            Console.line("   (\(dump.cases.count - sharedDump.cases.count) of this dump's cases are not in the baseline and are left out of the comparison)")
        }
        let before = sharedBaseline.tally().overall
        let after = sharedDump.tally().overall
        func delta(_ a: Double, _ b: Double) -> String {
            let d = (b - a) * 100
            return String(format: "%+.1f pt", d)
        }
        Console.line("   vs \(baseline.label) on \(shared.count) shared cases:")
        Console.line("     top-1        \(Console.percent(before.top1Rate)) → \(Console.percent(after.top1Rate))  (\(delta(before.top1Rate, after.top1Rate)))   weighted \(Console.percent(before.weightedTop1Rate)) → \(Console.percent(after.weightedTop1Rate))  (\(delta(before.weightedTop1Rate, after.weightedTop1Rate)))")
        Console.line("     top-3        \(Console.percent(before.top3Rate)) → \(Console.percent(after.top3Rate))  (\(delta(before.top3Rate, after.top3Rate)))")
        Console.line("     conf. prec.  \(Console.percent(before.confidentPrecision)) → \(Console.percent(after.confidentPrecision))  (\(before.confidentCorrect)/\(before.confident) → \(after.confidentCorrect)/\(after.confident))   coverage \(Console.percent(before.confidentCoverage)) → \(Console.percent(after.confidentCoverage))")
        Console.line("     exemplar hit \(Console.percent(after.exemplarHitRate))")
        let notLower = after.top1Rate >= before.top1Rate && after.confidentPrecision >= before.confidentPrecision
        Console.line("     shipping rule (top-1 and confident precision not lower than baseline): \(notLower ? "holds" : "FAILS")")
        if verbose {
            let baselineByFile = Dictionary(shared.map { ($0.evaluationCase.file, $0) }, uniquingKeysWith: { first, _ in first })
            for result in sharedDump.cases {
                guard let base = baselineByFile[result.evaluationCase.file], base.isCorrect != result.isCorrect else { continue }
                Console.line("     \(result.isCorrect ? "FIXED " : "BROKE ") \(result.evaluationCase.file) expected \(result.evaluationCase.expected): \(base.ranked.first?.id.rawValue ?? "-") → \(result.ranked.first?.id.rawValue ?? "-")")
            }
        }
    }
}
