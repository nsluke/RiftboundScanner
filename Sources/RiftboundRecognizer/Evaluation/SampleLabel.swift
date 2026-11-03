import Foundation

/// Resolves the expected card for a real photo from its file name, so that
/// `samples/OGN-001-298.jpg` or `samples/ogn-007a-298 kitchen.heic` can be scored.
public enum SampleLabel {
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp"]

    /// The card named by `fileName`: its stem's first word is matched against
    /// catalog ids (case-insensitively), then parsed as a printed code with the
    /// last hyphen standing in for the slash (`OGN-001-298` → `OGN-001/298`).
    public static func cardID(forFileName fileName: String, in index: CardIndex) -> Card.ID? {
        let stem = (fileName as NSString).deletingPathExtension
        guard let token = stem.split(whereSeparator: { $0.isWhitespace || $0 == "_" || $0 == "(" }).first else { return nil }
        let lowered = token.lowercased()
        if let entry = index.entries.first(where: { $0.id.rawValue == lowered }) {
            return entry.id
        }
        var candidate = String(token)
        if !candidate.contains("/"), let lastHyphen = candidate.lastIndex(of: "-"), candidate.filter({ $0 == "-" }).count >= 2 {
            candidate.replaceSubrange(lastHyphen...lastHyphen, with: "/")
        }
        guard let code = PrintedCode(parsing: candidate) else { return nil }
        return index.entries.first { $0.card.code == code }?.id
    }

    /// Labelled cases for every image in `folder` whose name resolves to a card.
    public static func cases(in folder: URL, index: CardIndex, group: String = "samples") throws -> [EvaluationCase] {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        return names.compactMap { name in
            guard imageExtensions.contains((name as NSString).pathExtension.lowercased()),
                  let id = cardID(forFileName: name, in: index)
            else { return nil }
            return EvaluationCase(file: name, expected: id, group: group)
        }
    }
}
