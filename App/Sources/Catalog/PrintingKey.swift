import Foundation
import RiftboundRecognizer

/// The identity a printing shares between the recogniser's index and the
/// vault: set, collector number and variant with no denominator, in the
/// index's spelling (`OGN-066`, `OGN-066a`, `SFD-227*`, `RAD-R01`).
///
/// The index writes `sfd-227*-221` where the vault writes `SFD-227-STAR`, and
/// `ven-038a-166` where the vault writes `VEN-038A`; both sides reduce to one
/// key here (ADR-002, decision 1). Vault codes the recogniser can never
/// produce keep their raw spelling so they never collide with the base
/// printing: promo suffixes (`OGN-066-P`, `SFD-178a-P`, `UNL-058-P-Champion`),
/// rune and token backs (`RAD-R01b-P`, `UNL-T01g`) and the oversized rows
/// that carry a denominator (`OGN-279/298`). The server resolves this key
/// through `card_aliases`, so the app never needs the vault spelling.
nonisolated struct PrintingKey: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The key of an index printing: its code without the denominator.
    init(_ code: PrintedCode) {
        rawValue = "\(code.set.rawValue)-\(code.number.rawValue)\(code.variant.rawValue)"
    }

    /// The key of a vault row. `-STAR` becomes `*` and a trailing uppercase
    /// variant letter becomes lowercase; any code with a `/` or a suffix the
    /// index does not know is kept as written.
    init(vaultCode code: String) {
        guard let match = code.wholeMatch(of: #/(?<set>[A-Z]{2,4})-(?<number>[A-Z]{0,2}[0-9]{1,3})(?<variant>a|A|\*|-STAR)?/#),
              let set = SetCode(rawValue: String(match.output.set)),
              let number = CollectorNumber(rawValue: String(match.output.number))
        else {
            self.init(rawValue: code)
            return
        }
        let variant: PrintedCode.Variant = switch match.output.variant {
        case "a", "A": .alternateArt
        case "*", "-STAR": .signature
        default: .standard
        }
        self.init(PrintedCode(set: set, number: number, variant: variant))
    }

    /// The key of an index card id (`ogn-007a-298`, `sfd-227*-221`, `rad-r01`),
    /// which is the printed code lowercased with its denominator joined by a
    /// hyphen. `nil` for anything that is not exactly such an id.
    init?(cardID: Card.ID) {
        guard let match = cardID.rawValue.wholeMatch(of: #/(?<set>[a-z]{3})-(?<number>[a-z]{0,2}[0-9]{1,3})(?<variant>[a*]?)(?:-[0-9]{1,3})?/#),
              let set = SetCode(rawValue: String(match.output.set).uppercased()),
              let number = CollectorNumber(rawValue: String(match.output.number).uppercased())
        else { return nil }
        let variant: PrintedCode.Variant = switch match.output.variant {
        case "a": .alternateArt
        case "*": .signature
        default: .standard
        }
        self.init(PrintedCode(set: set, number: number, variant: variant))
    }

    /// Set and collector number with every suffix dropped: the vault-side
    /// spelling of the recogniser's ArtGroup, shared by every printing of one
    /// piece of art (`SFD-178` for `SFD-178`, `SFD-178a-P` and `SFD-178-P`).
    /// `nil` for the oversized `/NNN` rows, which are never grouped with the
    /// base printing, and for codes with no collector number (`OGN-P`).
    var artGroupCode: String? {
        guard !rawValue.contains("/"),
              let match = rawValue.prefixMatch(of: #/(?<set>[A-Z]{2,4})-(?<number>[A-Z]{0,2}[0-9]{1,3})(?![0-9])/#)
        else { return nil }
        return "\(match.output.set)-\(match.output.number)"
    }

    var description: String { rawValue }
}
