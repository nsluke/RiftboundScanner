import Foundation
import RiftboundRecognizer

/// What the fix panel's one field holds: a printed code with its set
/// (`rad 40`, `RAD-040`, `ogn001`), a bare collector number (`112`, `r1`),
/// or part of a name (`kato`). The code is printed too small to read from a
/// 1080p photo but the name banner is not, so names are first-class.
nonisolated enum FixQuery: Hashable, Sendable {
    case empty
    case code(SetCode, CollectorNumber)
    case number(CollectorNumber)
    case name(String)

    /// Reads `text` against the sets the directory knows. A leading two to
    /// four letters count as a set only when the directory has that set, so
    /// `sp1` stays a number and `vi` stays a name. A variant suffix (`a`, `*`)
    /// and a printed total (`/298`) are ignored: every printing that shares
    /// the number is offered.
    init(_ text: String, sets: [SetCode]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self = .empty
            return
        }
        let code = Self.withoutTotalAndVariant(trimmed.uppercased())
        if let number = CollectorNumber(rawValue: code) {
            self = .number(number)
            return
        }
        let known = Set(sets)
        for length in (2...4).reversed() where code.count > length {
            let letters = String(code.prefix(length))
            let rest = String(code.dropFirst(length)).trimmingCharacters(in: Self.separators)
            if let set = SetCode(rawValue: letters), known.contains(set), let number = CollectorNumber(rawValue: rest) {
                self = .code(set, number)
                return
            }
        }
        self = .name(trimmed)
    }

    private static let separators = CharacterSet(charactersIn: " -•·")

    /// `OGN-001/298` → `OGN-001`, `007A` → `007`, `299*` → `299`.
    private static func withoutTotalAndVariant(_ text: String) -> String {
        var code = text
        if let slash = code.firstIndex(of: "/") {
            code = String(code[..<slash])
        }
        if code.last == "*" || (code.last == "A" && code.dropLast().last?.isNumber == true) {
            code.removeLast()
        }
        return code.trimmingCharacters(in: separators)
    }
}

nonisolated extension CardDirectory {
    /// The printings `query` names, best first. A bare number lists that
    /// number in `preferredSet` first, then in every other set, so the set
    /// never has to be picked by hand. Names rank cards whose name starts
    /// with the text (or has a word that does) ahead of the rest.
    func cards(for query: FixQuery, preferredSet: SetCode?, limit: Int = 12) -> [Card] {
        switch query {
        case .empty:
            return []
        case .code(let set, let number):
            return cards(in: set, number: number.rawValue)
        case .number(let number):
            let order = (preferredSet.map { [$0] } ?? []) + sets.filter { $0 != preferredSet }
            return Array(order.flatMap { cards(in: $0, number: number.rawValue) }.prefix(limit))
        case .name(let text):
            let found = matching(text)
            let leading = found.filter { $0.displayName.hasWordPrefix(text) }
            let leadingIDs = Set(leading.map(\.id))
            return Array((leading + found.filter { !leadingIDs.contains($0.id) }).prefix(limit))
        }
    }
}

private extension String {
    /// Whether the name, or any word in it, starts with `prefix`, ignoring case.
    nonisolated func hasWordPrefix(_ prefix: String) -> Bool {
        split(whereSeparator: { $0 == " " || $0 == "," || $0 == "-" })
            .contains { $0.lowercased().hasPrefix(prefix.lowercased()) }
    }
}
