import SwiftUI

struct RootView: View {
    let dependencies: AppDependencies
    @State private var scanner: ScannerModel
    @State private var history: HistoryModel
    @State private var collection: CollectionModel
    @State private var decks: DecksModel
    @State private var settings: SettingsModel
    private let deckDependencies: DeckDependencies

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        _scanner = State(wrappedValue: ScannerModel(
            camera: dependencies.camera,
            feeder: dependencies.makeFeeder(),
            identifier: dependencies.identifier,
            store: dependencies.store,
            makeBatch: dependencies.makeBatch,
            now: dependencies.now,
            makeID: dependencies.makeID
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
            index: dependencies.index
        ))
    }

    var body: some View {
        TabView {
            Tab("Scan", systemImage: "camera.viewfinder") {
                NavigationStack {
                    ScannerView(model: scanner, session: dependencies.camera.session, directory: dependencies.directory)
                        .toolbarVisibility(.hidden, for: .navigationBar)
                        .reviewDestinations(store: dependencies.store, directory: dependencies.directory)
                }
            }
            Tab("Collection", systemImage: "square.grid.2x2") {
                NavigationStack {
                    CollectionView(model: collection)
                }
                .environment(\.deckDependencies, deckDependencies)
            }
            Tab("Decks", systemImage: "rectangle.stack") {
                NavigationStack {
                    DecksView(model: decks, dependencies: deckDependencies)
                }
            }
            Tab("History", systemImage: "list.bullet.rectangle") {
                NavigationStack {
                    HistoryView(model: history, store: dependencies.store, directory: dependencies.directory, index: dependencies.index)
                }
            }
            Tab("Settings", systemImage: "gearshape") {
                NavigationStack {
                    SettingsView(model: settings)
                }
            }
        }
    }
}
