import SwiftUI

/// Adds the card shown in `CardDetailView` to one of the decks on the
/// server. Online only: offline the form stays visible but the action is
/// disabled and says why.
struct AddToDeckSheet: View {
    @State private var model: AddToDeckModel
    @Environment(\.dismiss) private var dismiss

    init(model: AddToDeckModel) {
        _model = State(wrappedValue: model)
    }

    var body: some View {
        NavigationStack {
            Form {
                cardSection
                if let message = model.offlineMessage {
                    offlineSection(message)
                }
                deckSection
                placementSection
                actionSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ground.ignoresSafeArea())
            .foregroundStyle(Theme.text)
            .navigationTitle("Add to deck")
            .inlineNavigationTitle()
            .darkNavigationBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isAdded ? "Done" : "Cancel") { dismiss() }
                }
            }
            .task { await model.load() }
        }
    }

    private var isAdded: Bool {
        if case .loaded = model.submission { return true }
        return false
    }

    private var cardSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.card.name)
                    .font(.headline)
                Text([model.card.code, model.card.supertype, model.card.type].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            .accessibilityElement(children: .combine)
        }
        .listRowBackground(Theme.surface)
    }

    private func offlineSection(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "wifi.exclamationmark")
                .font(.footnote)
                .foregroundStyle(Theme.amber)
            Button {
                Task { await model.retryConnection() }
            } label: {
                Label("Try again", systemImage: "arrow.clockwise")
            }
        }
        .listRowBackground(Theme.surface)
    }

    @ViewBuilder
    private var deckSection: some View {
        Section {
            switch model.decks.decks {
            case .idle, .loading:
                ProgressView("Loading decks…")
            case .failed(let error):
                Label(error.message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Theme.amber)
            case .loaded(let listing):
                if listing.decks.isEmpty {
                    Text("No decks yet. Build one in the web builder first.")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                } else {
                    Picker("Deck", selection: deckSelection) {
                        ForEach(listing.decks) { deck in
                            Text("\(deck.name) · \(deck.formatTitle)").tag(Optional(deck.id))
                        }
                    }
                    .drillDownPickerStyle()
                    .accessibilityLabel("Deck")
                    if case .cached(let asOf, _) = listing.freshness {
                        Text("Deck list saved \(asOf.formatted(date: .abbreviated, time: .shortened)).")
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
        } header: {
            Text("Deck")
                .foregroundStyle(Theme.muted)
        }
        .listRowBackground(Theme.surface)
    }

    private var deckSelection: Binding<Int?> {
        Binding(
            get: { model.selectedDeckID },
            set: { id in
                if let id {
                    Task { await model.select(deckID: id) }
                }
            }
        )
    }

    private var placementSection: some View {
        Section {
            Picker("Slot", selection: $model.slot) {
                ForEach(DeckSlot.allCases, id: \.self) { slot in
                    Text(slot.title).tag(slot)
                }
            }
            .accessibilityLabel("Slot")
            Stepper(value: $model.quantity, in: AddToDeckModel.quantityRange) {
                HStack {
                    Text("Copies in \(model.slot.title)")
                    Spacer()
                    Text(model.quantity.formatted())
                        .monospacedDigit()
                        .foregroundStyle(Theme.amber)
                }
            }
            .accessibilityLabel("Copies in \(model.slot.title)")
            .accessibilityValue(model.quantity.formatted())
        } header: {
            Text("Placement")
                .foregroundStyle(Theme.muted)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                switch model.selectedDeck {
                case .loading:
                    Text("Checking what the deck holds…")
                case .loaded:
                    Text(model.existingQuantity > 0
                         ? "The deck has \(model.existingQuantity) in \(model.slot.title); the number above is the new total."
                         : "The deck has none in \(model.slot.title) yet.")
                case .failed(let error):
                    Text("Couldn't read the deck: \(error.message)")
                case .idle:
                    EmptyView()
                }
                Text("The slot is pre-filled from the card's type; Signature cards go to the main deck.")
            }
            .foregroundStyle(Theme.muted)
        }
        .listRowBackground(Theme.surface)
    }

    @ViewBuilder
    private var actionSection: some View {
        Section {
            switch model.submission {
            case .loaded(let deck):
                Label {
                    Text("Added. \(deck.name) now has \(model.quantity) × \(model.card.name) in \(model.slot.title).")
                        .font(.footnote)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.green)
                }
                .accessibilityElement(children: .combine)
            case .failed(let error):
                Label(error.message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
                submitButton
            case .loading:
                ProgressView("Adding…")
            case .idle:
                submitButton
            }
        }
        .listRowBackground(Theme.surface)
    }

    private var submitButton: some View {
        Button {
            Task { await model.submit() }
        } label: {
            Label(isAdded ? "Add again" : "Add to deck", systemImage: "plus.rectangle.on.rectangle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.amber)
        .disabled(!model.canSubmit)
        .accessibilityHint(model.offlineMessage ?? "Sends the change to the server")
    }
}
