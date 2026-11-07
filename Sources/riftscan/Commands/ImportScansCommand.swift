import Foundation
import RiftboundRecognizer

/// Turns the batches pulled from the phone into an evaluation manifest: one
/// case per human-judged scan, weighted by how it was sampled, with the photo
/// size recorded (ADR-002, section 7, evaluation protocol).
enum ImportScansCommand {
    static func run(_ arguments: ArraySlice<String>) throws {
        let options = try CommandLineOptions(arguments, booleanFlags: ["verbose"])
        let root = URL(fileURLWithPath: options.positionals.first ?? Defaults.scansPath)
        let output = options.url("output", default: Defaults.manifestPath)
        let policy = try options.string("policy").map { try LearningPolicy.read(from: URL(fileURLWithPath: $0)) } ?? .default
        let auditRate = try options.double("audit-rate", default: policy.confidence.auditRate)
        guard auditRate > 0, auditRate <= 1 else { throw UsageError("--audit-rate must be in (0, 1], got \(auditRate)") }

        let manifestFolder = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: manifestFolder, withIntermediateDirectories: true)
        let result = try ScanImport.importCases(under: root, manifestFolder: manifestFolder, auditRate: auditRate)
        try result.manifest.write(file: output)

        for batch in result.batches {
            let imported = result.cases.filter { $0.batchID == batch.id }
            let bySource = Dictionary(grouping: imported, by: { $0.decisionSource?.rawValue ?? "?" }).mapValues(\.count).sorted { $0.key < $1.key }
            let standard = imported.filter { $0.captureQuality == .standard }.count
            let derivable = imported.filter { $0.captureQuality != .standard && $0.derivedCaptureQuality == .standard }.count
            Console.line("\(Console.pad(batch.displayName, 12)) \(String(batch.id.uuidString.prefix(8)))  scans \(batch.scans.count)  cases \(imported.count)  standard captures \(standard)\(derivable > 0 ? " (+\(derivable) derivable from crop and size)" : "")  purpose \(batch.purpose)  training \(batch.trainingQuality.rawValue)  \(bySource.map { "\($0.key) \($0.value)" }.joined(separator: " "))")
            if options.bool("verbose") {
                for evaluationCase in imported {
                    let size = evaluationCase.imageSize.map { "\($0.width)×\($0.height)" } ?? "unreadable"
                    let derived = evaluationCase.derivedCaptureQuality.map { $0 == evaluationCase.captureQuality ? "" : " (derivable \($0.rawValue))" } ?? ""
                    Console.line("    \(evaluationCase.file)  \(evaluationCase.expected)  weight \(String(format: "%.3f", evaluationCase.samplingWeight))  \(evaluationCase.captureQuality?.rawValue ?? "-")\(derived)  \(size)")
                }
            }
        }
        let weighted = result.cases.reduce(0) { $0 + $1.samplingWeight }
        Console.line("Imported \(result.cases.count) cases (weighted \(String(format: "%.1f", weighted)), audit rate \(auditRate)) from \(result.batches.count) batches on \(RecognizerInfo.platform) → \(output.path)")
        let skipped = result.skipped.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue) \($0.value)" }
        if !skipped.isEmpty {
            Console.line("Skipped: \(skipped.joined(separator: ", "))")
        }
        if !result.unreadablePhotos.isEmpty {
            Console.error("Unreadable photos: \(result.unreadablePhotos.count) (first: \(result.unreadablePhotos[0]))")
        }
    }
}
