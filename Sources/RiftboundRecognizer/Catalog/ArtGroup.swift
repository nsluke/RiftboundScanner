import Foundation

/// The learning identity of a printing: every printing that shares an
/// illustration (standard, alternate-art `a`, signature `*`) belongs to one
/// group, so an exemplar learned from a photo of any of them helps all of them
/// equally and the printed code stays the only thing that tells them apart.
///
/// It is the recogniser ``Card/ID`` with the total and the `a`/`*` suffix
/// stripped: `sfd-227*-221` -> `sfd-227`, `ven-038a-166` -> `ven-038`,
/// `rad-r01a` -> `rad-r01`, `unl-t01` -> `unl-t01` (ADR-002, decision 1).
public struct ArtGroup: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The group of a printing. An id in an unrecognised shape is its own group,
    /// so an unexpected catalog spelling can never merge two printings by accident.
    public init(_ cardID: Card.ID) {
        rawValue = Self.group(of: cardID.rawValue) ?? cardID.rawValue
    }

    /// `set-number` for an id shaped `set-number[a|*][-total]`, else `nil`.
    /// Hand-rolled rather than a regex: it runs once per index entry per
    /// hypothesis, so it has to cost less than the dot product beside it.
    private static func group(of id: String) -> String? {
        var parts = id.utf8.split(separator: UInt8(ascii: "-"), omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        if parts.count == 3 {
            let total = parts.removeLast()
            guard (1...3).contains(total.count), total.allSatisfy(isDigit) else { return nil }
        }
        let set = parts[0]
        guard (2...4).contains(set.count), set.allSatisfy(isLowercaseLetter) else { return nil }
        var number = parts[1][...]
        if let last = number.last, last == UInt8(ascii: "a") || last == UInt8(ascii: "*") {
            number = number.dropLast()
        }
        let letters = number.prefix(while: isLowercaseLetter)
        let digits = number.dropFirst(letters.count)
        guard letters.count <= 2, (1...3).contains(digits.count), digits.allSatisfy(isDigit) else { return nil }
        return String(decoding: set, as: UTF8.self) + "-" + String(decoding: number, as: UTF8.self)
    }

    private static func isDigit(_ byte: UInt8) -> Bool { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) }
    private static func isLowercaseLetter(_ byte: UInt8) -> Bool { (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) }

    /// The group a printed code names, in the same spelling as ``init(_:)``
    /// produces for the catalog id of that printing.
    public init(code: PrintedCode) {
        rawValue = "\(code.set.rawValue.lowercased())-\(code.number.rawValue.lowercased())"
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension Card {
    /// See ``ArtGroup``.
    public var artGroup: ArtGroup { ArtGroup(id) }
}

extension CardIndex.Entry {
    /// See ``ArtGroup``.
    public var artGroup: ArtGroup { card.artGroup }
}
