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
    let vault: CardVault
    let priceSource: any PriceQuoting
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
        let documents = URL.documentsDirectory
        let caches = URL.cachesDirectory
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
        let endpoints = EndpointResolver(
            candidates: { await settings.load().candidates },
            probe: URLSessionEndpointProbe(),
            paths: LiveNetworkPathSource(),
            clock: ContinuousClock(),
            now: now
        )
        let client = HTTPCollectionClient(
            endpoints: endpoints,
            token: { await settings.load().token },
            clientIdentity: HTTPCollectionClient.clientIdentity(appVersion: appVersion, device: device),
            cache: ResponseCache(directory: paths.catalog.appending(path: "responses", directoryHint: .isDirectory))
        )
        return AppDependencies(
            camera: CaptureEngine(),
            makeFeeder: { CSC100Feeder() },
            identifier: LiveCardIdentifier(recognizer: recognizer),
            store: FileScanStore(root: documents.appending(path: "Scans", directoryHint: .isDirectory), now: now, makeID: makeID),
            directory: CardDirectory(index: cardIndex),
            vault: vault,
            priceSource: TCGCSVPriceSource(cacheURL: caches.appending(path: "tcgcsv-prices.json"), now: now),
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
            confidenceRule: { .default }
        )
    }
}

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
