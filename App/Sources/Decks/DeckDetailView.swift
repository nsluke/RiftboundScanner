import SwiftUI

/// One deck: validation verdict, then every slot with its cards and what
/// the user owns or lacks. Sharing sends the Piltover Archive text.
struct DeckDetailView: View {
    @State private var model: DeckDetailModel

    init(model: DeckDetailModel) {
        _model = State(wrappedValue: model)
    }

    var body: some View {
        Group {
            switch model.deck {
            case .idle, .loading:
                ProgressView("Loading deck…")
                    .tint(Theme.text)
            case .failed(let error):
                ContentUnavailableView {
                    Label("Couldn't load this deck", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error.message)
                } actions: {
                    Button("Try again") { Task { await model.load() } }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.amber)
                }
            case .loaded(let loaded):
                content(loaded)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        .navigationTitle(model.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                shareButton
            }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    @ViewBuilder
    private var shareButton: some View {
        switch model.export {
        case .loaded(let text):
            ShareLink(item: text, subject: Text(model.name), preview: SharePreview(model.name, image: Image(systemName: "rectangle.stack"))) {
                Label("Share decklist", systemImage: "square.and.arrow.up")
            }
            .accessibilityHint("Shares the deck as Piltover Archive text")
        case .idle, .loading:
            ProgressView()
                .accessibilityLabel("Preparing decklist")
        case .failed:
            Image(systemName: "square.and.arrow.up")
                .foregroundStyle(Theme.muted)
                .accessibilityLabel("Decklist unavailable offline")
        }
    }

    private func content(_ loaded: LoadedDeck) -> some View {
        List {
            summarySection(loaded)
            validationSection(loaded.deck.validation)
            ForEach(loaded.sections) { section in
                slotSection(section)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func summarySection(_ loaded: LoadedDeck) -> some View {
        Section {
            if case .cached(let asOf, let reason) = loaded.freshness {
                StaleBanner(asOf: asOf, reason: reason) {
                    Task { await model.load() }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(loaded.deck.formatTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.muted)
                FlowLayout(spacing: 8) {
                    Badge(text: String(localized: "\(loaded.deck.cardCount) cards"), color: Theme.blue)
                    if loaded.deck.shortCount > 0 {
                        Badge(text: String(localized: "\(loaded.deck.shortCount) short"), color: Theme.amber)
                    } else {
                        Badge(text: String(localized: "All owned"), color: Theme.blue)
                    }
                }
                if let notes = loaded.deck.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
            }
            .accessibilityElement(children: .combine)
        }
        .listRowBackground(Theme.surface)
    }

    @ViewBuilder
    private func validationSection(_ validation: DeckValidation) -> some View {
        Section {
            if validation.issues.isEmpty {
                Label {
                    Text(validation.isOK ? "Legal for \(validation.format?.capitalized ?? "this format")" : "Not checked")
                } icon: {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Color.green)
                }
            } else {
                ForEach(Array(validation.issues.enumerated()), id: \.offset) { _, issue in
                    IssueRow(issue: issue)
                }
            }
        } header: {
            Text("Validation")
                .foregroundStyle(Theme.muted)
        } footer: {
            if let asOf = validation.rulesAsOf {
                Text("Rules as of \(asOf). \(validation.errorCount) errors, \(validation.warningCount) warnings.")
                    .foregroundStyle(Theme.muted)
            }
        }
        .listRowBackground(Theme.surface)
    }

    private func slotSection(_ section: DeckSlotSection) -> some View {
        Section {
            if section.cards.isEmpty {
                Text("Empty")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            } else {
                ForEach(section.cards) { card in
                    DeckCardRow(card: card)
                }
            }
        } header: {
            DeckSlotHeader(title: section.title, count: section.count)
        }
        .listRowBackground(Theme.surface)
    }
}

/// A slot's name and count. Inline while the text fits a row, stacked at
/// accessibility sizes, so neither the name nor the count is ever truncated.
struct DeckSlotHeader: View {
    let title: String
    let count: Int

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    enum Arrangement: Hashable, Sendable {
        case inline
        case stacked

        /// Accessibility sizes stack the count under the name.
        static func fitting(_ size: DynamicTypeSize) -> Arrangement {
            size.isAccessibilitySize ? .stacked : .inline
        }
    }

    var body: some View {
        Group {
            switch Arrangement.fitting(dynamicTypeSize) {
            case .inline:
                HStack(alignment: .firstTextBaseline) {
                    titleText
                    Spacer(minLength: 8)
                    countText
                }
            case .stacked:
                VStack(alignment: .leading, spacing: 2) {
                    titleText
                    countText
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isHeader)
    }

    var accessibilityLabel: String {
        String(localized: "\(title), \(count) cards")
    }

    private var titleText: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.text)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var countText: some View {
        Text(count.formatted())
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(Theme.muted)
    }
}

/// A card in a slot: copies, name, code and rarity, and whether the user
/// owns enough of it.
struct DeckCardRow: View {
    let card: DeckCard

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                quantity
                titles
                Spacer(minLength: 8)
                badge
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    quantity
                    titles
                }
                badge
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.accessibilitySummary)
    }

    private var quantity: some View {
        Text("\(card.quantity)×")
            .font(.body.monospacedDigit().weight(.semibold))
            .foregroundStyle(Theme.amber)
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(card.name)
                .font(.body)
            HStack(spacing: 6) {
                Text(card.cardID)
                    .font(.caption.monospaced())
                if let rarity = card.rarity {
                    Text(rarity)
                        .font(.caption)
                        .foregroundStyle(Theme.rarity(rarity))
                }
                ForEach(card.domains, id: \.self) { domain in
                    Circle()
                        .fill(Theme.domain(domain))
                        .frame(width: 8, height: 8)
                }
                if card.banned {
                    Text("Banned")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
            .foregroundStyle(Theme.muted)
            if card.usedElsewhere > 0 {
                Text("\(card.usedElsewhere) in other decks")
                    .font(.caption2)
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    private var badge: some View {
        switch card.ownershipBadge {
        case .owned: Badge(text: card.ownershipBadge.text, color: Theme.blue)
        case .short: Badge(text: card.ownershipBadge.text, color: Theme.amber)
        }
    }
}

/// One validation finding with its severity.
struct IssueRow: View {
    let issue: DeckIssue

    var body: some View {
        Label {
            Text(issue.text)
                .font(.footnote)
        } icon: {
            Image(systemName: issue.isError ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(issue.isError ? Color.red : Theme.amber)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(issue.isError ? "Error: \(issue.text)" : "Warning: \(issue.text)")
    }
}
