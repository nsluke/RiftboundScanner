import Foundation
import RiftboundRecognizer

/// Runs the recogniser over an imported manifest's photos, feeds every scan
/// through the Swift admission gate and writes an `ExemplarIndex` overlay per
/// fold, printing the exemplar count each fold yields. A fold that yields no
/// exemplars fails the command (exit 1) after everything has been written: an
/// evaluation against an empty overlay would measure nothing.
enum BuildOverlayCommand {
    static func run(_ arguments: ArraySlice<String>) async throws {
        let options = try CommandLineOptions(arguments, booleanFlags: ["leave-one-out", "verbose", "accept-legacy", "derive-capture-quality"])
        let manifestPath = try options.positional(0, named: "manifest")
        let index = try CardIndex.read(from: options.url("index", default: Defaults.indexPath))
        let policy = try options.string("policy").map { try LearningPolicy.read(from: URL(fileURLWithPath: $0)) } ?? .default
        let output = options.url("output", default: Defaults.overlayPath)
        let dumpURL = options.string("dump").map { URL(fileURLWithPath: $0) }
        let limit = try options.int("limit", default: Int.max)
        let excluded = try Overlays.batchIDs(options.string("exclude-batch"), option: "exclude-batch")
        var assumptions = AdmissionDump.Assumptions(acceptLegacyDecisions: options.bool("accept-legacy"), deriveCaptureQuality: options.bool("derive-capture-quality"))
        if let quality = options.string("training-quality") {
            guard let value = AdmissionInput.CaptureQuality(rawValue: quality) else {
                throw UsageError("--training-quality expects standard or legacy, got '\(quality)'")
            }
            assumptions.trainingQuality = value
        }

        let set = try EvaluationSet(path: manifestPath, index: index)
        let cases = Array(set.cases.prefix(limit))
        guard !cases.isEmpty else { throw UsageError("no cases in \(manifestPath); run import-scans first") }
        guard cases.allSatisfy({ $0.scanID != nil && $0.batchID != nil }) else {
            throw UsageError("build-overlay needs a manifest written by import-scans (cases carry scan and batch ids)")
        }
        let batches = try set.batches()
        // A scan pulled into two batch folders would be keyed twice; name it
        // rather than trap (the folder's id, not the record's own `batchID`,
        // tells copies apart).
        var scansByID: [UUID: ImportedScan] = [:]
        var folderByScan: [UUID: ImportedBatch] = [:]
        for batch in batches.values.sorted(by: { $0.startedAt < $1.startedAt }) {
            for scan in batch.scans {
                if let other = folderByScan[scan.id], other.id != batch.id {
                    throw UsageError("scan \(scan.id.uuidString) appears in two batch folders (\(other.displayName) and \(batch.displayName)); remove the duplicate and re-run import-scans")
                }
                folderByScan[scan.id] = batch
                scansByID[scan.id] = scan
            }
        }

        // Analyse every photo once, with the bare index.
        let featurePrinter = VisionFeaturePrintGenerator()
        let devicePrint = try await featurePrinter.calibrationPrint()
        let recognizer = try await CardRecognizer.live(index: index, policy: policy.scoring)
        Console.line("Analysing \(cases.count) photos with the bare index (calibration \(devicePrint.digest.hex), \(assumptions.description))")
        var analyses: [AnalysedScan] = []
        let clock = ContinuousClock()
        let start = clock.now
        for (number, evaluationCase) in cases.enumerated() {
            guard let scanID = evaluationCase.scanID, let batchID = evaluationCase.batchID,
                  let scan = scansByID[scanID], let batch = batches[batchID]
            else { throw UsageError("case \(evaluationCase.file) names a scan or batch the folder does not hold") }
            let photo = try ImageFile.load(set.url(for: evaluationCase), maxPixelSize: ScanImport.photoMaxPixelSize)
            let result = try await recognizer.identify(photo)
            let analysed = AnalysedScan(evaluationCase, scan: scan, batch: batch, result: result, index: index)
            analyses.append(analysed)
            if options.bool("verbose") || number % 20 == 19 || number == cases.count - 1 {
                let input = analysed.input
                let code = input.code.map { "\($0.source.rawValue) \($0.origin.rawValue) \($0.agreement.rawValue)" } ?? "no code"
                Console.line("  [\(number + 1)/\(cases.count)] \(evaluationCase.file)  \(input.placement.rawValue)  ref \(String(format: "%.4f", input.referenceSimilarity))  other \(String(format: "%.4f", analysed.bestOtherReferenceSimilarity))  \(code)")
            }
        }
        Console.line("Analysed in \(Console.seconds(clock.now - start))")

        // Gate per fold.
        let holdouts: [[UUID]] = options.bool("leave-one-out") ? (set.manifest?.batchIDs ?? []).map { [$0] } : [excluded]
        let gate = ExemplarAdmission(policy: policy.admission, calibrationHash: devicePrint.digest)
        var folds: [AdmissionDump.Fold] = []
        var emptyFolds: [String] = []
        Console.line()
        Console.line("\(Console.pad("Fold", 26))\(Console.pad("Inputs", 8))\(Console.pad("Exemplars", 11))\(Console.pad("Groups", 8))Outcomes")
        for holdout in holdouts {
            let inputs = analyses.filter { !holdout.contains($0.input.batchID) }.map { assumptions.apply(to: $0) }
            let batchByScan = Dictionary(inputs.map { ($0.scanID, $0.batchID) }, uniquingKeysWith: { first, _ in first })
            let run = gate.run(inputs)
            let admittedAt = Date()
            let overlay = ExemplarIndex(version: 1, calibrationPrint: devicePrint, exemplars: try run.exemplars.map { exemplar in
                guard let batchID = batchByScan[exemplar.scanID] else { throw UsageError("admitted exemplar \(exemplar.scanID) names no input scan") }
                return ExemplarIndex.Exemplar(artGroup: exemplar.artGroup, featurePrint: exemplar.featurePrint, scanID: exemplar.scanID, batchID: batchID, admittedAt: admittedAt)
            })
            let overlayURL = holdouts.count > 1 ? Self.foldURL(output, holdout: holdout) : output
            try FileManager.default.createDirectory(at: overlayURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try overlay.write(to: overlayURL)
            let byGroup = Dictionary(grouping: run.exemplars, by: \.artGroup.rawValue).mapValues(\.count)
            let fold = AdmissionDump.Fold(
                excludedBatches: holdout,
                records: run.records,
                exemplarCount: run.exemplars.count,
                exemplarsByGroup: byGroup,
                overlayFile: dumpURL.map { ScanImport.relativePath(to: overlayURL, from: $0.deletingLastPathComponent()) } ?? overlayURL.lastPathComponent
            )
            folds.append(fold)
            let outcomes = Dictionary(grouping: run.records, by: { $0.outcome.reason.map { "\($0)" } ?? $0.outcome.label }).mapValues(\.count).sorted { $0.value > $1.value }
            Console.line("\(Console.pad(fold.name, 26))\(Console.pad(String(inputs.count), 8))\(Console.pad(String(run.exemplars.count), 11))\(Console.pad(String(byGroup.count), 8))\(outcomes.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
            if options.bool("verbose") {
                for record in run.records {
                    Console.line("    \(record.scanID.uuidString.prefix(8))  \(record.artGroup?.rawValue ?? "-")  \(Self.describe(record.outcome))")
                }
            }
            if run.exemplars.isEmpty {
                emptyFolds.append(fold.name)
            }
        }
        if let dumpURL {
            try FileManager.default.createDirectory(at: dumpURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try AdmissionDump(generatedAt: Date(), engine: recognizer.fingerprint, policy: policy.admission, assumptions: assumptions, analyses: analyses, folds: folds).write(to: dumpURL)
            Console.line("Admission dump → \(dumpURL.path)")
        }
        if holdouts.count > 1 {
            Console.line("Overlays → \(output.deletingLastPathComponent().path)/\(Self.foldStem(output))-holdout-<batch>.\(output.pathExtension.isEmpty ? "json" : output.pathExtension)")
        } else {
            Console.line("Overlay → \(output.path)")
        }
        if !emptyFolds.isEmpty {
            throw EmptyFoldError(folds: emptyFolds)
        }
    }

    /// A fold that admitted nothing: evaluating against it would measure the
    /// bare index and call it an overlay result. Exit 1, like every riftscan failure.
    struct EmptyFoldError: Error, CustomStringConvertible {
        let folds: [String]

        var description: String {
            "fold\(folds.count == 1 ? "" : "s") \(folds.joined(separator: ", ")) yielded zero exemplars; the overlay\(folds.count == 1 ? " was" : "s were") written but the fold fails (nothing to evaluate against)"
        }
    }

    static func foldStem(_ output: URL) -> String {
        output.deletingPathExtension().lastPathComponent
    }

    static func foldURL(_ output: URL, holdout: [UUID]) -> URL {
        let suffix = holdout.isEmpty ? "all" : "holdout-" + holdout.map { String($0.uuidString.prefix(8)) }.joined(separator: "+")
        return output.deletingLastPathComponent().appendingPathComponent("\(foldStem(output))-\(suffix).\(output.pathExtension.isEmpty ? "json" : output.pathExtension)")
    }

    static func describe(_ outcome: AdmissionOutcome) -> String {
        switch outcome {
        case .admitted(let tier, let corroborators, let evicted):
            var text = "admitted (\(tier.rawValue))"
            if !corroborators.isEmpty { text += " with \(corroborators.map { String($0.uuidString.prefix(8)) }.joined(separator: ","))" }
            if !evicted.isEmpty { text += ", evicting \(evicted.map { String($0.uuidString.prefix(8)) }.joined(separator: ","))" }
            return text
        case .rejected(let reason):
            return "rejected: \(reason.rawValue)"
        case .needsSecondWitness:
            return "needs a second witness"
        case .blocked(let scanID, let similarity):
            return "blocked by \(scanID.uuidString.prefix(8)) at \(String(format: "%.4f", similarity))"
        case .duplicate(let scanID, let similarity):
            return "duplicate of \(scanID.uuidString.prefix(8)) at \(String(format: "%.4f", similarity))"
        }
    }
}
