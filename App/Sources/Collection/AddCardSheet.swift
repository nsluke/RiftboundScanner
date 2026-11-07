import Foundation
import SwiftUI

/// Adds a card by hand: find the printing in the vault, pick the finish when
/// it comes in both, say how many, and one `manual:<id>` ledger item is
/// queued (ADR-002, decision 13). The item is the only truth here; the
/// collection count updates when the server has applied it.
@Observable
final class AddCardModel {
    var query = "" {
        didSet { search() }
    }
    private(set) var results: [VaultCard] = []
    private(set) var selected: VaultCard?
    /// The finish to send; `nil` lets the server derive it.
    var finish: Finish?
    var quantity = 1
    /// The last add: idle until the button, loading while writing, then the
    /// item queued or why it was not.
    private(set) var outcome: Loadable<ManualItem, ScanProblem> = .idle

    let vault: CardVault
    private let store: ManualItemStore
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID

    static let resultLimit = 40

    init(vault: CardVault, store: ManualItemStore, now: @escaping @Sendable () -> Date, makeID: @escaping @Sendable () -> UUID) {
        self.vault = vault
        self.store = store
        self.now = now
        self.makeID = makeID
    }

    /// How the selected printing gets its finish; `unknown` with nothing selected.
    var finishResolution: FinishPolicy.Resolution {
        FinishPolicy.resolve(card: selected, batchDefault: .normal)
    }

    var canAdd: Bool {
        if case .loading = outcome { return false }
        return selected != nil && quantity > 0
    }

    var isAdding: Bool {
        if case .loading = outcome { return true }
        return false
    }

    func select(_ card: VaultCard) {
        selected = card
        finish = finishResolution.preselectedFinish
        outcome = .idle
    }

    func clearSelection() {
        selected = nil
        finish = nil
        outcome = .idle
    }

    /// Queues one item for the selection. Returns it, or `nil` when nothing
    /// was selected or the write failed (`outcome` says why).
    @discardableResult
    func add() async -> ManualItem? {
        guard let selected, quantity > 0 else { return nil }
        outcome = .loading
        let item = ManualItem(
            id: makeID(),
            cardKey: selected.key.rawValue,
            finish: finishResolution.asksUser ? finish : finishResolution.preselectedFinish,
            quantity: quantity,
            createdAt: now()
        )
        do {
            try await store.add(item)
            outcome = .loaded(item)
            return item
        } catch {
            outcome = .failed(.storage(String(describing: error)))
            return nil
        }
    }

    private func search() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            return
        }
        let needle = trimmed.replacingOccurrences(of: " ", with: "-")
        results = Array(vault.cards.lazy.filter { card in
            card.name.localizedCaseInsensitiveContains(trimmed) || card.code.localizedCaseInsensitiveContains(needle)
        }.prefix(Self.resultLimit))
    }
}

struct AddCardSheet: View {
    @State private var model: AddCardModel
    /// Called once an item is queued, so the collection can nudge the sync engine.
    let onAdded: (ManualItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(SyncEngine.self) private var sync: SyncEngine?

    init(model: @autoclosure @escaping () -> AddCardModel, onAdded: @escaping (ManualItem) -> Void) {
        _model = State(wrappedValue: model())
        self.onAdded = onAdded
    }

    var body: some View {
        NavigationStack {
            Form {
                if let selected = model.selected {
                    selection(selected)
                } else {
                    search
                }
                recent
            }
            .navigationTitle("Add card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var search: some View {
        Section {
            TextField("Name or code, e.g. OGN-066-P", text: $model.query)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .accessibilityLabel("Search the catalog")
        } footer: {
            Text("Every printing in the catalog, promos included.")
        }
        if !model.results.isEmpty {
            Section("Printings") {
                ForEach(model.results) { card in
                    Button {
                        model.select(card)
                    } label: {
                        row(card)
                    }
                    .tint(.primary)
                    .accessibilityHint("Selects this printing")
                }
            }
        } else if !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            Section {
                Text("No printing matches “\(model.query)”.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func selection(_ card: VaultCard) -> some View {
        Section {
            row(card)
            Button("Choose another") { model.clearSelection() }
                .font(.footnote)
        }
        Section {
            if model.finishResolution.asksUser {
                Picker("Finish", selection: finishBinding) {
                    Text("Normal").tag(Finish.normal)
                    Text("Foil").tag(Finish.foil)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Finish")
            } else if let forced = model.finishResolution.preselectedFinish {
                LabeledContent("Finish", value: forced.label)
            }
            Stepper(value: $model.quantity, in: 1...99) {
                LabeledContent("Quantity", value: "\(model.quantity)")
            }
            .accessibilityLabel("Quantity, \(model.quantity)")
        } footer: {
            if case .unknown = model.finishResolution {
                Text("The catalog does not say which finishes this printing comes in; the server decides unless you pick one.")
            }
        }
        Section {
            Button {
                Task {
                    if let item = await model.add() {
                        onAdded(item)
                        await sync?.flush()
                    }
                }
            } label: {
                HStack {
                    Text(model.quantity == 1 ? "Add 1 card" : "Add \(model.quantity) cards")
                    Spacer()
                    if model.isAdding {
                        ProgressView()
                    }
                }
            }
            .disabled(!model.canAdd)
            .accessibilityHint("Queues the add for the collection server")
            switch model.outcome {
            case .loaded(let item):
                Label("Queued \(item.quantity) × \(item.cardKey). It appears in the collection once the server has it.", systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .failed(let problem):
                Label(problem.message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            case .idle, .loading:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var recent: some View {
        if let items = sync?.manualItems, !items.isEmpty {
            Section("Recent adds") {
                ForEach(items.prefix(10)) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(item.quantity) × \(item.cardKey)\(item.finish.map { " · \($0.label.lowercased())" } ?? "")")
                                .font(.subheadline)
                            Text(stateLabel(item.state))
                                .font(.caption)
                                .foregroundStyle(stateNeedsAttention(item.state) ? .orange : .secondary)
                        }
                        Spacer()
                        Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func row(_ card: VaultCard) -> some View {
        HStack(spacing: 12) {
            CardArtView(url: card.image, size: CGSize(width: 40, height: 56))
            VStack(alignment: .leading, spacing: 2) {
                Text(card.name)
                Text("\(card.code) · \(card.setName) · \(card.rarity)\(card.promo ? " · promo" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var finishBinding: Binding<Finish> {
        Binding(get: { model.finish ?? .normal }, set: { model.finish = $0 })
    }

    private func stateLabel(_ state: LedgerItemState) -> String {
        switch state {
        case .queued: String(localized: "Waiting to send")
        case .sent: String(localized: "Sent, awaiting the server")
        case .applied: String(localized: "In the collection")
        case .terminal(let status): status.message
        }
    }

    private func stateNeedsAttention(_ state: LedgerItemState) -> Bool {
        if case .terminal(let status) = state { return status.needsAttention }
        return false
    }
}
