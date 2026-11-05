import CoreGraphics
import Foundation
import RiftboundRecognizer

/// Why a scan could not be completed, in words the screen can show.
nonisolated enum ScanProblem: Error, Hashable {
    case camera(String)
    case decoding
    case recognition(String)
    case storage(String)

    init(_ error: any Error) {
        switch error {
        case let problem as ScanProblem: self = problem
        case let cameraError as CameraError: self = .camera(cameraError.message)
        case is PhotoDecoder.Failure: self = .decoding
        default: self = .recognition(String(describing: error))
        }
    }

    var message: String {
        switch self {
        case .camera(let detail): detail
        case .decoding: String(localized: "The photo could not be decoded.")
        case .recognition(let detail): String(localized: "Recognition failed. \(detail)")
        case .storage(let detail): String(localized: "The scan could not be saved. \(detail)")
        }
    }
}

/// Drives one batch of scans: camera, recogniser, review, store, and the card
/// feeder that can run them in a loop.
@Observable
final class ScannerModel {
    /// The feed-and-scan loop. Exactly one of these holds at a time, so the
    /// screen shows either nothing, a live count, or one ending with its reason.
    enum AutoScan: Hashable {
        case off
        case running(fed: Int)
        case ended(fed: Int, reason: AutoScanEnd)
    }

    enum AutoScanEnd: Hashable {
        case stoppedByUser
        /// The feeder stopped reporting cards; it says nothing when empty.
        case hopperEmpty
        case feederFailed(FeederError)
        case scanFailed(ScanProblem)

        var message: String {
            switch self {
            case .stoppedByUser: String(localized: "Stopped.")
            case .hopperEmpty: String(localized: "The hopper looks empty.")
            case .feederFailed(let error): error.message
            case .scanFailed(let problem): problem.message
            }
        }
    }

    enum CameraState: Hashable {
        case unknown
        case starting
        case ready
        case denied
        case unavailable(String)
    }

    enum Phase {
        case idle
        case capturing
        case recognizing(CGImage)
        case reviewing(PendingScan)
        case failed(ScanProblem)
    }

    /// A scan awaiting the user's verdict; nothing is written until they give one.
    struct PendingScan: Identifiable {
        let record: ScanRecord
        let photo: CGImage
        let rectified: CGImage
        let photoData: Data
        let rectifiedData: Data

        var id: ScanRecord.ID { record.id }
    }

    private(set) var cameraState: CameraState = .unknown
    private(set) var phase: Phase = .idle
    private(set) var batch: ScanBatch?
    /// This batch's records, oldest first.
    private(set) var records: [ScanRecord] = []
    private(set) var isTorchOn = false
    /// Increments whenever a verdict is saved; the view uses it to trigger haptics.
    private(set) var savedVerdictCount = 0
    private(set) var storageProblem: ScanProblem?
    private(set) var autoScan: AutoScan = .off
    /// Owned here so leaving the screen or stopping cancels the loop; tests await it.
    private(set) var autoScanTask: Task<Void, Never>?

    let feeder: any FeederControlling
    private let camera: any CameraOperating
    private let identifier: any CardIdentifying
    private let store: any ScanStoring
    private let makeBatch: @Sendable (_ label: String) -> ScanBatch
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID
    /// How long a fed card gets to come to rest before the photo.
    private let settleDelay: Duration
    private let clock = ContinuousClock()

    init(
        camera: any CameraOperating,
        feeder: any FeederControlling,
        identifier: any CardIdentifying,
        store: any ScanStoring,
        makeBatch: @escaping @Sendable (_ label: String) -> ScanBatch,
        now: @escaping @Sendable () -> Date,
        makeID: @escaping @Sendable () -> UUID,
        settleDelay: Duration = .milliseconds(350)
    ) {
        self.camera = camera
        self.feeder = feeder
        self.identifier = identifier
        self.store = store
        self.makeBatch = makeBatch
        self.now = now
        self.makeID = makeID
        self.settleDelay = settleDelay
    }

    var pendingScan: PendingScan? {
        if case .reviewing(let pending) = phase { return pending }
        return nil
    }

    var problem: ScanProblem? {
        if case .failed(let problem) = phase { return problem }
        return nil
    }

    var isBusy: Bool {
        switch phase {
        case .capturing, .recognizing: true
        case .idle, .reviewing, .failed: false
        }
    }

    var isAutoScanning: Bool {
        if case .running = autoScan { return true }
        return false
    }

    /// The feeder is ready and nothing else is using the camera.
    var canStartAutoScan: Bool {
        guard case .idle = phase, cameraState == .ready, batch != nil, feeder.state.isReady else { return false }
        switch autoScan {
        case .off, .ended: return true
        case .running: return false
        }
    }

    var summary: BatchSummary { BatchSummary(records: records) }

    // MARK: - Camera lifecycle

    /// Continues the latest batch (or starts one) and brings the camera up.
    func start() async {
        if batch == nil {
            await loadLatestBatch()
        }
        cameraState = .starting
        guard await camera.requestAccess() else {
            cameraState = .denied
            return
        }
        do {
            try await camera.start()
            cameraState = .ready
        } catch {
            cameraState = .unavailable(ScanProblem(error).message)
        }
    }

    func stopCamera() {
        stopAutoScan()
        isTorchOn = false
        if cameraState == .ready {
            cameraState = .unknown
        }
        // Bridges from a synchronous `onDisappear`; the engine finishes on its own queue.
        Task { await camera.stop() }
    }

