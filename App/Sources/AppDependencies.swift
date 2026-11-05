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
    let index: IndexSummary
    let makeBatch: @Sendable (_ label: String) -> ScanBatch
    let now: @Sendable () -> Date
    let makeID: @Sendable () -> UUID

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
        let documents = URL.documentsDirectory
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let device = ScanBatch.Device.current(appVersion: appVersion)
        let now: @Sendable () -> Date = { Date() }
        let makeID: @Sendable () -> UUID = { UUID() }
        return AppDependencies(
            camera: CaptureEngine(),
            makeFeeder: { CSC100Feeder() },
            identifier: LiveCardIdentifier(recognizer: CardRecognizer.live(index: cardIndex)),
            store: FileScanStore(root: documents.appending(path: "Scans", directoryHint: .isDirectory)),
            directory: CardDirectory(index: cardIndex),
            index: summary,
            makeBatch: { label in
                ScanBatch(id: ScanBatch.ID(rawValue: makeID()), startedAt: now(), label: label, device: device, index: summary)
            },
            now: now,
            makeID: makeID
        )
    }
}

nonisolated enum BootstrapError: Error, Hashable {
    case indexMissing
    case indexUnreadable(String)

    var message: String {
        switch self {
        case .indexMissing:
            String(localized: "The app was built without index.json. Run `swift run -c release riftscan build-index`, then rebuild.")
        case .indexUnreadable(let detail):
            String(localized: "The bundled card index could not be read. \(detail)")
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
