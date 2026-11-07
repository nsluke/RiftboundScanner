import SwiftUI

/// The user's cards, or the whole catalog with owned counts, as a grid or a
/// list with search, filters, sorting and market prices.
struct CollectionView: View {
    let model: CollectionModel
    /// Builds the Add card sheet's model (ADR-002, decision 13).
    let makeAddCard: () -> AddCardModel

    enum Layout: Hashable { case grid, list }

    @State private var layout: Layout = .grid
    @State private var isFiltering = false
    @State private var isAddingCard = false
    @State private var selected: CollectionEntry?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 12)]

    var body: some View {
        Group {
            switch model.owned {
            case .idle, .loading:
                ProgressView().tint(Theme.text)
            case .failed(let problem):
                ContentUnavailableView {
                    Label("Couldn't load your collection", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(problem.message)
                } actions: {
                    Button("Try again") { Task { await model.load() } }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.amber)
                }
            case .loaded:
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        .navigationTitle("Collection")
        .toolbarColorScheme(.dark, for: .navigationBar)
        .searchable(text: filterBinding.query, prompt: "Name, code or tag")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isAddingCard = true
                } label: {
                    Label("Add card", systemImage: "plus")
                }
                .accessibilityHint("Adds a card by hand, for printings the scanner cannot see")
                sortMenu
                Button {
                    isFiltering = true
                } label: {
                    Label("Filters", systemImage: model.filter.activeCount > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel(model.filter.activeCount > 0 ? "Filters, \(model.filter.activeCount) active" : "Filters")
            }
        }
        .sheet(isPresented: $isFiltering) {
            CollectionFilterSheet(model: model)
        }
        .sheet(isPresented: $isAddingCard) {
            AddCardSheet(model: makeAddCard()) { _ in }
        }
        .sheet(item: $selected) { entry in
            CardDetailView(entry: entry, pricesAsOf: model.pricesAsOf)
        }
        .task { await model.load() }
        .refreshable { await model.refreshPrices() }
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                scopePicker
                if model.shown.isEmpty {
                    emptyState
                } else {
                    switch layout {
                    case .grid: grid
                    case .list: list
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
    }

    private var header: some View {
        let totals = model.totals
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.filter.ownedOnly ? "\(totals.cards) cards · \(totals.printings) printings" : "\(totals.printings) printings · \(totals.cards) owned")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(totals.value, format: .currency(code: "USD").precision(.fractionLength(0)))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.amber)
            }
            HStack(spacing: 6) {
                pricesStatus
                Spacer()
                Picker("Layout", selection: $layout) {
                    Image(systemName: "square.grid.2x2").tag(Layout.grid)
                    Image(systemName: "list.bullet").tag(Layout.list)
                }
                .pickerStyle(.segmented)
                .frame(width: 100)
            }
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var pricesStatus: some View {
        switch model.prices {
        case .loading:
            Label("Updating prices…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(Theme.muted)
        case .loaded(let sheet):
            Text("TCGplayer market as of \(sheet.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(Theme.muted)
        case .failed(let error):
            Label("Snapshot prices from \(model.vault.asOf.formatted(date: .abbreviated, time: .omitted)) · \(error.message)", systemImage: "wifi.exclamationmark")
                .font(.caption)
                .foregroundStyle(Theme.amber)
                .lineLimit(2)
        case .idle:
            Text("Snapshot prices from \(model.vault.asOf.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption)
                .foregroundStyle(Theme.muted)
        }
    }

    private var scopePicker: some View {
        Picker("Scope", selection: filterBinding.ownedOnly) {
            Text("My cards").tag(true)
            Text("All cards").tag(false)
        }
        .pickerStyle(.segmented)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(model.filter.ownedOnly && model.ownedTotals.cards == 0 ? "No cards yet" : "Nothing matches", systemImage: "square.grid.2x2")
        } description: {
            Text(model.filter.ownedOnly && model.ownedTotals.cards == 0
                 ? "Cards you confirm after scanning appear here."
                 : "Try fewer filters or a different search.")
        }
        .padding(.top, 40)
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(model.shown) { entry in
                Button {
                    selected = entry
                } label: {
                    CollectionCardCell(entry: entry)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var list: some View {
        LazyVStack(spacing: 0) {
            ForEach(model.shown) { entry in
                Button {
                    selected = entry
                } label: {
                    CollectionRow(entry: entry)
                }
                .buttonStyle(.plain)
                Divider().overlay(Theme.hairline)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: filterBinding.sort) {
                ForEach(CollectionFilter.Sort.allCases, id: \.self) { sort in
                    Text(sort.label).tag(sort)
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
    }

    private var filterBinding: Binding<CollectionFilter> {
        Binding(get: { model.filter }, set: { model.filter = $0 })
    }
}

/// A card in the grid: art, name, code, rarity colour, price and owned count.
struct CollectionCardCell: View {
    let entry: CollectionEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                CardArtView(url: entry.artURL, size: proxy.size)
            }
            .aspectRatio(5 / 7, contentMode: .fit)
            .overlay(alignment: .topTrailing) {
                if entry.quantity > 0 {
                    Text("×\(entry.quantity)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.ground.opacity(0.85), in: Capsule())
                        .padding(4)
                }
            }
            .overlay(alignment: .leading) {
                Rectangle().fill(Theme.rarity(entry.vault.rarity)).frame(width: 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(entry.vault.name)
                .font(.caption.weight(.semibold))
                .lineLimit(2, reservesSpace: true)
            HStack {
                Text(entry.vault.code)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.muted)
                Spacer()
                PriceText(entry: entry)
                    .font(.caption.weight(.medium))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [entry.vault.name, entry.vault.code, entry.vault.rarity]
        if entry.quantity > 0 { parts.append(String(localized: "\(entry.quantity) owned")) }
        if let price = entry.bestPrice { parts.append(price.formatted(.currency(code: "USD"))) }
        return parts.joined(separator: ", ")
    }
}

struct CollectionRow: View {
    let entry: CollectionEntry

    var body: some View {
        HStack(spacing: 12) {
            CardArtView(url: entry.artURL, size: CGSize(width: 40, height: 56))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.vault.name).font(.body)
                HStack(spacing: 6) {
                    Text(entry.vault.code).font(.caption.monospaced())
                    Text(entry.vault.rarity).font(.caption).foregroundStyle(Theme.rarity(entry.vault.rarity))
                    ForEach(entry.vault.domains, id: \.self) { domain in
                        Circle().fill(Theme.domain(domain)).frame(width: 8, height: 8)
                            .accessibilityLabel(domain)
                    }
                }
                .foregroundStyle(Theme.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                PriceText(entry: entry).font(.body.weight(.medium))
                if entry.quantity > 0 {
                    Text("×\(entry.quantity)").font(.caption.monospacedDigit()).foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The best market price, marked when it is the foil price.
struct PriceText: View {
    let entry: CollectionEntry

    var body: some View {
        if let price = entry.bestPrice {
            HStack(spacing: 3) {
                Text(price, format: .currency(code: "USD").precision(.fractionLength(2)))
                if !entry.vault.hasNormal || entry.normalPrice == nil {
                    Text("foil").font(.caption2).foregroundStyle(Theme.muted)
                }
            }
        } else {
            Text("—").foregroundStyle(Theme.muted)
        }
    }
}
