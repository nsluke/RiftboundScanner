import Foundation
import RiftboundRecognizer
import SwiftUI

/// What the last start-run sheet chose, minus the label (which names one
/// sitting). Remembered so the next box takes one tap.
nonisolated struct RunSetupMemory: Hashable, Sendable, Codable {
    var purpose: BatchPurpose
    var product: BatchProduct?
    var defaultFinish: Finish?

    init(purpose: BatchPurpose, product: BatchProduct?, defaultFinish: Finish?) {
        self.purpose = purpose
        self.product = product
        self.defaultFinish = defaultFinish
    }

    init(_ setup: ScanBatch.Setup) {
        self.init(purpose: setup.purpose, product: setup.product, defaultFinish: setup.defaultFinish)
    }
}

/// Where the last run setup lives: defaults in the app, memory in tests.
nonisolated protocol RunSetupStoring: Sendable {
    func load() async -> RunSetupMemory?
    func save(_ memory: RunSetupMemory) async throws
}

actor DefaultsRunSetupStore: RunSetupStoring {
    static let key = "scanner.lastRunSetup"

    private let defaults: UserDefaults

    /// `UserDefaults` is thread-safe but not `Sendable`; the instance is
    /// handed over and owned by this actor from then on.
    init(defaults: sending UserDefaults) {
        self.defaults = defaults
    }

    func load() -> RunSetupMemory? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(RunSetupMemory.self, from: data)
    }

    func save(_ memory: RunSetupMemory) throws {
        defaults.set(try JSONEncoder().encode(memory), forKey: Self.key)
    }
}

/// The start-run sheet's fields (ADR-002 §6): label, purpose, product and
/// default finish, pre-filled from the last run. `setup` is what
/// `ScannerModel.beginNewBatch(_:)` receives.
@Observable
final class StartRunModel {
    enum ProductKind: Hashable, CaseIterable, Sendable {
        case sealedBox
        case loose
        case other

        var label: String {
            switch self {
            case .sealedBox: String(localized: "Sealed box")
            case .loose: String(localized: "Loose cards")
            case .other: String(localized: "Other")
            }
        }
    }

    var label = ""
    var purpose: BatchPurpose = .collection
    var productKind: ProductKind = .sealedBox
    var set: SetCode
    var otherProductName = ""
    var defaultFinish: Finish = .normal
    /// Whether the fields hold the remembered choice yet.
    private(set) var isLoaded = false
    private(set) var saveProblem: String?

    /// The sets the index knows, for the sealed-box picker.
    let sets: [SetCode]
    /// One line about the engine this run will use.
    let engineLine: String

    private let memory: any RunSetupStoring

    init(memory: any RunSetupStoring, sets: [SetCode], index: IndexSummary, appVersion: String) {
        self.memory = memory
        self.sets = sets
        set = sets.first ?? SetCode(rawValue: "OGN")!
        engineLine = String(localized: "Index of \(index.entryCount) printings, built \(index.builtAt.formatted(date: .abbreviated, time: .omitted)) · app \(appVersion)")
    }

    /// Fills the fields from the remembered setup, when there is one.
    func load() async {
        if let remembered = await memory.load() {
            apply(remembered)
        }
        isLoaded = true
    }

    private func apply(_ remembered: RunSetupMemory) {
        purpose = remembered.purpose
        switch remembered.product {
        case .sealedBox(let rememberedSet):
            productKind = .sealedBox
            if sets.isEmpty || sets.contains(rememberedSet) {
                set = rememberedSet
            }
        case .loose:
            productKind = .loose
        case .other(let name):
            productKind = .other
            otherProductName = name
        case nil:
            productKind = .loose
        }
        defaultFinish = remembered.defaultFinish ?? .normal
    }

