import Foundation
import RiftboundRecognizer

@main
struct Riftscan {
    static let usage = """
    usage: riftscan <command> [options]

      identify <photo> [--index cache/index.json] [--overlay overlay.json|.bin] [--policy policy.json] [--top 3]
               [--expect-set UNL] [--json] [--verbose] [--save-rectified out.png]
      build-index [--cards data/cards.json] [--images cache/images] [--output cache/index.json] [--concurrency N]
      synth [--cards data/cards.json] [--images cache/images] [--output synthetic] [--count 100] [--seed 42]
            [--severities mild,moderate,harsh]
      evaluate <folder|manifest.json> [--index cache/index.json] [--overlay overlay.json] [--policy policy.json]
               [--exclude-batch UUID[,UUID]] [--batch UUID[,UUID]] [--group NAME] [--expect-set UNL] [--limit N]
               [--dump out.json] [--label NAME] [--verbose]
      check-revision [--index cache/index.json] [--json] [--no-vector]

    Learning evaluation (docs/learning-eval.md):
      import-scans [scans] [--output evaluation/manifest.json] [--policy policy.json] [--audit-rate 0.3] [--verbose]
      build-overlay <manifest.json> [--index cache/index.json] [--policy policy.json] [--output evaluation/overlay.json]
               [--exclude-batch UUID[,UUID] | --leave-one-out] [--dump evaluation/admissions.json]
               [--accept-legacy] [--training-quality standard|legacy] [--limit N] [--verbose]
      report <dump.json>... [--baseline dump.json] [--verbose]
      admission-report <admissions.json> [--floor 0.62]
      gate-diff <admission-cases.json|admissions.json> [--server http://riftbound.lan] [--token T] [--fold NAME]
               [--limit N] [--verbose]

    Paths are relative to the current directory; run from the repository root.
    """

    static func main() async {
        let arguments = CommandLine.arguments.dropFirst()
        guard let command = arguments.first else {
            Console.line(usage)
            exit(2)
        }
        do {
            switch command {
            case "identify": try await IdentifyCommand.run(arguments.dropFirst())
            case "build-index": try await BuildIndexCommand.run(arguments.dropFirst())
            case "synth": try SynthCommand.run(arguments.dropFirst())
            case "evaluate": try await EvaluateCommand.run(arguments.dropFirst())
            case "check-revision": try await CheckRevisionCommand.run(arguments.dropFirst())
            case "import-scans": try ImportScansCommand.run(arguments.dropFirst())
            case "build-overlay": try await BuildOverlayCommand.run(arguments.dropFirst())
            case "report": try ReportCommand.run(arguments.dropFirst())
            case "admission-report": try AdmissionReportCommand.run(arguments.dropFirst())
            case "gate-diff": try await GateDiffCommand.run(arguments.dropFirst())
            case "help", "--help", "-h": Console.line(usage)
            default: throw UsageError("unknown command '\(command)'\n\n\(usage)")
            }
        } catch let error as UsageError {
            Console.error("riftscan: \(error.description)")
            exit(2)
        } catch {
            Console.error("riftscan: \(error)")
            exit(1)
        }
    }
}
