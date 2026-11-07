import Foundation

// Display and placement rules for deck slots and cards. Pure values, so
// the tests cover them without a view.

nonisolated extension DeckSlot {
    /// The slot's name as the web builder and Piltover Archive show it.
    var title: String {
        switch self {
        case .legend: String(localized: "Legend")
        case .champion: String(localized: "Champion")
        case .rune: String(localized: "Runes")
        case .battlefield: String(localized: "Battlefields")
        case .main: String(localized: "Main Deck")
        case .sideboard: String(localized: "Sideboard")
        case .unknown(let raw): raw.capitalized
        }
    }

    /// The slot a card most likely belongs in, from its catalog type: the
    /// same rule as the server's `decks.default_slot`. Legends go to
    /// `legend` even when their supertype is Champion (the starter legends);
    /// Signature cards are spells and gear, never the chosen champion, so
    /// they go to the main deck; other Champion units are the champion.
    static func defaultSlot(type: String?, supertype: String?) -> DeckSlot {
        switch type {
        case "Legend": return .legend
        case "Rune": return .rune
        case "Battlefield": return .battlefield
        default: break
        }
        switch supertype {
        case "Signature": return .main
        case "Champion": return .champion
        default: return .main
        }
    }

    static func defaultSlot(for card: VaultCard) -> DeckSlot {
        defaultSlot(type: card.type, supertype: card.supertype)
    }
}

nonisolated extension DeckCard {
    /// How the row reads to VoiceOver: quantity, name, code, slot and what is
    /// missing, as one element.
    var accessibilitySummary: String {
        var parts = [String(localized: "\(quantity) × \(name)"), cardID, slot.title]
        if short > 0 {
            parts.append(String(localized: "\(short) short"))
        } else {
            parts.append(String(localized: "owned"))
        }
        if usedElsewhere > 0 {
            parts.append(String(localized: "\(usedElsewhere) in other decks"))
        }
        if banned {
            parts.append(String(localized: "banned"))
        }
        return parts.joined(separator: ", ")
    }

    /// The badge text: how many copies the user still needs, or none.
    var ownershipBadge: OwnershipBadge {
        short > 0 ? .short(short) : .owned
    }

    enum OwnershipBadge: Hashable, Sendable {
        case owned
        case short(Int)

        var text: String {
            switch self {
            case .owned: String(localized: "Owned")
            case .short(let count): String(localized: "\(count) short")
            }
        }
    }
}

nonisolated extension DeckSummary {
    /// `Constructed` for `constructed`; formats are lowercase on the wire.
    var formatTitle: String { format.capitalized }

    var accessibilitySummary: String {
        var parts = [name, formatTitle, String(localized: "\(cardCount) cards")]
        if let shortCount, shortCount > 0 {
            parts.append(String(localized: "\(shortCount) short"))
        }
        return parts.joined(separator: ", ")
    }
}

nonisolated extension DeckDetail {
    var formatTitle: String { format.capitalized }
}

nonisolated extension DeckIssue {
    /// The server's message, or the code spelled out when it sent none.
    var text: String {
        message ?? code.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
