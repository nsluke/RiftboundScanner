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
    #if os(macOS)
    @State private var cameraSource: CameraSourceModel
    @State private var serverBatches: ServerBatchesModel
    @State private var remotePreview: RemotePreviewModel
    #endif
    private let deckDependencies: DeckDependencies

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        _scanner = State(wrappedValue: ScannerModel(
            camera: dependencies.scannerCamera,
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
        _collection = State(wrappedValue: CollectionModel(
            catalog: dependencies.catalog,
            holdings: dependencies.holdings,
            prices: dependencies.prices,
            pending: dependencies.pending,
            endpoints: dependencies.endpoints,
            directory: dependencies.directory,
            seed: dependencies.vault,
            now: dependencies.now
        ))
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
        #if os(macOS)
        _cameraSource = State(wrappedValue: dependencies.platform.makeCameraSource())
        _serverBatches = State(wrappedValue: dependencies.platform.makeServerBatches())
        _remotePreview = State(wrappedValue: dependencies.platform.makeRemotePreview())
        #endif
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Scan", systemImage: "camera.viewfinder", value: RootTab.scan) {
                NavigationStack {
                    scannerView
                        .hiddenNavigationBar()
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
                    HistoryView(model: history, serverBatches: serverBatchesForHistory, store: dependencies.store, directory: dependencies.directory, vault: dependencies.vault, index: dependencies.index, rule: dependencies.confidenceRule)
                }
            }
            Tab("Settings", systemImage: "gearshape", value: RootTab.settings) {
                NavigationStack {
                    SettingsView(model: settings)
                }
            }
        }
        #if os(macOS)
        .tabViewStyle(.sidebarAdaptable)
        #endif
        .environment(sync)
        .task { await sync.start() }
        #if os(macOS)
        // The iPhone app's frames can be read once, so the root reads them for good.
        .task { await remotePreview.run() }
        #endif
        .onChange(of: tab, initial: true) { sync.isScanTabVisible = tab == .scan }
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .active: Task { await sync.appDidBecomeActive() }
            case .inactive, .background: sync.appDidResignActive()
            @unknown default: break
            }
        }
    }

    /// The server's batches for History to import; only the Mac offers them.
    private var serverBatchesForHistory: ServerBatchesModel? {
        #if os(macOS)
        serverBatches
        #else
        nil
        #endif
    }

    /// The Scan tab's screen; the Mac's also takes the camera picker.
    private var scannerView: ScannerView {
        let makeStartRun = {
            StartRunModel(memory: dependencies.runSetup, sets: dependencies.directory.sets, index: dependencies.index, appVersion: dependencies.appVersion)
        }
        #if os(macOS)
        return ScannerView(model: scanner, session: dependencies.camera.session, directory: dependencies.directory, makeStartRun: makeStartRun, cameraSource: cameraSource, remotePreview: remotePreview)
        #else
        return ScannerView(model: scanner, session: dependencies.camera.session, directory: dependencies.directory, makeStartRun: makeStartRun, makeCameraForMac: dependencies.platform.makeCameraForMac)
        #endif
    }
}
