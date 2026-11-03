import Foundation

/// Finds printed codes in OCR output, repairing the usual misreads.
///
/// ``PrintedCode/init(parsing:)`` handles well-formed text. This parser also
/// copes with digits read as letters (`OO1` for `001`), letters read as digits
/// (`0GN` for `OGN`), missing separators and the trailing language tag on
/// runes, using the catalog's known set codes and collector-number prefixes as
/// the vocabulary to repair against.
public struct PrintedCodeParser: Hashable, Sendable {
    /// Known set codes and collector-number prefixes, taken from the index.
    public struct Vocabulary: Hashable, Sendable {
        public var sets: Set<SetCode>
        public var numberPrefixes: Set<String>

        public init(sets: Set<SetCode>, numberPrefixes: Set<String>) {
            self.sets = sets
            self.numberPrefixes = numberPrefixes
        }

        /// The sets and prefixes printed as of the Vendetta release.
        public static let riftbound = Vocabulary(
            sets: Set(["OGN", "OGS", "RAD", "SFD", "UNL", "VEN"].compactMap(SetCode.init(rawValue:))),
            numberPrefixes: ["", "R", "T", "SP"]
        )
    }

    public let vocabulary: Vocabulary

    public init(vocabulary: Vocabulary = .riftbound) {
        self.vocabulary = vocabulary
    }

    /// Every code found in `text`, best first.
    public func codes(in text: String) -> [PrintedCode] {
        let normalized = text.uppercased().replacingOccurrences(of: "×", with: "*")
        if let strict = PrintedCode(parsing: normalized), isKnown(strict) {
            return [strict]
        }
        return repairedCodes(in: normalized)
    }

    private func isKnown(_ code: PrintedCode) -> Bool {
        vocabulary.sets.contains(code.set) && vocabulary.numberPrefixes.contains(code.number.prefix)
    }

    // MARK: - Repair

    private static let lettersToDigits: [Character: Character] = ["O": "0", "Q": "0", "D": "0", "I": "1", "L": "1", "S": "5", "B": "8", "Z": "2", "G": "6"]
    private static let digitsToLetters: [Character: Character] = ["0": "O", "1": "I", "5": "S", "8": "B", "2": "Z", "6": "G"]

    private func repairedCodes(in text: String) -> [PrintedCode] {
        let tokens = tokenize(text)
        var codes: [PrintedCode] = []
        for (index, token) in tokens.enumerated() {
            guard let (set, remainder) = repairSet(in: token.text) else { continue }
            var numberText = remainder
            var nextIndex = index + 1
            if numberText.isEmpty {
                guard nextIndex < tokens.count else { continue }
                numberText = tokens[nextIndex].text
                nextIndex += 1
            }
            guard let (number, variant) = repairNumber(numberText) else { continue }
            var total: Int?
            if nextIndex < tokens.count, tokens[nextIndex].followsSlash {
                total = repairDigits(tokens[nextIndex].text).flatMap { Int($0) }
            }
            codes.append(PrintedCode(set: set, number: number, variant: variant, total: total))
        }
        return codes
    }

    private struct Token {
        let text: String
        let followsSlash: Bool
    }

    private func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var sawSlash = false
        for character in text {
            if character.isLetter || character.isNumber || character == "*" {
                current.append(character)
            } else {
                if !current.isEmpty {
                    tokens.append(Token(text: current, followsSlash: sawSlash))
                    current = ""
                    sawSlash = false
                }
                if character == "/" {
                    sawSlash = true
                }
            }
        }
        if !current.isEmpty {
            tokens.append(Token(text: current, followsSlash: sawSlash))
        }
        return tokens
    }

    /// Interprets the first three characters of `token` as a set code, repairing
    /// digit-for-letter misreads. Returns the remainder for glued tokens like `OGN001`.
    private func repairSet(in token: String) -> (SetCode, String)? {
        guard token.count >= 3 else { return nil }
        let head = token.prefix(3)
        let repaired = String(head.map { Self.digitsToLetters[$0] ?? $0 })
        guard let set = SetCode(rawValue: repaired), vocabulary.sets.contains(set) else { return nil }
        return (set, String(token.dropFirst(3)))
    }

    /// Splits `token` into a collector number and variant, trying each known prefix.
    private func repairNumber(_ token: String) -> (CollectorNumber, PrintedCode.Variant)? {
        var body = Substring(token)
        var variant = PrintedCode.Variant.standard
        if body.last == "*" {
            variant = .signature
            body = body.dropLast()
        } else if body.last == "A", body.count > 1 {
            variant = .alternateArt
            body = body.dropLast()
        }
        let prefixes = vocabulary.numberPrefixes.sorted { $0.count > $1.count }
        for prefix in prefixes where body.hasPrefix(prefix) {
            let digitsPart = body.dropFirst(prefix.count)
            guard (1...3).contains(digitsPart.count), let digits = repairDigits(String(digitsPart)),
                  let number = CollectorNumber(rawValue: prefix + digits)
            else { continue }
            return (number, variant)
        }
        return nil
    }

    private func repairDigits(_ text: String) -> String? {
        var digits = ""
        for character in text {
            if character.isNumber {
                digits.append(character)
            } else if let digit = Self.lettersToDigits[character] {
                digits.append(digit)
            } else {
                return nil
            }
        }
        return digits.isEmpty ? nil : digits
    }
}
