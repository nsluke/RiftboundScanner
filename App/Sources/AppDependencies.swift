import Foundation
import RiftboundRecognizer

/// Everything the app needs, wired once at launch. This is the only place that
/// names concrete types; every model receives its collaborators through `init`.
nonisolated struct AppDependencies: Sendable {
    let camera: CaptureEngine
    /// Built on the main actor by the root view: the live driver is a main-actor
    /// object whose CoreBluetooth callbacks land there.
    let makeFeeder: @MainActor @Sendable () -> any FeederControlling
    let identifier: any CardIdentifying
    let store: any ScanStoring
    let directory: CardDirectory
    /// The bundled `CardVault.json`: the catalog seed and the ledger builder's
    /// finish rules. The Collection shows the server's catalog once fetched.
    let vault: CardVault
    /// The Collection tab's three server-backed sources and its view of the
    /// outbox (ADR-002 §6), each caching under `paths.catalog`.
    let catalog: any CatalogSourcing
    let holdings: any HoldingsSourcing
    let prices: any PriceQuoting
    let pending: any PendingLedgerProviding
    let index: IndexSummary
    let makeBatch: @Sendable (ScanBatch.Setup) -> ScanBatch
    let now: @Sendable () -> Date
    let makeID: @Sendable () -> UUID
    /// `Library/Application Support/Riftbound`, prepared and excluded from backup.
    let paths: AppPaths
    let settings: any ServerSettingsStoring
    let endpoints: any EndpointResolving
    let client: any CollectionServing
    /// The Decks tab's offline copy, under `paths.catalog`.
    let deckCache: any DeckCacheStoring
    let appVersion: String
    /// The confident tier in force, read at each use. Built-in defaults until
    /// the learning sync (A8) installs a downloaded policy and the server's
    /// audit count.
    let confidenceRule: @Sendable () -> ConfidenceRule
    /// The last start-run sheet's choice, remembered for the next run.
    let runSetup: any RunSetupStoring
    /// Cards added by hand, under `paths.sync/manual.json`.
    let manualItems: ManualItemStore
    /// Built on the main actor by the root view (the feeder pattern): the
    /// engine is main-actor state and cannot be constructed inside `live()`.
    let makeSyncEngine: @MainActor @Sendable () -> SyncEngine
    /// What only one platform has: on the Mac, the camera picker.
    let platform: PlatformDependencies

    /// The production graph. Runs off the main actor: decoding the 6 MB index
    /// takes long enough to count as a hang.
    @concurrent
    static func live() async throws(BootstrapError) -> AppDependencies {
        guard let indexURL = Bundle.main.url(forResource: "index", withExtension: "json") else {
            throw .indexMissing
        }
        let cardIndex: CardIndex
        do {
            cardIndex = try CardIndex.read(from: indexURL)
        } catch {
            throw .indexUnreadable(String(describing: error))
        }
        let summary = IndexSummary(builtAt: cardIndex.builtAt, entryCount: cardIndex.entries.count, formatVersion: cardIndex.formatVersion)
        // Calibrates Vision's feature printer (one feature print of the
        // calibration canvas) so every result carries the engine fingerprint.
        let recognizer: CardRecognizer
        do {
            recognizer = try await CardRecognizer.live(index: cardIndex)
        } catch {
            throw .recognizerUncalibrated(String(describing: error))
        }
        let vault: CardVault
        if let vaultURL = Bundle.main.url(forResource: "CardVault", withExtension: "json") {
            vault = (try? await CardVault.read(from: vaultURL)) ?? .empty
        } else {
            vault = .empty
        }
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let device = ScanBatch.Device.current(appVersion: appVersion)
        let now: @Sendable () -> Date = { Date() }
        let makeID: @Sendable () -> UUID = { UUID() }
        let paths: AppPaths
        do {
            paths = try AppPaths.live.prepare()
        } catch {
            throw .storageUnavailable(String(describing: error))
        }
        let settings = DefaultsServerSettingsStore(defaults: .standard, secrets: KeychainSecretStore())
        let pathSource = LiveNetworkPathSource()
        let endpoints = EndpointResolver(
            candidates: { await settings.load().candidates },
            probe: URLSessionEndpointProbe(),
            paths: pathSource,
            clock: ContinuousClock(),
            now: now
        )
        let client = HTTPCollectionClient(
            endpoints: endpoints,
            token: { await settings.load().token },
            clientIdentity: HTTPCollectionClient.clientIdentity(appVersion: appVersion, device: device),
            cache: ResponseCache(directory: paths.catalog.appending(path: "responses", directoryHint: .isDirectory))
        )
        // One store seam: the file store under Documents, wrapped so every
        // decision also updates sync.json beside it (ADR-002, decision 4).
        let store = SyncingScanStore(
            inner: FileScanStore(root: AppPaths.scans, now: now, makeID: makeID),
            directory: paths.sync,
            now: now
        )
        let outbox = Outbox(fileURL: paths.sync.appending(path: "outbox.json"))
        let manualItems = ManualItemStore(fileURL: paths.sync.appending(path: "manual.json"))
        // The sizes assets are shrunk to; a policy value here, not a literal
        // in the uploader (ADR-002, principle 4).
        let assetEncoding = AssetEncodingPolicy()
        let camera = CaptureEngine()
        return AppDependencies(
            camera: camera,
            makeFeeder: { CSC100Feeder() },
            identifier: LiveCardIdentifier(recognizer: recognizer),
            store: store,
            directory: CardDirectory(index: cardIndex),
            vault: vault,
            catalog: ServerCatalogSource(client: client, seed: vault, url: paths.catalog.appending(path: "catalog.json"), now: now),
            holdings: ServerHoldingsSource(client: client, url: paths.catalog.appending(path: "holdings.json"), now: now),
            prices: ServerPriceSource(client: client, url: paths.catalog.appending(path: "prices.json"), now: now),
            pending: OutboxPendingLedger(outbox: outbox, store: store),
            index: summary,
            makeBatch: { setup in
                ScanBatch(
                    id: ScanBatch.ID(rawValue: makeID()),
                    startedAt: now(),
                    label: setup.label,
                    device: device,
                    index: summary,
                    purpose: setup.purpose,
                    product: setup.product,
                    defaultFinish: setup.defaultFinish,
                    // Guide crops at full resolution: new batches may train.
                    trainingQuality: .standard
                )
            },
            now: now,
            makeID: makeID,
            paths: paths,
            settings: settings,
            endpoints: endpoints,
            client: client,
            deckCache: FileDeckCacheStore(url: paths.catalog.appending(path: "decks.json")),
            appVersion: appVersion,
            confidenceRule: { .default },
            runSetup: DefaultsRunSetupStore(defaults: .standard),
            manualItems: manualItems,
            makeSyncEngine: {
                SyncEngine(
                    store: store,
                    outbox: outbox,
                    manual: manualItems,
                    client: client,
                    endpoints: endpoints,
                    paths: pathSource,
                    vault: vault,
                    device: device.model,
                    uploads: RecordUploadComposer(),
                    assets: StoredAssetProvider(store: store, policy: assetEncoding),
                    now: now
                )
            },
            platform: .live(camera: camera)
        )
    }
}

