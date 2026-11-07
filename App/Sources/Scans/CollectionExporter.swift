import Foundation
import RiftboundRecognizer

/// Turns a batch's confirmed scans into files other programs import: a CSV
/// card list for spreadsheets and collection trackers, and a plain decklist
/// (`2 Vi, Piltover Enforcer (OGN-001/298)`) for deck builders. Only scans
/// with a named card count; pending and rejected ones are reported, not listed.
nonisolated enum CollectionExporter {
    enum Format: Hashable, Sendable, CaseIterable {
        case csv
        case decklist

        var fileExtension: String {
            switch self {
            case .csv: "csv"
            case .decklist: "txt"
            }
        }

        var label: String {
            switch self {
            case .csv: String(localized: "Card list (CSV)")
            case .decklist: String(localized: "Decklist (text)")
            }
        }
    }

    /// One line of the export: a printing and how many scans named it.
    struct Line: Hashable, Sendable {
        let card: Card
        let quantity: Int
    }

    struct Export: Hashable, Sendable {
        let lines: [Line]
        /// Scans with no verdict yet; left out of the list.
        let pending: Int
        /// Scans the user rejected; left out of the list.
        let rejected: Int
        /// Confirmed scans whose card the directory no longer knows; left out.
        let unresolved: Int

        var totalCards: Int { lines.reduce(0) { $0 + $1.quantity } }
    }

    /// Counts confirmed cards, in directory order, resolving corrections
    /// through `directory`.
    static func export(_ records: [ScanRecord], directory: CardDirectory) -> Export {
        var quantities: [Card.ID: Int] = [:]
        var order: [Card.ID] = []
        var pending = 0, rejected = 0, unresolved = 0
        for record in records {
            switch record.verdict {
            case .pending:
                pending += 1
            case .rejected:
                rejected += 1
            case .correct, .corrected:
                guard let id = record.confirmedCardID, directory[id] != nil else {
                    unresolved += 1
                    continue
                }
                if quantities[id] == nil { order.append(id) }
                quantities[id, default: 0] += 1
            }
        }
        let lines = order
            .compactMap { id in directory[id].map { Line(card: $0, quantity: quantities[id] ?? 0) } }
            .sorted { lhs, rhs in
                if lhs.card.code.set != rhs.card.code.set { return lhs.card.code.set < rhs.card.code.set }
                if lhs.card.code.number.digits != rhs.card.code.number.digits { return lhs.card.code.number.digits < rhs.card.code.number.digits }
                return lhs.card.code.canonical < rhs.card.code.canonical
            }
        return Export(lines: lines, pending: pending, rejected: rejected, unresolved: unresolved)
    }

    static func render(_ export: Export, as format: Format) -> String {
        switch format {
        case .csv: csv(export)
        case .decklist: decklist(export)
        }
    }

    /// RFC 4180 rows with a header; names with commas or quotes are quoted.
    static func csv(_ export: Export) -> String {
        var rows = ["Quantity,Name,Code,Set,Rarity,Type,Card ID"]
        for line in export.lines {
            rows.append([
                String(line.quantity),
                line.card.displayName,
                line.card.code.canonical,
                line.card.setName,
                line.card.rarity.label,
                line.card.kind?.label ?? "",
                line.card.id.rawValue,
            ].map(csvField).joined(separator: ","))
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    /// `quantity name (code)` per line, the shape most deck builders paste.
    static func decklist(_ export: Export) -> String {
        export.lines.map { "\($0.quantity) \($0.card.displayName) (\($0.card.code.canonical))" }.joined(separator: "\n") + (export.lines.isEmpty ? "" : "\n")
    }

    /// Writes the rendered export next to the other share files.
    @concurrent
    static func write(_ export: Export, as format: Format, named name: String) async throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "\(name).\(format.fileExtension)")
        try render(export, as: format).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func csvField(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
