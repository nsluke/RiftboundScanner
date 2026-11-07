import SwiftUI

/// The user's cards as the server's ledger has them, or the whole catalog
/// with owned counts, as a grid or a list with search, filters, sorting and
/// market prices. Offline it shows the last snapshot with a notice; never
/// connected, the bundled catalog with zero counts and a Connect action.
struct CollectionView: View {
    let model: CollectionModel

    enum Layout: Hashable { case grid, list }

    @Environment(SyncEngine.self) private var sync: SyncEngine?
    @State private var layout: Layout = .grid
    @State private var isFiltering = false
    @State private var selected: CollectionEntry?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 12)]

    var body: some View {
        Group {
            switch model.holdings {
            case .idle, .loading:
                ProgressView().tint(Theme.text)
                    .accessibilityLabel("Loading your collection")
            case .loaded, .failed:
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
        .sheet(item: $selected) { entry in
            CardDetailView(entry: entry, pricesAsOf: model.pricesAsOf)
        }
        .task { await model.load() }
        .refreshable { await model.refresh() }
        // The ledger moved on the server, the outbox changed, or the server's
        // catalog version did: the sync engine knows first.
        .onChange(of: sync?.ledgerGeneration) { _, _ in Task { await model.refreshHoldings() } }
        .onChange(of: sync?.queuedItems) { _, _ in Task { await model.refreshPending() } }
        .onChange(of: sync?.catalogVersion) { _, version in Task { await model.noteServerCatalogVersion(version ?? nil) } }
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                ForEach(model.notices) { notice in
                    NoticeBanner(notice: notice)
                }
                scopePicker
                if model.isDisconnected, model.filter.ownedOnly {
                    disconnectedState
                } else if model.shown.isEmpty {
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
                if model.pendingTotal != 0 {
                    PendingChip(count: model.pendingTotal)
                }
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
        let snapshotLine = String(localized: "Snapshot prices from \(model.vault.asOf.formatted(date: .abbreviated, time: .omitted))")
        switch model.prices {
        case .loading:
            Label("Updating prices…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(Theme.muted)
        case .loaded(let sheet):
            Text("TCGplayer market as of \(sheet.asOf.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption)
                .foregroundStyle(Theme.muted)
        case .failed(.notFound):
            Text("\(snapshotLine) · the server has no prices yet")
                .font(.caption)
                .foregroundStyle(Theme.muted)
                .lineLimit(2)
        case .failed(let error):
            Label("\(snapshotLine) · \(error.message)", systemImage: "wifi.exclamationmark")
                .font(.caption)
                .foregroundStyle(Theme.amber)
                .lineLimit(2)
        case .idle:
            Text(snapshotLine)
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
                 ? "Cards you confirm after scanning appear here once your server has them."
                 : "Try fewer filters or a different search.")
        }
        .padding(.top, 40)
    }

    /// Never connected: the server has not answered yet and nothing is
    /// cached. All cards still browses the bundled catalog.
    @ViewBuilder
    private var disconnectedState: some View {
        if case .failed(let error) = model.holdings {
            ContentUnavailableView {
                Label("Not connected to your server", systemImage: "externaldrive.badge.wifi")
            } description: {
                Text("\(error.message) Your collection lives on the server; the catalog is here to browse meanwhile.")
            } actions: {
                Button("Connect") { Task { await model.connect() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.amber)
                    .accessibilityHint("Looks for your collection server again")
            }
            .padding(.top, 40)
        }
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

/// The offline and catalog notices, one line each, readable as one element.
struct NoticeBanner: View {
    let notice: CollectionNotice

    var body: some View {
        Label {
            Text(notice.message)
                .font(.footnote)
        } icon: {
            Image(systemName: symbol)
        }
        .foregroundStyle(Theme.amber)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch notice {
        case .offline: "wifi.exclamationmark"
        case .catalogNewerThanBundle: "arrow.down.doc"
        }
    }
}

/// "+N pending": what this phone still owes the ledger for a printing.
struct PendingChip: View {
    let count: Int

    var body: some View {
        Text(count > 0 ? "+\(count) pending" : "\(count) pending")
            .font(.caption2.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.amber.opacity(0.2), in: Capsule())
            .foregroundStyle(Theme.amber)
            .accessibilityLabel(count > 0 ? "\(count) pending sync" : "\(-count) pending removal")
    }
}

/// A card in the grid: art, name, code, rarity colour, price, owned count
/// and the pending chip.
struct CollectionCardCell: View {
    let entry: CollectionEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                CardArtView(url: entry.artURL, size: proxy.size)
            }
            .aspectRatio(5 / 7, contentMode: .fit)
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: 2) {
                    if entry.quantity > 0 {
                        Text("×\(entry.quantity)")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.ground.opacity(0.85), in: Capsule())
                    }
                    if entry.pending != 0 {
                        PendingChip(count: entry.pending)
                            .background(Theme.ground.opacity(0.85), in: Capsule())
                    }
                }
                .padding(4)
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
        if entry.pending > 0 { parts.append(String(localized: "\(entry.pending) pending sync")) }
        if entry.pending < 0 { parts.append(String(localized: "\(-entry.pending) pending removal")) }
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
                HStack(spacing: 4) {
                    if entry.quantity > 0 {
                        Text("×\(entry.quantity)").font(.caption.monospacedDigit()).foregroundStyle(Theme.muted)
                    }
                    if entry.pending != 0 {
                        PendingChip(count: entry.pending)
                    }
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
