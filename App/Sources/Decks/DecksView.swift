import SwiftUI

/// The Decks tab: the decks built on the web, read-only, with what the user
/// owns against each. Editing happens in the web builder; the phone adds
/// cards from their detail sheet.
struct DecksView: View {
    let model: DecksModel
    let dependencies: DeckDependencies

    var body: some View {
        Group {
            switch model.decks {
            case .idle, .loading:
                ProgressView("Loading decks…")
                    .tint(Theme.text)
            case .failed(let error):
                ContentUnavailableView {
                    Label("Couldn't load your decks", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error.message)
                } actions: {
                    Button("Try again") { Task { await model.load() } }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.amber)
                }
            case .loaded(let listing):
                if listing.decks.isEmpty {
                    ContentUnavailableView {
                        Label("No decks yet", systemImage: "rectangle.stack")
                    } description: {
                        Text("Build a deck in the web builder on your collection server; it appears here with what you own.")
                    } actions: {
                        if listing.freshness.isCached {
                            Button("Try again") { Task { await model.load() } }
                        }
                    }
                } else {
                    list(listing)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        .navigationTitle("Decks")
        .darkNavigationBar()
        .navigationDestination(for: DeckSummary.self) { summary in
            DeckDetailView(model: dependencies.makeDetailModel(for: summary))
        }
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    private func list(_ listing: DeckListing) -> some View {
        List {
            if case .cached(let asOf, let reason) = listing.freshness {
                Section {
                    StaleBanner(asOf: asOf, reason: reason) {
                        Task { await model.load() }
                    }
                }
                .listRowBackground(Theme.surface)
            }
            Section {
                ForEach(listing.decks) { deck in
                    NavigationLink(value: deck) {
                        DeckRow(deck: deck)
                    }
                    .listRowBackground(Theme.surface)
                }
            } footer: {
                Text("Decks are built and edited on the web; owned and short counts come from your ledger.")
                    .foregroundStyle(Theme.muted)
            }
        }
        .scrollContentBackground(.hidden)
    }
}

/// One deck in the list: name, format, size and how many copies are missing.
struct DeckRow: View {
    let deck: DeckSummary

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                titles
                Spacer(minLength: 8)
                badges
            }
            VStack(alignment: .leading, spacing: 6) {
                titles
                badges
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(deck.accessibilitySummary)
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(deck.name)
                .font(.headline)
            Text("\(deck.formatTitle) · \(deck.cardCount) cards")
                .font(.caption)
                .foregroundStyle(Theme.muted)
        }
    }

    @ViewBuilder
    private var badges: some View {
        if let shortCount = deck.shortCount, shortCount > 0 {
            Badge(text: String(localized: "\(shortCount) short"), color: Theme.amber)
        }
    }
}

/// "Showing the copy saved at …" with the reason and a retry.
struct StaleBanner: View {
    let asOf: Date
    let reason: ServerError
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Showing decks saved \(asOf.formatted(date: .abbreviated, time: .shortened)). \(reason.message)")
                    .font(.footnote)
            } icon: {
                Image(systemName: "wifi.exclamationmark")
            }
            .foregroundStyle(Theme.amber)
            Button("Retry now", action: retry)
                .font(.footnote.weight(.semibold))
                .tint(Theme.amber)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Offline. Showing decks saved \(asOf.formatted(date: .abbreviated, time: .shortened)).")
    }
}

/// A small capsule label in the theme's colours.
struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
            .fixedSize(horizontal: true, vertical: false)
    }
}
