import Foundation
import RiftboundRecognizer

@main
struct Riftscan {
    static let usage = """
    usage: riftscan <command> [options]

      identify <photo> [--index cache/index.json] [--top 3] [--json] [--verbose] [--save-rectified out.png]
      build-index [--cards data/cards.json] [--images cache/images] [--output cache/index.json] [--concurrency N]
      synth [--cards data/cards.json] [--images cache/images] [--output synthetic] [--count 100] [--seed 42]
            [--severities mild,moderate,harsh]
      evaluate <folder> [--index cache/index.json] [--group mild|moderate|harsh|samples] [--limit N] [--verbose]

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
