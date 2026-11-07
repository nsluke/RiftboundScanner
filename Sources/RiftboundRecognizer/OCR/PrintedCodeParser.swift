import Foundation

/// Whether a code was read as printed or guessed from a likely digit misread.
public enum CodeOrigin: String, Hashable, Sendable, Codable {
    /// What the text says once letter/digit shape confusions (`0GN`, `OO1`)
    /// are resolved: the same characters, read as the characters they are.
    case literal
    /// A different digit from the one read, substituted for a known OCR
    /// confusion (`1` ↔ `2`, `7` ↔ `1`): a guess, never direct evidence.
    case alternative
}

/// What one stretch of OCR text could name: the index-known codes, best
/// first, and whether the best is what the text literally says.
public struct CodeInterpretation: Hashable, Sendable {
    /// Every index-known code the text could name, best first: the literal
    /// reading when the index knows it, then the ranked digit alternatives.
    /// Never empty.
    public let alternatives: [PrintedCode]
    /// Whether ``code`` is the literal reading or a digit alternative (the
    /// literal reading named nothing in the index).
    public let origin: CodeOrigin

    /// The best code: `alternatives.first`.
    public var code: PrintedCode { alternatives[0] }

    init(alternatives: [PrintedCode], origin: CodeOrigin) {
        precondition(!alternatives.isEmpty, "an interpretation names at least one code")
        self.alternatives = alternatives
        self.origin = origin
    }
}

/// Finds printed codes in OCR output, repairing the usual misreads.
///
/// ``PrintedCode/init(parsing:)`` handles well-formed text. This parser also
/// copes with digits read as letters (`OO1` for `001`), letters read as digits
/// (`0GN` for `OGN`), missing separators and the trailing language tag on
/// runes, using the index's codes as the vocabulary to repair against. A code
/// counts only when the index holds a printing with it and its denominator is
/// one its set prints; the parser also offers the index-known codes one digit
/// confusion away, which the recogniser weighs separately from the literal
/// reading.
public struct PrintedCodeParser: Hashable, Sendable {
    /// The codes an index (or catalog) knows, in the forms the parser checks.
    public struct Vocabulary: Hashable, Sendable {
        /// Every printing's code with the denominator stripped: what a reading
        /// must name to be known.
        public let keys: Set<PrintedCode>
        /// The denominators each set prints (`OGN: {298}`, `RAD: {167, 5}`).
        /// A reading whose denominator is not among its set's is a misread,
        /// since the denominator is constant per set and distinct across sets.
        public let totals: [SetCode: Set<Int>]
        /// Every set code in ``keys``, for repairing digit-for-letter misreads.
        public let sets: Set<SetCode>
        /// Every collector-number prefix in ``keys`` (`""`, `R`, `T`, `SP`).
        public let numberPrefixes: Set<String>

        public init(codes: some Sequence<PrintedCode>) {
            var keys: Set<PrintedCode> = []
            var totals: [SetCode: Set<Int>] = [:]
            var sets: Set<SetCode> = []
            var prefixes: Set<String> = []
            for code in codes {
                keys.insert(code.withoutTotal)
                if let total = code.total {
                    totals[code.set, default: []].insert(total)
                }
                sets.insert(code.set)
                prefixes.insert(code.number.prefix)
            }
            self.keys = keys
            self.totals = totals
            self.sets = sets
            self.numberPrefixes = prefixes
        }

        /// Whether the index holds a printing with this code and the
        /// denominator, when read, does not contradict the set: it is one the
        /// set prints, or one no set prints at all (`068/266` for `068/166` is
        /// a misread denominator, not a different set, and the key still
        /// stands). A denominator that belongs to another set (`VEN • 040/221`
        /// with Spiritforged's `/221`) rejects the reading: either the letters
        /// or the digits are wrong, and the parser cannot tell which. A reading
        /// without a denominator (runes and tokens print none; OCR may miss
        /// it) passes on the key alone.
        public func isKnown(_ code: PrintedCode) -> Bool {
            guard keys.contains(code.withoutTotal) else { return false }
            guard let total = code.total else { return true }
            if totals[code.set, default: []].contains(total) { return true }
            return !totals.values.contains { $0.contains(total) }
        }

        /// Knows nothing; every reading is rejected.
        public static let empty = Vocabulary(codes: [])
    }

    public let vocabulary: Vocabulary

    public init(vocabulary: Vocabulary) {
        self.vocabulary = vocabulary
    }

    /// Every code found in `text`, best first: the best code of each
    /// ``interpretations(in:hints:)`` entry.
    public func codes(in text: String, hints: RecognitionHints = .none) -> [PrintedCode] {
        interpretations(in: text, hints: hints).map(\.code)
    }

    /// Every code found in `text`, best first, each with the index-known
    /// alternatives a digit misread could hide. A well-formed, index-known code
    /// is taken as read; otherwise the text is tokenised and repaired.
    ///
    /// With `hints.expectedSet`, every repair (a letter/digit shape repair, or
    /// a digit alternative) must land in the expected set; a well-formed,
    /// index-known reading of another set is still returned, because the card
    /// plainly says so.
    public func interpretations(in text: String, hints: RecognitionHints = .none) -> [CodeInterpretation] {
        let normalized = text.uppercased().replacingOccurrences(of: "×", with: "*")
        if let strict = PrintedCode(parsing: normalized), let interpretation = interpret(strict, repaired: false, hints: hints) {
            return [interpretation]
        }
        return repairedCodes(in: normalized).compactMap { interpret($0, repaired: true, hints: hints) }
    }

    /// Ranks the literal reading (when known) ahead of its digit alternatives,
    /// applying the set hint to everything that is a guess.
    private func interpret(_ literal: PrintedCode, repaired: Bool, hints: RecognitionHints) -> CodeInterpretation? {
        var ranked: [PrintedCode] = []
        if vocabulary.isKnown(literal) {
            ranked.append(literal)
        }
        ranked += alternatives(to: literal)
        if let expected = hints.expectedSet {
            ranked.removeAll { candidate in
                candidate.set != expected && (repaired || candidate != literal)
            }
        }
        guard !ranked.isEmpty else { return nil }
        return CodeInterpretation(alternatives: ranked, origin: ranked[0] == literal ? .literal : .alternative)
    }

    // MARK: - Digit alternatives

    /// The digit pairs OCR confuses on the printed code, measured on real
    /// scans: `024` read for `014`. Ordered, so alternatives rank deterministically.
    private static let digitAlternatives: [Character: [Character]] = ["1": ["2", "7"], "2": ["1"], "7": ["1"]]

    /// Index-known codes one digit substitution away from `literal`, same set,
    /// variant and denominator, ranked by the position of the substituted digit
    /// (leftmost first) and then by the table's order. The literal itself is
    /// never included.
    private func alternatives(to literal: PrintedCode) -> [PrintedCode] {
        let characters = Array(literal.number.rawValue)
        var found: [PrintedCode] = []
        for (position, character) in characters.enumerated() {
            for replacement in Self.digitAlternatives[character] ?? [] {
                var repaired = characters
                repaired[position] = replacement
                guard let number = CollectorNumber(rawValue: String(repaired)) else { continue }
                let candidate = PrintedCode(set: literal.set, number: number, variant: literal.variant, total: literal.total)
                if candidate != literal, vocabulary.isKnown(candidate), !found.contains(candidate) {
                    found.append(candidate)
                }
            }
        }
        return found
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
