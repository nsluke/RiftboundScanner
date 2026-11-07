import Foundation
import RiftboundRecognizer

enum EvaluateCommand {
    static func run(_ arguments: ArraySlice<String>) async throws {
        let options = try CommandLineOptions(arguments, booleanFlags: ["verbose"])
        let path = try options.positional(0, named: "folder")
        let limit = try options.int("limit", default: Int.max)
        let verbose = options.bool("verbose")
        let index = try CardIndex.read(from: options.url("index", default: Defaults.indexPath))
        let hints = try IdentifyCommand.hints(from: options)
        let policy = try options.string("policy").map { try LearningPolicy.read(from: URL(fileURLWithPath: $0)) } ?? .default
        let devicePrint = try await VisionFeaturePrintGenerator().calibrationPrint()
        var overlay = try Overlays.load(path: options.string("overlay"), policy: policy, devicePrint: devicePrint)
        let excludedBatches = try Overlays.batchIDs(options.string("exclude-batch"), option: "exclude-batch")
        if !excludedBatches.isEmpty {
            overlay = overlay.excluding(batches: Set(excludedBatches))
        }
        let recognizer = try await CardRecognizer.live(index: index, policy: policy.scoring, overlay: overlay)

        let set = try EvaluationSet(path: path, index: index)
        var cases = set.cases
        if let group = options.string("group") {
            cases = cases.filter { $0.group == group }
        }
        let onlyBatches = try Overlays.batchIDs(options.string("batch"), option: "batch")
        if !onlyBatches.isEmpty {
            cases = cases.filter { $0.batchID.map(onlyBatches.contains) ?? false }
        }
        guard !cases.isEmpty else {
            Console.line("No labelled photos found in \(path). Synthetic sets need \(EvaluationManifest.fileName); real photos are named by code, e.g. OGN-001-298.jpg; import-scans writes a manifest for pulled batches.")
            return
        }
        if !overlay.isEmpty {
            Console.line("Overlay: \(overlay.exemplars.count) exemplars in \(overlay.exemplarsByGroup.count) groups, version \(overlay.version)\(excludedBatches.isEmpty ? "" : ", excluding \(excludedBatches.count) batch(es)")")
        }

        var tally = EvaluationTally()
        var results: [EvaluationDump.CaseResult] = []
        let clock = ContinuousClock()
        for (number, evaluationCase) in cases.prefix(limit).enumerated() {
            // Imported scans load at the importer's size (a guide crop keeps its
            // full resolution); synthetic and sample photos at the recogniser's default.
            let photo = try ImageFile.load(set.url(for: evaluationCase), maxPixelSize: evaluationCase.scanID == nil ? 2048 : ScanImport.photoMaxPixelSize)
            let start = clock.now
            let result = try await recognizer.identify(photo, hints: hints)
            let duration = clock.now - start
            let verdict = policy.confidence.verdict(for: result.matches, codeReading: result.codeReading)
            let caseResult = EvaluationDump.CaseResult(
                evaluationCase: evaluationCase,
                ranked: result.matches.map(EvaluationDump.RankedEntry.init),
                codeRead: result.codeReading?.code,
                codeSource: result.codeReading?.source,
                codeConfidence: result.codeReading?.confidence,
                placement: result.quad == nil ? .wholeImage : .detected,
                verdict: verdict,
                seconds: Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            )
            results.append(caseResult)
            tally.record(evaluationCase, ranked: caseResult.ranked.map(\.id), duration: duration, confident: verdict.isConfident, exemplarHit: caseResult.exemplarHit)
            let rank = caseResult.rank
            if verbose || rank != 0 {
                let got = result.matches.prefix(3).map { "\($0.card.code)(\(String(format: "%.2f", $0.score))\($0.exemplarSimilarity.map { String(format: " ex %.2f", $0) } ?? ""))" }.joined(separator: " ")
                let code = result.codeReading.map { "code \($0.code)\($0.origin == .alternative ? " (alternative)" : "")" } ?? "no code"
                let confident = verdict.isConfident ? " CONFIDENT" : ""
                Console.line("[\(number + 1)/\(min(limit, cases.count))] \(rank == 0 ? "ok  " : "MISS")\(confident) \(evaluationCase.file) expected \(evaluationCase.expected) rank \(rank.map { String($0 + 1) } ?? "-") \(code) → \(got)")
            }
        }

        Console.line()
        Report.print(tally)
        if let dumpPath = options.string("dump") {
            let dumpURL = URL(fileURLWithPath: dumpPath)
            try FileManager.default.createDirectory(at: dumpURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let dump = EvaluationDump(
                generatedAt: Date(),
                label: options.string("label", default: overlay.isEmpty ? "baseline" : "overlay"),
                engine: recognizer.fingerprint,
                indexEntryCount: index.entries.count,
                overlayVersion: overlay.version,
                overlayExemplars: overlay.exemplars.count,
                excludedBatches: excludedBatches,
                policyVersion: policy.version,
                cases: results
            )
            try dump.write(to: dumpURL)
            Console.line("Dump → \(dumpURL.path)")
        }
    }
}

/// The tables `evaluate` and `report` share.
enum Report {
    static func print(_ tally: EvaluationTally) {
        Console.line("\(Console.pad("Group", 14))\(Console.pad("Cases", 7))\(Console.pad("Weight", 8))\(Console.pad("Top-1", 8))\(Console.pad("Top-3", 8))\(Console.pad("W.Top-1", 9))\(Console.pad("W.Top-3", 9))\(Console.pad("Conf", 6))\(Console.pad("Prec", 8))\(Console.pad("Cover", 8))\(Console.pad("ExHit", 7))Mean time")
        for name in tally.groupNames {
            guard let stats = tally.groups[name] else { continue }
            Console.line(row(name, stats))
        }
        Console.line(row("overall", tally.overall))
        let overall = tally.overall
        if overall.confident > 0 {
            Console.line("Confident tier: \(overall.confidentCorrect)/\(overall.confident) right (precision \(Console.percent(overall.confidentPrecision)), 95 % lower bound \(Console.percent(overall.confidentPrecisionLowerBound)); weighted precision \(Console.percent(overall.weightedConfidentPrecision)), coverage \(Console.percent(overall.confidentCoverage)) raw / \(Console.percent(overall.weightedConfidentCoverage)) weighted)")
        }
        let confidentFailures = tally.failures.filter(\.confident)
        if !confidentFailures.isEmpty {
            Console.line("Confident but wrong:")
            for failure in confidentFailures {
                Console.line("  \(failure.file) expected \(failure.expected) got \(failure.ranked.map(\.rawValue).joined(separator: " > "))")
            }
        }
    }

    private static func row(_ name: String, _ stats: EvaluationTally.GroupStatistics) -> String {
        "\(Console.pad(String(name.prefix(13)), 14))\(Console.pad(String(stats.total), 7))\(Console.pad(String(format: "%.1f", stats.weight), 8))\(Console.pad(Console.percent(stats.top1Rate), 8))\(Console.pad(Console.percent(stats.top3Rate), 8))\(Console.pad(Console.percent(stats.weightedTop1Rate), 9))\(Console.pad(Console.percent(stats.weightedTop3Rate), 9))\(Console.pad(String(stats.confident), 6))\(Console.pad(Console.percent(stats.confidentPrecision), 8))\(Console.pad(Console.percent(stats.confidentCoverage), 8))\(Console.pad(Console.percent(stats.exemplarHitRate), 7))\(Console.seconds(stats.meanDuration))"
    }
}
