import SwiftUI

struct RootView: View {
    /// Which tab is showing; the sync engine's periodic flush runs on Scan.
    enum RootTab: Hashable {
        case scan, collection, decks, history, settings
    }

    let dependencies: AppDependencies
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: RootTab = .scan
    @State private var scanner: ScannerModel
    @State private var history: HistoryModel
    @State private var collection: CollectionModel
    @State private var decks: DecksModel
    @State private var settings: SettingsModel
    @State private var sync: SyncEngine
    private let deckDependencies: DeckDependencies

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        _scanner = State(wrappedValue: ScannerModel(
            camera: dependencies.camera,
            feeder: dependencies.makeFeeder(),
            identifier: dependencies.identifier,
            store: dependencies.store,
            vault: dependencies.vault,
            directory: dependencies.directory,
            makeBatch: dependencies.makeBatch,
            now: dependencies.now,
            makeID: dependencies.makeID,
            confidenceRule: dependencies.confidenceRule
        ))
        _history = State(wrappedValue: HistoryModel(store: dependencies.store))
        _collection = State(wrappedValue: CollectionModel(store: dependencies.store, directory: dependencies.directory, vault: dependencies.vault, priceSource: dependencies.priceSource))
        deckDependencies = DeckDependencies(client: dependencies.client, endpoints: dependencies.endpoints, cache: dependencies.deckCache, now: dependencies.now)
        _decks = State(wrappedValue: DecksModel(client: dependencies.client, cache: dependencies.deckCache, now: dependencies.now))
        _settings = State(wrappedValue: SettingsModel(
            settingsStore: dependencies.settings,
            client: dependencies.client,
            endpoints: dependencies.endpoints,
            paths: dependencies.paths,
            appVersion: dependencies.appVersion,
            index: dependencies.index,
            confidenceRule: dependencies.confidenceRule
        ))
        _sync = State(wrappedValue: dependencies.makeSyncEngine())
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Scan", systemImage: "camera.viewfinder", value: RootTab.scan) {
                NavigationStack {
                    ScannerView(
                        model: scanner,
                        session: dependencies.camera.session,
                        directory: dependencies.directory,
                        makeStartRun: {
                            StartRunModel(memory: dependencies.runSetup, sets: dependencies.directory.sets, index: dependencies.index, appVersion: dependencies.appVersion)
                        }
                    )
                    .toolbarVisibility(.hidden, for: .navigationBar)
                    .reviewDestinations(store: dependencies.store, directory: dependencies.directory, vault: dependencies.vault, rule: dependencies.confidenceRule)
                }
            }
            Tab("Collection", systemImage: "square.grid.2x2", value: RootTab.collection) {
                NavigationStack {
                    CollectionView(model: collection) {
                        AddCardModel(vault: dependencies.vault, store: dependencies.manualItems, now: dependencies.now, makeID: dependencies.makeID)
                    }
                }
                .environment(\.deckDependencies, deckDependencies)
            }
            Tab("Decks", systemImage: "rectangle.stack", value: RootTab.decks) {
                NavigationStack {
                    DecksView(model: decks, dependencies: deckDependencies)
                }
            }
            Tab("History", systemImage: "list.bullet.rectangle", value: RootTab.history) {
                NavigationStack {
                    HistoryView(model: history, store: dependencies.store, directory: dependencies.directory, vault: dependencies.vault, index: dependencies.index, rule: dependencies.confidenceRule)
                }
            }
            Tab("Settings", systemImage: "gearshape", value: RootTab.settings) {
                NavigationStack {
                    SettingsView(model: settings)
                }
            }
        }
        .environment(sync)
        .task { await sync.start() }
        .onChange(of: tab, initial: true) { sync.isScanTabVisible = tab == .scan }
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .active: Task { await sync.appDidBecomeActive() }
            case .inactive, .background: sync.appDidResignActive()
            @unknown default: break
            }
        }
    }
}
