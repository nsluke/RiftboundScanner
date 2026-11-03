import Foundation
import RiftboundRecognizer

enum EvaluateCommand {
    static func run(_ arguments: ArraySlice<String>) async throws {
        let options = try CommandLineOptions(arguments, booleanFlags: ["verbose"])
        let folder = URL(fileURLWithPath: try options.positional(0, named: "folder"))
        let limit = try options.int("limit", default: Int.max)
        let verbose = options.bool("verbose")
        let index = try CardIndex.read(from: options.url("index", default: Defaults.indexPath))
        let recognizer = CardRecognizer.live(index: index)

        var cases: [EvaluationCase]
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent(EvaluationManifest.fileName).path) {
            cases = try EvaluationManifest.read(from: folder).cases
        } else {
            cases = try SampleLabel.cases(in: folder, index: index)
        }
        if let group = options.string("group") {
            cases = cases.filter { $0.group == group }
        }
        guard !cases.isEmpty else {
            Console.line("No labelled photos found in \(folder.path). Synthetic sets need \(EvaluationManifest.fileName); real photos are named by code, e.g. OGN-001-298.jpg.")
            return
        }

        var tally = EvaluationTally()
        let clock = ContinuousClock()
        for (number, evaluationCase) in cases.prefix(limit).enumerated() {
            let photo = try ImageFile.load(folder.appendingPathComponent(evaluationCase.file))
            let start = clock.now
            let result = try await recognizer.identify(photo)
            let duration = clock.now - start
            let ranked = result.matches.map(\.id)
            tally.record(evaluationCase, ranked: ranked, duration: duration)
            let rank = ranked.firstIndex(of: evaluationCase.expected)
            if verbose || rank != 0 {
                let got = result.matches.prefix(3).map { "\($0.card.code)(\(String(format: "%.2f", $0.score)))" }.joined(separator: " ")
                let code = result.codeReading.map { "code \($0.code)" } ?? "no code"
                Console.line("[\(number + 1)/\(min(limit, cases.count))] \(rank == 0 ? "ok  " : "MISS") \(evaluationCase.file) expected \(evaluationCase.expected) rank \(rank.map { String($0 + 1) } ?? "-") \(code) → \(got)")
            }
        }

        Console.line()
        Console.line("\(Console.pad("Group", 12))\(Console.pad("Cases", 8))\(Console.pad("Top-1", 9))\(Console.pad("Top-3", 9))Mean time")
        for name in tally.groupNames {
            guard let stats = tally.groups[name] else { continue }
            Console.line("\(Console.pad(name, 12))\(Console.pad(String(stats.total), 8))\(Console.pad(Console.percent(stats.top1Rate), 9))\(Console.pad(Console.percent(stats.top3Rate), 9))\(Console.seconds(stats.meanDuration))")
        }
        let overall = tally.overall
        Console.line("\(Console.pad("overall", 12))\(Console.pad(String(overall.total), 8))\(Console.pad(Console.percent(overall.top1Rate), 9))\(Console.pad(Console.percent(overall.top3Rate), 9))\(Console.seconds(overall.meanDuration))")
    }
}