#if os(macOS)
/// The Mac's own collaborators. The camera picker discovers Continuity Camera
/// iPhones and other cameras and points the shared engine at the chosen one.
nonisolated struct PlatformDependencies: Sendable {
    /// Built on the main actor by the root view, like the feeder.
    let makeCameraSource: @MainActor @Sendable () -> CameraSourceModel

    static func live(camera: CaptureEngine) -> PlatformDependencies {
        PlatformDependencies {
            CameraSourceModel(
                discovery: LiveCameraDiscovery(),
                camera: camera,
                preferences: DefaultsCameraPreferenceStore(defaults: .standard)
            )
        }
    }
}
#else
/// The iPhone has nothing beyond the shared graph: one back camera, no picker.
nonisolated struct PlatformDependencies: Sendable {
    static func live(camera: CaptureEngine) -> PlatformDependencies {
        PlatformDependencies()
    }
}
#endif

nonisolated enum BootstrapError: Error, Hashable {
    case indexMissing
    case indexUnreadable(String)
    case recognizerUncalibrated(String)
    case storageUnavailable(String)

    var message: String {
        switch self {
        case .indexMissing:
            String(localized: "The app was built without index.json. Run `swift run -c release riftscan build-index`, then rebuild.")
        case .indexUnreadable(let detail):
            String(localized: "The bundled card index could not be read. \(detail)")
        case .recognizerUncalibrated(let detail):
            String(localized: "The recogniser could not calibrate this device's image model. \(detail)")
        case .storageUnavailable(let detail):
            String(localized: "The app's storage folder could not be created. \(detail)")
        }
    }
}

/// What the app knows about the index it shipped with; recorded on every batch
/// so results can be traced to the index that produced them.
nonisolated struct IndexSummary: Hashable, Sendable, Codable {
    let builtAt: Date
    let entryCount: Int
    let formatVersion: Int
}
