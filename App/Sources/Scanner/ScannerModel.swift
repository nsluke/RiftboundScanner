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

/// Drives one batch of scans: camera, recogniser, review, store.
@Observable
final class ScannerModel {
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

    private let camera: any CameraOperating
    private let identifier: any CardIdentifying
    private let store: any ScanStoring
    private let makeBatch: @Sendable (_ label: String) -> ScanBatch
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID
    private let clock = ContinuousClock()

    init(
        camera: any CameraOperating,
        identifier: any CardIdentifying,
        store: any ScanStoring,
        makeBatch: @escaping @Sendable (_ label: String) -> ScanBatch,
        now: @escaping @Sendable () -> Date,
        makeID: @escaping @Sendable () -> UUID
    ) {
        self.camera = camera
        self.identifier = identifier
        self.store = store
        self.makeBatch = makeBatch
        self.now = now
        self.makeID = makeID
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
        guard case .idle = phase, cameraState == .ready, let batch else { return }
        phase = .capturing
        do {
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
            phase = .reviewing(PendingScan(record: record, photo: photo, rectified: result.rectifiedCard, photoData: photoData, rectifiedData: rectifiedData))
        } catch {
            phase = .failed(ScanProblem(error))
        }
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