    var product: BatchProduct {
        switch productKind {
        case .sealedBox: .sealedBox(set: set)
        case .loose: .loose
        case .other: .other(otherProductName.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// What the new batch is started with.
    var setup: ScanBatch.Setup {
        ScanBatch.Setup(label: label.trimmingCharacters(in: .whitespacesAndNewlines), purpose: purpose, product: product, defaultFinish: defaultFinish)
    }

    /// The label the batch gets when none is typed.
    var suggestedLabel: String {
        switch productKind {
        case .sealedBox: String(localized: "\(set.rawValue) box")
        case .loose: String(localized: "Loose cards")
        case .other: otherProductName.isEmpty ? String(localized: "Run") : otherProductName
        }
    }

    var canStart: Bool {
        productKind != .other || !otherProductName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Remembers the choice, then hands the setup to `begin`. A failure to
    /// remember is reported but never stops the run.
    func start(_ begin: (ScanBatch.Setup) async -> Void) async {
        var setup = setup
        if setup.label.isEmpty {
            setup.label = suggestedLabel
        }
        do {
            try await memory.save(RunSetupMemory(setup))
        } catch {
            saveProblem = String(describing: error)
        }
        await begin(setup)
    }
}

/// Starts a sitting: what it is for, what is being opened and the finish
/// both-finish printings take (ADR-002 §6). Every field is remembered for
/// the next run except the label.
struct StartRunSheet: View {
    @State private var model: StartRunModel
    let onStart: (ScanBatch.Setup) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isStarting = false

    init(model: @autoclosure @escaping () -> StartRunModel, onStart: @escaping (ScanBatch.Setup) async -> Void) {
        _model = State(wrappedValue: model())
        self.onStart = onStart
    }

    var body: some View {
        NavigationStack {
            Form {
                if !model.isLoaded {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Loading the last run's settings")
                } else {
                    fields
                }
            }
            .navigationTitle("Start run")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        isStarting = true
                        Task {
                            await model.start(onStart)
                            dismiss()
                        }
                    }
                    .disabled(!model.canStart || isStarting || !model.isLoaded)
                    .accessibilityHint("Starts a new batch with these settings")
                }
            }
            .task { await model.load() }
        }
    }

    @ViewBuilder
    private var fields: some View {
        Section {
            TextField(model.suggestedLabel, text: $model.label)
                .accessibilityLabel("Batch label")
        } header: {
            Text("Label")
        } footer: {
            Text("Left blank, the batch is named after the product.")
        }

        Section {
            Picker("Purpose", selection: $model.purpose) {
                Text("Collection").tag(BatchPurpose.collection)
                Text("Calibration").tag(BatchPurpose.calibration)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Purpose")
        } footer: {
            Text(model.purpose == .collection
                 ? "Confirmed cards are added to your collection on the server."
                 : "A test sitting. Nothing reaches the collection, and nothing trains the recogniser.")
        }

        Section("Product") {
            Picker("Product", selection: $model.productKind) {
                ForEach(StartRunModel.ProductKind.allCases, id: \.self) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.menu)
            switch model.productKind {
            case .sealedBox:
                Picker("Set", selection: $model.set) {
                    ForEach(model.sets, id: \.self) { set in
                        Text(set.rawValue).tag(set)
                    }
                }
                .accessibilityHint("The recogniser expects every card to be from this set; promo printings are folded away")
            case .other:
                TextField("What is being scanned", text: $model.otherProductName)
                    .accessibilityLabel("Product name")
            case .loose:
                EmptyView()
            }
        }

        Section {
            Picker("Default finish", selection: $model.defaultFinish) {
                Text("Normal").tag(Finish.normal)
                Text("Foil").tag(Finish.foil)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Default finish")
        } footer: {
            Text("Printings that come in both finishes take this one unless you change it while reviewing. Single-finish printings are recorded as they come.")
        }

        Section {
            Text(model.engineLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Engine: \(model.engineLine)")
        }
        if let problem = model.saveProblem {
            Section {
                Label("The choice could not be remembered: \(problem)", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }
}
