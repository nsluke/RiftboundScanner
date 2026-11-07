import Foundation

/// A set identifier such as `OGN` (Origins) or `RAD` (Radiance): two to four ASCII capitals.
public struct SetCode: RawRepresentable, Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard (2...4).contains(rawValue.count),
              rawValue.allSatisfy({ $0.isASCII && $0.isUppercase })
        else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static func < (lhs: SetCode, rhs: SetCode) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The collector token of a printed code: `001`, `299`, `R01`, `T01` or `SP1`.
public struct CollectorNumber: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.wholeMatch(of: #/[A-Z]{0,2}[0-9]{1,3}/#) != nil else { return nil }
        self.rawValue = rawValue
    }

    /// Letters before the digits (`R`, `T`, `SP`); empty for ordinary collector numbers.
    public var prefix: String { String(rawValue.prefix { $0.isLetter }) }

    /// The numeric part, e.g. 7 for `007` and 1 for `SP1`.
    public var digits: Int { Int(rawValue.drop { $0.isLetter }) ?? 0 }

    public var description: String { rawValue }
}

/// The set/collector code printed in the bottom-left corner of every card.
///
/// Cards print it with a bullet (`OGN • 001/298`, `OGN • 007a/298` for alternate
/// art, `OGN • 299*/298` for signatures, `RAD • R01 • EN` for runes); the catalog
/// writes the same code with a hyphen (`OGN-001/298`). ``init(parsing:)`` accepts
/// both and ``canonical`` reproduces the catalog spelling.
public struct PrintedCode: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The suffix that distinguishes printings of the same collector number.
    public enum Variant: String, Hashable, Sendable, Codable, CaseIterable {
        case standard = ""
        case alternateArt = "a"
        case signature = "*"
    }

    public let set: SetCode
    public let number: CollectorNumber
    public let variant: Variant
    /// The denominator (`298` in `001/298`); runes and tokens print none.
    public let total: Int?

    public init(set: SetCode, number: CollectorNumber, variant: Variant = .standard, total: Int? = nil) {
        self.set = set
        self.number = number
        self.variant = variant
        self.total = total
    }

    /// Parses a catalog code (`OGN-007a/298`) or a printed one (`OGN • 007a/298`).
    /// Returns `nil` when no well-formed code appears in `text`. A code must end
    /// at a token boundary, so a misread like `2O2a` is left to the OCR parser's
    /// repair pass instead of being truncated to `2`.
    public init?(parsing text: String) {
        let pattern = #/(?<set>[A-Z]{3})[\s•·.\-*]*(?<number>[A-Z]{0,2}[0-9]{1,3})(?<variant>[A*]?)(?:\s*\/\s*(?<total>[0-9]{1,3}))?(?![A-Z0-9])/#
        guard let match = text.uppercased().firstMatch(of: pattern),
              let set = SetCode(rawValue: String(match.output.set)),
              let number = CollectorNumber(rawValue: String(match.output.number))
        else { return nil }
        let variant: Variant = switch match.output.variant {
        case "A": .alternateArt
        case "*": .signature
        default: .standard
        }
        self.init(set: set, number: number, variant: variant, total: match.output.total.flatMap { Int($0) })
    }

    /// The same code with no denominator: set, number and variant, which is
    /// what identifies a printing (the denominator is constant per set).
    public var withoutTotal: PrintedCode {
        PrintedCode(set: set, number: number, variant: variant, total: nil)
    }

    /// The catalog spelling, e.g. `OGN-007a/298` or `RAD-R01`.
    public var canonical: String {
        var text = "\(set.rawValue)-\(number.rawValue)\(variant.rawValue)"
        if let total {
            text += "/" + String(format: "%03d", total)
        }
        return text
    }

    public var description: String { canonical }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let code = PrintedCode(parsing: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a printed code: \(text)")
        }
        self = code
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(canonical)
    }
}
