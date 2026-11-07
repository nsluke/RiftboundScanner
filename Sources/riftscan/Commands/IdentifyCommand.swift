import CoreGraphics
import Foundation
import RiftboundRecognizer

enum IdentifyCommand {
    static func run(_ arguments: ArraySlice<String>) async throws {
        let options = try CommandLineOptions(arguments, booleanFlags: ["json", "verbose"])
        let photoPath = try options.positional(0, named: "photo")
        let top = try options.int("top", default: 3)
        let index = try CardIndex.read(from: options.url("index", default: Defaults.indexPath))
        let hints = try hints(from: options)
        let recognizer = try await CardRecognizer.live(index: index)
        let photo = try ImageFile.load(URL(fileURLWithPath: photoPath))

        let clock = ContinuousClock()
        let start = clock.now
        let result = try await recognizer.identify(photo, hints: hints)
        let elapsed = clock.now - start

        if let path = options.string("save-rectified") {
            try ImageFile.write(result.rectifiedCard, to: URL(fileURLWithPath: path), as: .png)
        }
        let matches = Array(result.matches.prefix(top))
        if options.bool("json") {
            try printJSON(photo: photoPath, result: result, matches: matches, elapsed: elapsed, hints: hints)
        } else {
            printReport(photo: photoPath, size: photo, result: result, matches: matches, elapsed: elapsed)
            if options.bool("verbose") {
                printHypotheses(result)
            }
        }
    }

    /// `--expect-set UNL`: the set the card is expected to belong to (a sealed box).
    static func hints(from options: CommandLineOptions) throws(UsageError) -> RecognitionHints {
        guard let raw = options.string("expect-set") else { return .none }
        guard let set = SetCode(rawValue: raw.uppercased()) else {
            throw UsageError("--expect-set wants a set code such as OGN or UNL, not '\(raw)'")
        }
        return RecognitionHints(expectedSet: set)
    }

    private static func printHypotheses(_ result: RecognitionResult) {
        Console.line()
        Console.line("Hypotheses tried:")
        for (number, hypothesis) in result.hypotheses.enumerated() {
            let where_: String = switch hypothesis.location {
            case .detected(let quad, let confidence):
                "rectangle \(quad.corners.map { "(\(Int($0.x)),\(Int($0.y)))" }.joined(separator: " ")) conf \(String(format: "%.2f", confidence))"
            case .assumedWholeImage:
                "whole image"
            }
            let code = hypothesis.codeRead.map { "code \($0)" } ?? "no code"
            Console.line("  \(number + 1). \(where_): best \(hypothesis.bestCard?.rawValue ?? "-") score \(String(format: "%.3f", hypothesis.bestScore)) (desc \(String(format: "%.3f", hypothesis.descriptorScore)), \(code))")
        }
    }

    private static func printReport(photo: String, size: CGImage, result: RecognitionResult, matches: [Match], elapsed: Duration) {
        Console.line("Photo: \(photo) (\(size.width)×\(size.height)), identified in \(Console.seconds(elapsed))")
        switch result.location {
        case .detected(_, let confidence):
            Console.line("Card:  rectangle detected (confidence \(String(format: "%.2f", confidence)))")
        case .assumedWholeImage:
            Console.line("Card:  no rectangle found; whole image assumed to be the card")
        }
        if let reading = result.codeReading {
            let source = reading.source == .edgeBand ? "edge band" : "full image"
            Console.line("Code:  \(reading.code) read from \"\(reading.text)\" (confidence \(String(format: "%.2f", reading.confidence)), \(reading.orientation.rawValue), \(reading.layout.rawValue) layout, \(source), \(reading.origin.rawValue))")
            let alternatives = reading.alternatives.dropFirst()
            if !alternatives.isEmpty {
                Console.line("       could also be \(alternatives.map(\.canonical).joined(separator: ", "))")
            }
        } else {
            Console.line("Code:  none read")
        }
        Console.line("Query: \(result.descriptor.orientation.rawValue) descriptor, feature print \(result.descriptor.descriptor.featurePrint.digest.hex)")
        Console.line("Engine: \(result.engine.packageVersion) on \(result.engine.platform) \(result.engine.osVersion), calibration \(result.engine.calibrationHash.hex)")
        Console.line()
        Console.line(" #  \(Console.pad("Code", 14))\(Console.pad("Name", 30))Score  Desc   FP    dH    pH    Art   OCR")
        for (rank, match) in matches.enumerated() {
            let components = match.components
            let columns = [
                String(format: "%2d", rank + 1),
                Console.pad(match.card.code.canonical, 14),
                Console.pad(String(match.card.displayName.prefix(29)), 30),
                String(format: "%.3f", match.score),
                String(format: "%.3f", match.descriptorScore),
                String(format: "%.2f", components.featurePrint),
                String(format: "%.2f", components.wholeDifferenceHash),
                String(format: "%.2f", components.wholePerceptualHash),
                String(format: "%.2f", components.artDifferenceHash),
                match.codeAgreement.map { $0.rawValue + (match.codeOrigin == .alternative ? "*" : "") } ?? "-",
            ]
            Console.line(columns.joined(separator: "  ").replacingOccurrences(of: "   ", with: "  "))
        }
        if matches.contains(where: { $0.codeOrigin == .alternative }) {
            Console.line("    * matched a digit alternative of the reading, not the reading itself")
        }
        if let best = matches.first {
            Console.line()
            Console.line("Best: \(best.card.displayName) — \(best.card.code) (\(best.card.setName), \(best.card.rarity.label), \(best.orientation.rawValue))")
        }
    }

