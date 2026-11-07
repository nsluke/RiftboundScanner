import SwiftUI

/// One chip per printing the scan could be ledgered as (ADR-002, decision
/// 13): the recognised printing first, its vault siblings after it, and for
/// a sealed-box batch the promo siblings behind "Other printings…". The
/// pre-selected chip is the inherited printing; tapping another is what
/// writes `Decision.ledgerPrintingCode = .set`.
struct PrintingPickerView: View {
    let options: PrintingOptions
    @Binding var selection: PrintingKey?

    @State private var isShowingHidden = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Printing")
                .font(.subheadline.weight(.medium))
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(options.shown) { row in
                        chip(row)
                    }
                    if isShowingHidden {
                        ForEach(options.hidden) { row in
                            chip(row)
                        }
                    } else if !options.hidden.isEmpty {
                        Button {
                            isShowingHidden = true
                        } label: {
                            Text("Other printings…")
                                .font(.footnote.weight(.medium))
                                .padding(.horizontal, 12)
                                .frame(minHeight: 36)
                        }
                        .foregroundStyle(Theme.blue)
                        .accessibilityLabel("Other printings")
                        .accessibilityHint("Shows \(options.hidden.count) promo printings a sealed box does not contain")
                    }
                }
            }
            .scrollIndicators(.hidden)
            if options.shown.isEmpty {
                Text("The vault has no row for this printing; it is ledgered as recognised.")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Printing")
    }

    private func chip(_ row: VaultCard) -> some View {
        let isSelected = selection == row.key
        return Button {
            selection = row.key
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.code)
                    .font(.footnote.monospaced().weight(.semibold))
                Text(chipDetail(row))
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Theme.ground.opacity(0.8) : Theme.muted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 36)
            .background(isSelected ? Theme.amber : Theme.surface, in: Capsule())
            .overlay(Capsule().stroke(isSelected ? Theme.amber : Theme.hairline, lineWidth: 1))
        }
        .foregroundStyle(isSelected ? Theme.ground : Theme.text)
        .accessibilityLabel("Printing \(row.code), \(chipDetail(row))")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint(row.key == options.recognized ? "The printing the recogniser named" : "Ledgers this scan as this printing")
    }

    /// Rarity plus the finishes the vault lists, and "promo" when it is one.
    private func chipDetail(_ row: VaultCard) -> String {
        var parts = [row.promo ? String(localized: "promo") : row.rarity.lowercased()]
        switch (row.hasNormal, row.hasFoil) {
        case (true, false): parts.append(String(localized: "normal only"))
        case (false, true): parts.append(String(localized: "foil only"))
        case (true, true): parts.append(String(localized: "normal or foil"))
        case (false, false): break
        }
        return parts.joined(separator: " · ")
    }
}

/// Normal/Foil for a printing that comes in both (ADR-002, decision 3). The
/// pre-selected value is the inherited one; a tap on the other is what
/// writes `Decision.finish = .set`. With no inherited value (the vault does
/// not know the printing) neither is selected until the user says.
struct FinishToggle: View {
    @Binding var selection: Finish?
    let inherited: Finish?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Finish")
                .font(.subheadline.weight(.medium))
            HStack(spacing: 8) {
                ForEach(Finish.allCases, id: \.self) { finish in
                    let isSelected = selection == finish
                    Button {
                        selection = finish
                    } label: {
                        Text(finish.label)
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 36)
                            .frame(maxWidth: .infinity)
                            .background(isSelected ? Theme.amber : Theme.surface, in: Capsule())
                            .overlay(Capsule().stroke(isSelected ? Theme.amber : Theme.hairline, lineWidth: 1))
                    }
                    .foregroundStyle(isSelected ? Theme.ground : Theme.text)
                    .accessibilityLabel(finish.label)
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                    .accessibilityHint(finish == inherited ? "The finish this scan already has" : "Records this scan as \(finish.label.lowercased())")
                }
            }
            if inherited == nil {
                Text("The vault does not say which finishes this printing comes in. Pick one, or leave it for the server to decide.")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Finish")
    }
}

nonisolated extension Finish {
    var label: String {
        switch self {
        case .normal: String(localized: "Normal")
        case .foil: String(localized: "Foil")
        }
    }
}