    func toggleTorch() async {
        do {
            try await camera.setTorch(!isTorchOn)
            isTorchOn.toggle()
        } catch {
            phase = .failed(ScanProblem(error))
        }
    }

    // MARK: - Scanning

    func capture() async {
        guard case .idle = phase, cameraState == .ready, batch != nil, !isAutoScanning else { return }
        do {
            phase = .reviewing(try await captureScan())
        } catch {
            phase = .failed(ScanProblem(error))
        }
    }

    /// Photographs and identifies one card, moving `phase` through capturing
    /// and recognizing on the way. Throws with the phase left where it failed;
    /// the caller decides how to surface that.
    private func captureScan() async throws -> PendingScan {
        guard let batch else { throw ScanProblem.camera(String(localized: "No batch is open.")) }
        phase = .capturing
        let encoded = try await camera.capturePhoto()
        let photo = try await PhotoDecoder.decode(encoded, maxPixelSize: 2048)
        phase = .recognizing(photo)
        let started = clock.now
        let result = try await identifier.identify(photo)
        let elapsed = clock.now - started
        let photoData = try await PhotoDecoder.encodeJPEG(photo, quality: 0.85)
        let rectifiedData = try await PhotoDecoder.encodeJPEG(result.rectifiedCard, quality: 0.8)
        let id = ScanRecord.ID(rawValue: makeID())
        let record = ScanRecord(
            id: id,
            batchID: batch.id,
            capturedAt: now(),
            photoFileName: "photos/\(id.rawValue.uuidString).jpg",
            rectifiedFileName: "rectified/\(id.rawValue.uuidString).jpg",
            processingSeconds: elapsed.seconds,
            placement: Placement(result.location),
            codeReading: result.codeReading.map(CodeReadingSummary.init),
            candidates: result.matches.prefix(5).map(Candidate.init)
        )
        return PendingScan(record: record, photo: photo, rectified: result.rectifiedCard, photoData: photoData, rectifiedData: rectifiedData)
    }

    // MARK: - Feeder

    func connectFeeder() {
        feeder.connect()
    }

    func disconnectFeeder() {
        stopAutoScan()
        feeder.disconnect()
    }

    /// Feeds, photographs and saves cards (verdict pending) until the user
    /// stops, the hopper runs dry, or something fails.
    func startAutoScan() {
        guard canStartAutoScan else { return }
        autoScan = .running(fed: 0)
        autoScanTask = Task { await runAutoScan() }
    }

    func stopAutoScan() {
        autoScanTask?.cancel()
    }

    func dismissAutoScanResult() {
        if case .ended = autoScan {
            autoScan = .off
        }
    }

    private func runAutoScan() async {
        var fed = 0
        let reason = await feedUntilDone(fed: &fed)
        feeder.stop()
        autoScan = .ended(fed: fed, reason: reason)
        phase = .idle
        autoScanTask = nil
    }

    private func feedUntilDone(fed: inout Int) async -> AutoScanEnd {
        while !Task.isCancelled {
            do {
                try await feeder.feedOneCard()
            } catch is CancellationError {
                return .stoppedByUser
            } catch FeederError.timedOut {
                return .hopperEmpty
            } catch let error as FeederError {
                return .feederFailed(error)
            } catch {
                return .feederFailed(.writeFailed(String(describing: error)))
            }
            fed += 1
            autoScan = .running(fed: fed)

            do {
                try await clock.sleep(for: settleDelay)
                let pending = try await captureScan()
                try Task.checkCancellation()
                try await store.append(pending.record, photo: pending.photoData, rectified: pending.rectifiedData)
                records.append(pending.record)
            } catch is CancellationError {
                return .stoppedByUser
            } catch let error as ScanStoreError {
                return .scanFailed(.storage(String(describing: error)))
            } catch {
                return .scanFailed(ScanProblem(error))
            }
        }
        return .stoppedByUser
    }

    /// Saves the pending scan with the user's verdict.
    func resolve(_ verdict: Verdict) async {
        guard case .reviewing(let pending) = phase else { return }
        var record = pending.record
        record.verdict = verdict
        record.verdictAt = now()
        do {
            try await store.append(record, photo: pending.photoData, rectified: pending.rectifiedData)
            records.append(record)
            savedVerdictCount += 1
            phase = .idle
        } catch {
            storageProblem = .storage(String(describing: error))
        }
    }

    /// Drops the pending scan without saving it.
    func retake() {
        if case .reviewing = phase {
            phase = .idle
        }
    }

    func dismissProblem() {
        if case .failed = phase {
            phase = .idle
        }
    }

    func dismissStorageProblem() {
        storageProblem = nil
    }

    // MARK: - Batches

    func beginNewBatch(label: String) async {
        do {
            try await createBatch(label: label.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            storageProblem = .storage(String(describing: error))
        }
    }

    private func loadLatestBatch() async {
        do {
            if let latest = try await store.batches().first {
                batch = latest
                records = try await store.records(in: latest.id)
            } else {
                try await createBatch(label: "")
            }
        } catch {
            storageProblem = .storage(String(describing: error))
        }
    }

    private func createBatch(label: String) async throws {
        let created = makeBatch(label)
        try await store.save(created)
        batch = created
        records = []
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
