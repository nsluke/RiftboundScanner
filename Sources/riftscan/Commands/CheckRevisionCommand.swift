import Foundation
import RiftboundRecognizer

/// Prints what this machine's Vision model makes of the calibration canvas, so
/// two machines (or one machine across an OS update) can be compared: the
/// engine fingerprint, the print's dimension, its 16-byte hash, and the vector
/// itself. With `--index`, also compares against the print stored in an index.
enum CheckRevisionCommand {
    static func run(_ arguments: ArraySlice<String>) async throws {
        let options = try CommandLineOptions(arguments, booleanFlags: ["json", "no-vector"])
        let generator = VisionFeaturePrintGenerator()
        let print = try await generator.calibrationPrint()
        let fingerprint = EngineFingerprint.current(calibrationHash: print.digest)

        var comparison: Comparison?
        if let indexPath = options.string("index") {
            let index = try CardIndex.read(from: URL(fileURLWithPath: indexPath))
            comparison = Comparison(indexPath: indexPath, index: index, devicePrint: print)
        }

        if options.bool("json") {
            let report = Report(
                engine: fingerprint,
                dimension: print.elements.count,
                calibrationHash: print.digest.hex,
                calibrationPrint: options.bool("no-vector") ? nil : print.elements,
                index: comparison
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            Console.line(String(decoding: try encoder.encode(report), as: UTF8.self))
            return
        }

        Console.line("Recogniser \(fingerprint.packageVersion) on \(fingerprint.platform) \(fingerprint.osVersion)")
        Console.line("Calibration print: \(print.elements.count) elements, hash \(print.digest.hex)")
        if let comparison {
            if let similarity = comparison.similarity, let hash = comparison.indexCalibrationHash {
                Console.line("Index \(comparison.indexPath): hash \(hash), dimension \(comparison.indexDimension ?? 0), cosine to this machine \(String(format: "%.6f", similarity))\(comparison.hashMatches ? " (identical)" : "")")
            } else {
                Console.line("Index \(comparison.indexPath): no calibration print recorded (built before it existed; rebuild with build-index)")
            }
        }
        if !options.bool("no-vector") {
            Console.line()
            Console.line("Vector:")
            for row in stride(from: 0, to: print.elements.count, by: 8) {
                let values = print.elements[row..<min(row + 8, print.elements.count)].map { String(format: "% .6f", $0) }
                Console.line("  \(values.joined(separator: " "))")
            }
        }
    }

    private struct Comparison: Encodable {
        let indexPath: String
        let indexCalibrationHash: String?
        let indexDimension: Int?
        /// Cosine similarity between the index's calibration print and this machine's.
        let similarity: Double?
        let hashMatches: Bool

        init(indexPath: String, index: CardIndex, devicePrint: FeaturePrint) {
            self.indexPath = indexPath
            indexCalibrationHash = index.calibrationHash?.hex
            indexDimension = index.calibrationPrint?.elements.count
            similarity = index.calibrationPrint.map { devicePrint.similarity(to: $0) }
            hashMatches = index.calibrationHash == devicePrint.digest
        }
    }

    private struct Report: Encodable {
        let engine: EngineFingerprint
        let dimension: Int
        let calibrationHash: String
        let calibrationPrint: [Float]?
        let index: Comparison?
    }
}
