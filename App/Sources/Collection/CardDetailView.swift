import SwiftUI

/// One printing in full: art, stats, rules, tags, both market prices, how many
/// the user owns of each finish (the server's count) with what this phone
/// still owes the ledger, and links out to the marketplaces.
struct CardDetailView: View {
    let entry: CollectionEntry
    let pricesAsOf: Date

    @Environment(\.dismiss) private var dismiss
    /// Set by the root view when the server is wired; absent, the action is hidden.
    @Environment(\.deckDependencies) private var decks
    @State private var addToDeck: AddToDeckModel?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    art
                    title
                    stats
                    if !entry.vault.domains.isEmpty { domains }
                    if let text = entry.vault.text { rules(text) }
                    if let flavor = entry.vault.flavor {
                        Text(flavor).font(.subheadline.italic()).foregroundStyle(Theme.muted)
                    }
                    if !entry.vault.tags.isEmpty { tags }
                    prices
                    links
                    if let decks {
                        addToDeckButton(decks)
                    }
                }
                .padding()
            }
            .sheet(item: $addToDeck) { model in
                AddToDeckSheet(model: model)
            }
            .background(Theme.ground.ignoresSafeArea())
            .foregroundStyle(Theme.text)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var art: some View {
        GeometryReader { proxy in
            CardArtView(url: entry.artURL, size: proxy.size)
        }
        .aspectRatio(5 / 7, contentMode: .fit)
        .frame(maxWidth: 300)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 12)
        .accessibilityLabel("Art for \(entry.vault.name)")
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.vault.name).font(.title2.weight(.semibold))
            HStack(spacing: 8) {
                Text(entry.vault.code).font(.subheadline.monospaced())
                Text(entry.vault.setName)
                Text(entry.vault.rarity).foregroundStyle(Theme.rarity(entry.vault.rarity)).fontWeight(.semibold)
                if let type = entry.vault.type {
                    Text([entry.vault.supertype, type].compactMap { $0 }.joined(separator: " "))
                }
            }
            .font(.subheadline)
            .foregroundStyle(Theme.muted)
            HStack(spacing: 8) {
                if entry.vault.promo { badge("Promo", Theme.amber) }
                if entry.vault.banned { badge("Banned", .red) }
                if entry.quantity > 0 { badge("\(entry.quantity) owned", Theme.blue) }
                if entry.pending != 0 { PendingChip(count: entry.pending) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    @ViewBuilder
    private var stats: some View {
        let items: [(String, Int?)] = [("Energy", entry.vault.energy), ("Might", entry.vault.might), ("Power", entry.vault.power)]
        let present = items.filter { $0.1 != nil }
        if !present.isEmpty {
            HStack(spacing: 8) {
                ForEach(present, id: \.0) { label, value in
                    VStack(spacing: 2) {
                        Text(label.uppercased()).font(.caption2).foregroundStyle(Theme.muted)
                        Text("\(value ?? 0)").font(.title3.weight(.semibold))
                    }
                    .frame(minWidth: 64)
                    .padding(8)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var domains: some View {
        HStack(spacing: 8) {
            ForEach(entry.vault.domains, id: \.self) { domain in
                HStack(spacing: 6) {
                    Circle().fill(Theme.domain(domain)).frame(width: 10, height: 10)
                    Text(domain)
                }
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.surface, in: Capsule())
            }
        }
    }

    private func rules(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }

    private var tags: some View {
        FlowLayout(spacing: 6) {
            ForEach(entry.vault.tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.hairline))
            }
        }
    }

    private var prices: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TCGplayer market · \(pricesAsOf.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.muted)
            Grid(horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Finish").foregroundStyle(Theme.muted)
                    Text("Each").foregroundStyle(Theme.muted)
                    Text("Owned").foregroundStyle(Theme.muted)
                    Text("Value").foregroundStyle(Theme.muted)
                }
                .font(.caption)
                // Every finish the server counts shows, even one the vault
                // says the printing lacks: a ledger row is a fact.
                if entry.vault.hasNormal || entry.owned.normal > 0 {
                    priceRow("Normal", entry.normalPrice, owned: entry.owned.normal)
                }
                if entry.vault.hasFoil || entry.owned.foil > 0 {
                    priceRow("Foil", entry.foilPrice, owned: entry.owned.foil)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func priceRow(_ finish: String, _ price: Double?, owned: Int) -> some View {
        GridRow {
            Text(finish)
            Text(price.map { $0.formatted(.currency(code: "USD")) } ?? "—")
            Text("\(owned)")
                .foregroundStyle(owned > 0 ? Theme.text : Theme.muted)
                .accessibilityLabel("\(owned) owned")
            Text(price.map { ($0 * Double(owned)).formatted(.currency(code: "USD")) } ?? "—")
                .foregroundStyle(owned > 0 ? Theme.amber : Theme.muted)
        }
        .font(.body.monospacedDigit())
        .accessibilityElement(children: .combine)
    }

    /// Opens the deck picker for this printing (ADR-002 Decision 11: the
    /// phone's one deck write).
    private func addToDeckButton(_ decks: DeckDependencies) -> some View {
        Button {
            addToDeck = decks.makeAddToDeckModel(for: entry.vault)
        } label: {
            Label("Add to deck…", systemImage: "plus.rectangle.on.rectangle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.amber)
        .accessibilityHint("Chooses a deck on your server to add \(entry.vault.name) to")
    }

    private var links: some View {
        HStack(spacing: 10) {
            if let url = entry.vault.tcgplayerURL {
                Link(destination: url) { Label("TCGplayer", systemImage: "cart") }
            }
            if let url = entry.vault.cardmarketURL {
                Link(destination: url) { Label("Cardmarket", systemImage: "eurosign.circle") }
            }
        }
        .buttonStyle(.bordered)
        .tint(Theme.blue)
    }
}
