import Foundation
import RiftboundRecognizer

/// Where an evaluation's cases come from: a folder holding `manifest.json`
/// (synthetic sets, or the file `import-scans` writes), a manifest file named
/// directly, or a folder of photos named by code.
struct EvaluationSet {
    /// The folder case file paths are relative to.
    let folder: URL
    let manifest: EvaluationManifest?
    let cases: [EvaluationCase]

    init(path: String, index: CardIndex) throws {
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw UsageError("no such file or folder: \(path)")
        }
        if !isDirectory.boolValue {
            folder = url.deletingLastPathComponent()
            manifest = try EvaluationManifest.read(file: url)
            cases = manifest?.cases ?? []
        } else if FileManager.default.fileExists(atPath: url.appendingPathComponent(EvaluationManifest.fileName).path) {
            folder = url
            manifest = try EvaluationManifest.read(from: url)
            cases = manifest?.cases ?? []
        } else {
            folder = url
            manifest = nil
            cases = try SampleLabel.cases(in: url, index: index)
        }
    }

    func url(for evaluationCase: EvaluationCase) -> URL {
        folder.appendingPathComponent(evaluationCase.file)
    }

    /// The batch folder a case's photo lives in (`<batch>/photos/<id>.jpg`).
    func batchFolder(for evaluationCase: EvaluationCase) -> URL {
        url(for: evaluationCase).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Reads every batch the cases came from, keyed by id.
    func batches() throws -> [UUID: ImportedBatch] {
        var batches: [UUID: ImportedBatch] = [:]
        for evaluationCase in cases where evaluationCase.batchID != nil {
            guard let id = evaluationCase.batchID, batches[id] == nil else { continue }
            batches[id] = try ScanImport.readBatch(at: batchFolder(for: evaluationCase))
        }
        return batches
    }
}

/// Reads an overlay file as `identify` does and refuses one whose
/// calibration print this machine cannot compare against.
enum Overlays {
    static func load(path: String?, policy: LearningPolicy, devicePrint: FeaturePrint) throws -> ExemplarIndex {
        guard let path else { return .empty }
        let overlay = try IdentifyCommand.readOverlay(at: URL(fileURLWithPath: path))
        let compatibility = overlay.compatibility(with: devicePrint, minimum: policy.calibrationMinimum)
        switch compatibility {
        case .compatible:
            return overlay
        case .embeddingChanged, .dimensionMismatch, .uncalibrated:
            throw IdentifyCommand.OverlayIncompatibleError(compatibility: compatibility, minimum: policy.calibrationMinimum)
        }
    }

    /// Comma-separated UUIDs from an option, in order.
    static func batchIDs(_ text: String?, option: String) throws -> [UUID] {
        guard let text, !text.isEmpty else { return [] }
        return try text.split(separator: ",").map { part in
            guard let id = UUID(uuidString: String(part).trimmingCharacters(in: .whitespaces)) else {
                throw UsageError("--\(option) expects UUIDs, got '\(part)'")
            }
            return id
        }
    }
}
