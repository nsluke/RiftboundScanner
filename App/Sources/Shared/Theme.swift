import SwiftUI

/// The review flow's palette, from the approved design. Dark ground, amber for
/// what needs the user and for primary actions, blue for what is settled.
enum Theme {
    static let ground = Color(red: 0x0F / 255, green: 0x11 / 255, blue: 0x15 / 255)
    static let surface = Color(red: 0x1A / 255, green: 0x1D / 255, blue: 0x24 / 255)
    static let hairline = Color(red: 0x2A / 255, green: 0x2F / 255, blue: 0x3A / 255)
    static let amber = Color(red: 0xF2 / 255, green: 0xB8 / 255, blue: 0x4B / 255)
    static let blue = Color(red: 0x7C / 255, green: 0xC4 / 255, blue: 0xFF / 255)
    static let muted = Color(red: 0x9A / 255, green: 0xA3 / 255, blue: 0xB2 / 255)
    /// A match the user has marked wrong.
    static let wrong = Color(red: 0xEF / 255, green: 0x6B / 255, blue: 0x5E / 255)
    static let text = Color.white

    /// Rarity and domain colours from the Card Vault design.
    static func rarity(_ label: String) -> Color {
        switch label {
        case "Uncommon": Color(red: 0x5A / 255, green: 0xA5 / 255, blue: 0x8C / 255)
        case "Rare": Color(red: 0x5C / 255, green: 0x8F / 255, blue: 0xE0 / 255)
        case "Epic": Color(red: 0xB0 / 255, green: 0x6A / 255, blue: 0xE8 / 255)
        case "Showcase": Color(red: 0xE2 / 255, green: 0xB8 / 255, blue: 0x4F / 255)
        default: Color(red: 0x8A / 255, green: 0x90 / 255, blue: 0x99 / 255)
        }
    }

    static func domain(_ name: String) -> Color {
        switch name {
        case "Fury": Color(red: 0xD9 / 255, green: 0x55 / 255, blue: 0x3F / 255)
        case "Calm": Color(red: 0x4F / 255, green: 0xB0 / 255, blue: 0x88 / 255)
        case "Mind": Color(red: 0x4A / 255, green: 0x8F / 255, blue: 0xD6 / 255)
        case "Body": Color(red: 0xD8 / 255, green: 0xA3 / 255, blue: 0x3A / 255)
        case "Chaos": Color(red: 0x9B / 255, green: 0x5F / 255, blue: 0xD1 / 255)
        case "Order": Color(red: 0xE3 / 255, green: 0xDC / 255, blue: 0xC3 / 255)
        default: Color(red: 0x8A / 255, green: 0x90 / 255, blue: 0x99 / 255)
        }
    }
}
