import Foundation

struct UsageError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// Minimal `--name value` / `--name=value` / `--flag` parsing. Three subcommands
/// do not justify a dependency.
struct CommandLineOptions {
    private(set) var positionals: [String] = []
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ arguments: ArraySlice<String>, booleanFlags: Set<String> = []) throws(UsageError) {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            guard argument.hasPrefix("--") else {
                positionals.append(argument)
                continue
            }
            let name = String(argument.dropFirst(2))
            if let equals = name.firstIndex(of: "=") {
                values[String(name[..<equals])] = String(name[name.index(after: equals)...])
            } else if booleanFlags.contains(name) {
                flags.insert(name)
            } else if let value = iterator.next() {
                values[name] = value
            } else {
                throw UsageError("--\(name) needs a value")
            }
        }
    }

    func positional(_ index: Int, named name: String) throws(UsageError) -> String {
        guard index < positionals.count else { throw UsageError("missing <\(name)>") }
        return positionals[index]
    }

    func string(_ name: String) -> String? { values[name] }

    func string(_ name: String, default fallback: String) -> String { values[name] ?? fallback }

    func bool(_ name: String) -> Bool { flags.contains(name) }

    func int(_ name: String, default fallback: Int) throws(UsageError) -> Int {
        guard let text = values[name] else { return fallback }
        guard let value = Int(text) else { throw UsageError("--\(name) expects an integer, got '\(text)'") }
        return value
    }

    func uint64(_ name: String, default fallback: UInt64) throws(UsageError) -> UInt64 {
        guard let text = values[name] else { return fallback }
        guard let value = UInt64(text) else { throw UsageError("--\(name) expects an unsigned integer, got '\(text)'") }
        return value
    }

    func url(_ name: String, default fallback: String) -> URL {
        URL(fileURLWithPath: string(name, default: fallback))
    }
}

enum Defaults {
    static let catalogPath = "data/cards.json"
    static let imagesPath = "cache/images"
    static let indexPath = "cache/index.json"
    static let syntheticPath = "synthetic"
}
