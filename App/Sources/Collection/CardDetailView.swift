import SwiftUI

/// One printing in full: art, stats, rules, tags, both market prices, how many
/// the user owns, and links out to the marketplaces.
struct CardDetailView: View {
    let entry: CollectionEntry
    let pricesAsOf: Date

    @Environment(\.dismiss) private var dismiss

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
                }
                .padding()
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
                    Text("Owned value").foregroundStyle(Theme.muted)
                }
                .font(.caption)
                if entry.vault.hasNormal {
                    priceRow("Normal", entry.normalPrice)
                }
                if entry.vault.hasFoil {
                    priceRow("Foil", entry.foilPrice)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func priceRow(_ finish: String, _ price: Double?) -> some View {
        GridRow {
            Text(finish)
            Text(price.map { $0.formatted(.currency(code: "USD")) } ?? "—")
            Text(price.map { ($0 * Double(entry.quantity)).formatted(.currency(code: "USD")) } ?? "—")
                .foregroundStyle(entry.quantity > 0 ? Theme.amber : Theme.muted)
        }
        .font(.body.monospacedDigit())
        .accessibilityElement(children: .combine)
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