    private struct Report: Encodable {
        struct MatchReport: Encodable {
            let id: String
            let code: String
            let name: String
            let set: String
            let score: Double
            let descriptorScore: Double
            let orientation: String
            let codeAgreement: String?
            /// `literal` or `alternative` when a code agreed; absent otherwise.
            let codeOrigin: String?
            let featurePrint: Double
            let wholeDifferenceHash: Double
            let wholePerceptualHash: Double
            let artDifferenceHash: Double
        }

        struct Point: Encodable {
            let x: Double
            let y: Double
        }

        struct DescriptorReport: Encodable {
            let orientation: String
            let featurePrintDigest: String
            let featurePrintDimension: Int
        }

        let photo: String
        let seconds: Double
        let cardDetected: Bool
        /// The card's corners (Core Image coordinates, origin bottom-left) when detected.
        let quad: [Point]?
        let codeRead: String?
        let codeConfidence: Double?
        let codeSource: String?
        /// Whether `codeRead` is the literal reading or a digit alternative.
        let codeOrigin: String?
        /// Every index-known code the text could name, best first (`codeRead` first).
        let codeAlternatives: [String]?
        let expectedSet: String?
        let descriptor: DescriptorReport
        let engine: EngineFingerprint
        let matches: [MatchReport]
    }

    private static func printJSON(photo: String, result: RecognitionResult, matches: [Match], elapsed: Duration, hints: RecognitionHints) throws {
        let report = Report(
            photo: photo,
            seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
            cardDetected: {
                if case .detected = result.location { return true }
                return false
            }(),
            quad: result.quad.map { quad in quad.corners.map { Report.Point(x: $0.x, y: $0.y) } },
            codeRead: result.codeReading?.code.canonical,
            codeConfidence: result.codeReading?.confidence,
            codeSource: result.codeReading?.source.rawValue,
            codeOrigin: result.codeReading?.origin.rawValue,
            codeAlternatives: result.codeReading?.alternatives.map(\.canonical),
            expectedSet: hints.expectedSet?.rawValue,
            descriptor: Report.DescriptorReport(
                orientation: result.descriptor.orientation.rawValue,
                featurePrintDigest: result.descriptor.descriptor.featurePrint.digest.hex,
                featurePrintDimension: result.descriptor.descriptor.featurePrint.elements.count
            ),
            engine: result.engine,
            matches: matches.map { match in
                Report.MatchReport(
                    id: match.card.id.rawValue,
                    code: match.card.code.canonical,
                    name: match.card.displayName,
                    set: match.card.setName,
                    score: match.score,
                    descriptorScore: match.descriptorScore,
                    orientation: match.orientation.rawValue,
                    codeAgreement: match.codeAgreement?.rawValue,
                    codeOrigin: match.codeOrigin?.rawValue,
                    featurePrint: match.components.featurePrint,
                    wholeDifferenceHash: match.components.wholeDifferenceHash,
                    wholePerceptualHash: match.components.wholePerceptualHash,
                    artDifferenceHash: match.components.artDifferenceHash
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        Console.line(String(decoding: try encoder.encode(report), as: UTF8.self))
    }
}
