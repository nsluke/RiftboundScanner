import Foundation

/// One printing of a Riftbound card, as listed in the community catalog.
///
/// Standard, alternate-art, overnumbered and signature printings are separate
/// values, each with its own ``PrintedCode``. Match printings by ``id`` or by
/// ``code``, never by name alone: 151 names in the Origins-to-Vendetta catalog
/// have more than one printing.
public struct Card: Hashable, Sendable, Codable, Identifiable {
    /// The catalog identifier, e.g. `ogn-007a-298`; unique per printing.
    public struct ID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue }
    }

    /// How the card is printed. Battlefields are landscape; everything else is portrait.
    public enum Orientation: String, Hashable, Sendable, Codable {
        case portrait
        case landscape
    }

    public let id: ID
    public let name: String
    public let displayName: String
    public let code: PrintedCode
    public let setName: String
    public let rarity: Rarity
    /// `nil` when the catalog lists no type for the printing.
    public let kind: Kind?
    public let printing: PrintingTraits
    public let orientation: Orientation
    /// The exact CDN URL the catalog supplies. Riot's assets are never bundled or committed.
    public let imageURL: URL

    public init(
        id: ID,
        name: String,
        displayName: String,
        code: PrintedCode,
        setName: String,
        rarity: Rarity,
        kind: Kind?,
        printing: PrintingTraits,
        orientation: Orientation,
        imageURL: URL
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.code = code
        self.setName = setName
        self.rarity = rarity
        self.kind = kind
        self.printing = printing
        self.orientation = orientation
        self.imageURL = imageURL
    }
}

/// Card rarity. Unknown catalog values decode into ``unknown(_:)`` instead of failing the load.
public enum Rarity: Hashable, Sendable, Codable {
    case common, uncommon, rare, epic, showcase
    case unknown(String)

    public init(label: String) {
        switch label.lowercased() {
        case "common": self = .common
        case "uncommon": self = .uncommon
        case "rare": self = .rare
        case "epic": self = .epic
        case "showcase": self = .showcase
        default: self = .unknown(label)
        }
    }

    public var label: String {
        switch self {
        case .common: "Common"
        case .uncommon: "Uncommon"
        case .rare: "Rare"
        case .epic: "Epic"
        case .showcase: "Showcase"
        case .unknown(let label): label
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(label: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(label)
    }
}

/// Card type. Unknown catalog values decode into ``unknown(_:)`` instead of failing the load.
public enum Kind: Hashable, Sendable, Codable {
    case unit, spell, legend, gear, battlefield, rune
    case unknown(String)

    public init(label: String) {
        switch label.lowercased() {
        case "unit": self = .unit
        case "spell": self = .spell
        case "legend": self = .legend
        case "gear": self = .gear
        case "battlefield": self = .battlefield
        case "rune": self = .rune
        default: self = .unknown(label)
        }
    }

    public var label: String {
        switch self {
        case .unit: "Unit"
        case .spell: "Spell"
        case .legend: "Legend"
        case .gear: "Gear"
        case .battlefield: "Battlefield"
        case .rune: "Rune"
        case .unknown(let label): label
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(label: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(label)
    }
}

/// Independent printing flags from the catalog. They can overlap: a signature
/// printing is usually also overnumbered.
public struct PrintingTraits: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let alternateArt = PrintingTraits(rawValue: 1 << 0)
    public static let signature = PrintingTraits(rawValue: 1 << 1)
    public static let overnumbered = PrintingTraits(rawValue: 1 << 2)
}
