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
    /// The feed-and-scan run. Exactly one of these holds at a time, so the
    /// screen shows nothing, live counts, the queue finishing after feeding has
    /// stopped, or one ending with its reason.
    enum AutoScan: Hashable {
        case off
        case running(AutoScanProgress)
        /// Feeding has stopped for `reason`; captured photos are still being identified.
        case draining(AutoScanProgress, reason: AutoScanEnd)
        case ended(AutoScanProgress, reason: AutoScanEnd)

        var progress: AutoScanProgress? {
            switch self {
            case .off: nil
            case .running(let progress), .draining(let progress, _), .ended(let progress, _): progress
            }
        }
    }

    struct AutoScanProgress: Hashable {
        /// Cards the feeder has advanced and the camera has photographed.
        var fed = 0
        /// Photos the recogniser has finished and the store has saved.
        var identified = 0
    }

    enum AutoScanEnd: Hashable {
        case stoppedByUser
        /// The feeder stopped reporting cards; it says nothing when empty.
        case hopperEmpty
        case feederFailed(FeederError)
        case scanFailed(ScanProblem)
        /// The camera in use (on the Mac, the iPhone) went away mid-run.
        case cameraDisconnected(String)

        var message: String {
            switch self {
            case .stoppedByUser: String(localized: "Stopped.")
            case .hopperEmpty: String(localized: "The hopper looks empty.")
            case .feederFailed(let error): error.message
            case .scanFailed(let problem): problem.message
            case .cameraDisconnected(let name): String(localized: "\(name) disconnected, so feeding stopped.")
            }
        }
    }

    enum CameraState: Hashable {
        case unknown
        case starting
        case ready
        case denied
        /// No camera is connected; on the iPhone, no back camera exists.
        case noCamera
        /// The camera in use went away; the Mac waits for it to come back.
        case disconnected(String)
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
    /// Records saved by the current or latest run, oldest first; what the
    /// run-complete strip shows.
    private(set) var runRecords: [ScanRecord] = []
    /// Increments when confident scans are accepted in bulk; for haptics.
    private(set) var acceptedCount = 0
    /// The whole run: feeding and identification. Finishes once the queue has
    /// drained; tests await it.
    private(set) var autoScanTask: Task<Void, Never>?
    /// The feeding half of the run, owned apart from the whole so stopping can
    /// cancel feeding at once while queued photos finish identifying.
    private var feedTask: Task<AutoScanEnd, Never>?
    /// Why feeding was cancelled from outside, when it was not the user.
    private var requestedStop: AutoScanEnd?
    /// Where the card sits in the preview, as the view last measured it.
    /// Captures are cropped to it before recognition; without it the whole
    /// photo is used.
    var guideCrop: GuideCrop?

    let feeder: any FeederControlling
    /// The bundled vault, for the printings a scan could be ledgered as.
    let vault: CardVault
    /// Every printing the index knows, for telling visible siblings from invisible ones.
    let directory: CardDirectory
    private let camera: any CameraOperating
    private let identifier: any CardIdentifying
    private let store: any ScanStoring
    private let makeBatch: @Sendable (ScanBatch.Setup) -> ScanBatch
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID
    /// The confident tier as currently installed; read at each use so a
    /// policy downloaded mid-session applies to the next run.
    private let confidenceRule: @Sendable () -> ConfidenceRule
    /// Catches a card fed twice in one run (ADR-002, decision 16).
    private let duplicateGuard: DuplicateGuard
    /// How long a fed card gets to come to rest before the photo.
    private let settleDelay: Duration
    private let clock = ContinuousClock()

    init(
        camera: any CameraOperating,
        feeder: any FeederControlling,
        identifier: any CardIdentifying,
        store: any ScanStoring,
        vault: CardVault,
        directory: CardDirectory,
        makeBatch: @escaping @Sendable (ScanBatch.Setup) -> ScanBatch,
        now: @escaping @Sendable () -> Date,
        makeID: @escaping @Sendable () -> UUID,
        confidenceRule: @escaping @Sendable () -> ConfidenceRule = { .default },
        duplicateGuard: DuplicateGuard = .standard,
        settleDelay: Duration = .milliseconds(350)
    ) {
        self.camera = camera
        self.feeder = feeder
        self.identifier = identifier
        self.store = store
        self.vault = vault
        self.directory = directory
        self.makeBatch = makeBatch
        self.now = now
        self.makeID = makeID
        self.confidenceRule = confidenceRule
        self.duplicateGuard = duplicateGuard
        self.settleDelay = settleDelay
    }

    /// The confident tier's thresholds in force right now.
    var rule: ConfidenceRule { confidenceRule() }

    /// How many accepted scans "Spot-check 10" re-checks.
    static let spotCheckLimit = 10

    /// This run's scans that were accepted without a look, newest first; what
    /// "Spot-check 10" draws from.
    var spotCheckCandidates: [ScanRecord.ID] {
        runRecords.filter { $0.lastDecision?.source == .autoAccepted }.map(\.id)
    }

    /// The five-tier reading of a pending scan in the current batch under the
    /// installed rule; `nil` once decided or without a batch.
    func tier(of record: ScanRecord) -> ScanTier? {
        guard let batch else { return nil }
        return record.tier(under: confidenceRule(), in: batch, vault: vault, directory: directory)
    }

    /// This run's scans counted per tier, plus how many are held for audit
    /// and how many are already decided; what the run-complete strip shows.
    var runTierCounts: TierCounts {
        TierCounts(records: batch == nil ? [] : runRecords, rule: confidenceRule(), batch: batch, vault: vault, directory: directory)
    }

    /// The hint the recogniser gets for this batch: a sealed box names its set.
    var recognitionHints: RecognitionHints {
        RecognitionHints(expectedSet: batch?.product?.expectedSet)
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

    /// True while the run is in progress, feeding or still draining.
    var isAutoScanning: Bool {
        switch autoScan {
        case .running, .draining: true
        case .off, .ended: false
        }
    }

    /// The feeder is ready and nothing else is using the camera.
    var canStartAutoScan: Bool {
        guard case .idle = phase, cameraState == .ready, batch != nil, feeder.state.isReady else { return false }
        switch autoScan {
        case .off, .ended: return true
        case .running, .draining: return false
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
        } catch CameraError.noCamera {
            cameraState = .noCamera
        } catch {
            cameraState = .unavailable(ScanProblem(error).message)
        }
    }

    /// Follows the Mac's camera picker (`CameraSourceModel`). The camera comes
    /// up once one is in use. When the camera in use goes away, feeding stops
    /// at once, because every later photo would miss the card, and the screen
    /// waits for it; photos already taken are still identified. A refused
    /// permission stays on screen whatever the cameras do.
    func follow(_ source: CameraSource) async {
        // The batch is there to browse and review whatever the camera does.
        if batch == nil {
            await loadLatestBatch()
        }
        switch source {
        case .searching:
            if cameraState != .denied {
                cameraState = .starting
            }
        case .using:
            await start()
        case .none:
            await cameraWentAway(.noCamera, reason: .cameraDisconnected(String(localized: "The camera")))
        case .lost(let device):
            await cameraWentAway(.disconnected(device.name), reason: .cameraDisconnected(device.name))
        }
    }

    private func cameraWentAway(_ state: CameraState, reason: AutoScanEnd) async {
        // Only feeding can be stopped; a run that is draining already has its reason.
        if case .running = autoScan {
            stopAutoScan(because: reason)
        }
        isTorchOn = false
        if cameraState != .denied {
            cameraState = state
        }
        await camera.stop()
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
            let (captured, image) = try await capturePhoto()
            phase = .recognizing(image)
            let identified = try await identify(captured, decoded: image)
            phase = .reviewing(PendingScan(
                record: identified.record,
                photo: image,
                rectified: identified.rectified,
                photoData: captured.jpeg,
                rectifiedData: identified.rectifiedData
            ))
        } catch {
            phase = .failed(ScanProblem(error))
        }
    }

    /// A photo that has been taken and cropped but not yet identified. Holds
    /// the encoded JPEG, not the bitmap, so a queue of these stays small.
    struct CapturedPhoto: Sendable {
        let id: ScanRecord.ID
        let batchID: ScanBatch.ID
        let capturedAt: Date
        let jpeg: Data
        var crop: CropDebug? = nil
        /// What the batch already knows about the card (ADR-002, decision 14).
        var hints: RecognitionHints = .none
    }

    /// What identification adds to a captured photo.
    nonisolated struct IdentifiedScan: Sendable {
        let record: ScanRecord
        let rectified: CGImage
        let rectifiedData: Data
    }

    /// Photographs the card, crops to the guide and encodes the result. Moves
    /// `phase` to capturing and leaves it there; the caller moves on.
    private func capturePhoto() async throws -> (CapturedPhoto, CGImage) {
        guard let batch else { throw ScanProblem.camera(String(localized: "No batch is open.")) }
        phase = .capturing
        let encoded = try await camera.capturePhoto()
        // With a crop the full photo is decoded so the card keeps its pixels;
        // the recogniser downsamples what it is given.
        let decoded = try await PhotoDecoder.decode(encoded, maxPixelSize: guideCrop == nil ? 2048 : 4096)
        var image = decoded
        var cropDebug: CropDebug?
        if let guideCrop {
            let pixelRect = guideCrop.pixelRect(forPhotoSize: CGSize(width: decoded.width, height: decoded.height))
            cropDebug = CropDebug(crop: guideCrop, photoWidth: decoded.width, photoHeight: decoded.height, pixelRect: pixelRect)
            image = decoded.cropping(to: pixelRect) ?? decoded
        }
        let jpeg = try await PhotoDecoder.encodeJPEG(image, quality: 0.85)
        let captured = CapturedPhoto(id: ScanRecord.ID(rawValue: makeID()), batchID: batch.id, capturedAt: now(), jpeg: jpeg, crop: cropDebug, hints: recognitionHints)
        return (captured, image)
    }

    /// Runs the recogniser on a captured photo, off the main actor: this is the
    /// second-long step the auto-scan pipeline overlaps with feeding.
    @concurrent
    nonisolated private func identify(_ captured: CapturedPhoto, decoded: CGImage? = nil) async throws -> IdentifiedScan {
        let photo: CGImage
        if let decoded {
            photo = decoded
        } else {
            photo = try await PhotoDecoder.decode(captured.jpeg, maxPixelSize: 4096)
        }
        let started = clock.now
        let identified = try await identifier.identify(photo, hints: captured.hints)
        let result = identified.result
        let elapsed = clock.now - started
        let rectifiedData = try await PhotoDecoder.encodeJPEG(result.rectifiedCard, quality: 0.8)
        let record = ScanRecord(
            id: captured.id,
            batchID: captured.batchID,
            capturedAt: captured.capturedAt,
            photoFileName: "photos/\(captured.id.rawValue.uuidString).jpg",
            rectifiedFileName: "rectified/\(captured.id.rawValue.uuidString).jpg",
            processingSeconds: elapsed.seconds,
            placement: Placement(result.location),
            codeReading: result.codeReading.map(CodeReadingSummary.init),
            candidates: result.matches.prefix(5).map(Candidate.init),
            crop: captured.crop,
            analysis: ScanAnalysis(result, at: now()),
            engine: identified.engine,
            captureQuality: CaptureQuality(crop: captured.crop, photoSize: PixelSize(width: photo.width, height: photo.height))
        )
        return IdentifiedScan(record: record, rectified: result.rectifiedCard, rectifiedData: rectifiedData)
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
    /// stops, the hopper runs dry, or something fails. Feeding and
    /// identification run as two halves joined by a queue, so the feeder never
    /// waits for the recogniser.
    func startAutoScan() {
        guard canStartAutoScan else { return }
        runRecords = []
        requestedStop = nil
        autoScan = .running(AutoScanProgress())
        let (queue, enqueue) = AsyncStream<CapturedPhoto>.makeStream(bufferingPolicy: .unbounded)
        autoScanTask = Task { await runAutoScan(queue: queue, enqueue: enqueue) }
    }

    /// Stops feeding at once. Photos already taken still get identified and
    /// saved; the run reports ended once they have.
    func stopAutoScan() {
        feedTask?.cancel()
    }

    private func stopAutoScan(because reason: AutoScanEnd) {
        requestedStop = reason
        feedTask?.cancel()
    }

    func dismissAutoScanResult() {
        if case .ended = autoScan {
            autoScan = .off
        }
    }

    func photoURL(for record: ScanRecord) -> URL {
        store.photoURL(for: record)
    }

    /// Records an `autoAccepted` correct decision for each of this run's
    /// confident-tier scans that is still pending on disk and not held for
    /// audit. The batch is re-read first, so a scan someone judged on another
    /// screen since the run is left alone; the other tiers (needs a look,
    /// pick printing, possible duplicate, unknown) and the audit sample stay
    /// pending for the review queue (ADR-002, decisions 9, 13 and 16).
    func acceptConfidentScans() async {
        guard let batch else { return }
        let rule = confidenceRule()
        do {
            let onDisk = try await store.records(in: batch.id)
            let runIDs = Set(runRecords.map(\.id))
            let eligible = onDisk.filter { runIDs.contains($0.id) && $0.isAcceptable(under: rule, in: batch, vault: vault, directory: directory) }
            guard !eligible.isEmpty else { return }
            var accepted: [ScanRecord.ID: ScanRecord] = [:]
            for record in eligible {
                accepted[record.id] = try await store.decide(record.id, in: batch.id, DecisionInput(.correct, source: .autoAccepted))
            }
            records = records.map { accepted[$0.id] ?? $0 }
            runRecords = runRecords.map { accepted[$0.id] ?? $0 }
            acceptedCount += accepted.count
        } catch {
            storageProblem = .storage(String(describing: error))
        }
    }

    private func runAutoScan(queue: AsyncStream<CapturedPhoto>, enqueue: AsyncStream<CapturedPhoto>.Continuation) async {
        // Two owned tasks rather than one group: stopping must cancel feeding
        // alone and let the identification half drain, which a group's shared
        // cancellation cannot express.
        let feeding = Task { await feedUntilDone(enqueue: enqueue) }
        feedTask = feeding
        let identifying = Task { await identifyQueued(queue) }

        var reason = await feeding.value
        if let requestedStop {
            reason = requestedStop
            self.requestedStop = nil
        }
        enqueue.finish()
        feeder.stop()
        feedTask = nil
        if let progress = autoScan.progress {
            autoScan = .draining(progress, reason: reason)
        }

        if let failure = await identifying.value {
            reason = failure
        }
        autoScan = .ended(autoScan.progress ?? AutoScanProgress(), reason: reason)
        phase = .idle
        autoScanTask = nil
    }

    private func feedUntilDone(enqueue: AsyncStream<CapturedPhoto>.Continuation) async -> AutoScanEnd {
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

            do {
                try await clock.sleep(for: settleDelay)
                let (captured, _) = try await capturePhoto()
                phase = .idle
                enqueue.yield(captured)
                advanceProgress { $0.fed += 1 }
            } catch is CancellationError {
                phase = .idle
                return .stoppedByUser
            } catch {
                phase = .idle
                return .scanFailed(ScanProblem(error))
            }
        }
        return .stoppedByUser
    }

    /// Identifies and saves queued photos one at a time. On a failure it stops
    /// feeding and discards whatever is still queued: once the recogniser or
    /// the store is broken, more photos would only fail the same way.
    private func identifyQueued(_ queue: AsyncStream<CapturedPhoto>) async -> AutoScanEnd? {
        for await captured in queue {
            do {
                let identified = try await identify(captured)
                // A card fed twice is caught here, against this run's latest
                // scans, before anything is saved (ADR-002, decision 16).
                let record = duplicateGuard.marking(identified.record, among: runRecords)
                try await store.append(record, photo: captured.jpeg, rectified: identified.rectifiedData)
                records.append(record)
                runRecords.append(record)
                advanceProgress { $0.identified += 1 }
            } catch {
                feedTask?.cancel()
                let problem: ScanProblem = error is ScanStoreError ? .storage(String(describing: error)) : ScanProblem(error)
                return .scanFailed(problem)
            }
        }
        return nil
    }

    private func advanceProgress(_ change: (inout AutoScanProgress) -> Void) {
        switch autoScan {
        case .running(var progress):
            change(&progress)
            autoScan = .running(progress)
        case .draining(var progress, let reason):
            change(&progress)
            autoScan = .draining(progress, reason: reason)
        case .off, .ended:
            break
        }
    }

    /// Saves the pending scan, then records the user's verdict as a `human`
    /// decision through the store, the one path every verdict takes.
    func resolve(_ verdict: Verdict) async {
        guard case .reviewing(let pending) = phase else { return }
        do {
            try await store.append(pending.record, photo: pending.photoData, rectified: pending.rectifiedData)
            let decided = try await store.decide(pending.record.id, in: pending.record.batchID, DecisionInput(verdict, source: .human))
            records.append(decided)
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

    /// Starts a calibration batch: until the start-run sheet asks what a
    /// batch is for, nothing scanned reaches the ledger.
    func beginNewBatch(label: String) async {
        await beginNewBatch(.calibration(label: label))
    }

    func beginNewBatch(_ setup: ScanBatch.Setup) async {
        var setup = setup
        setup.label = setup.label.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await createBatch(setup)
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
                try await createBatch(.calibration(label: ""))
            }
        } catch {
            storageProblem = .storage(String(describing: error))
        }
    }

    private func createBatch(_ setup: ScanBatch.Setup) async throws {
        let created = makeBatch(setup)
        try await store.save(created)
        batch = created
        records = []
    }
}

nonisolated extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
