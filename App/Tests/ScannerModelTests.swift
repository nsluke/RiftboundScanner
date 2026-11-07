import CoreGraphics
import Foundation
import RiftboundRecognizer
import Testing
@testable import RiftboundScannerApp

@Suite("Scanner model")
struct ScannerModelTests {
    private let recordID = UUID()

    private func makeModel(
        camera: StubCamera = StubCamera(),
        feeder: StubFeeder = StubFeeder(),
        identifier: any CardIdentifying = StubIdentifier(outcome: .success(Fixtures.result(cards: [Fixtures.vi, Fixtures.jinx]))),
        store: InMemoryScanStore = InMemoryScanStore()
    ) -> ScannerModel {
        ScannerModel(
            camera: camera,
            feeder: feeder,
            identifier: identifier,
            store: store,
            vault: Fixtures.vault,
            directory: Fixtures.directory,
            makeBatch: Fixtures.makeBatch,
            now: { Fixtures.epoch },
            makeID: { recordID }
        )
    }

    @Test func startCreatesABatchAndReadiesTheCamera() async {
        let model = makeModel()
        await model.start()
        #expect(model.batch != nil)
        #expect(model.cameraState == .ready)
        #expect(model.records.isEmpty)
    }

    @Test func deniedCameraIsAState() async {
        let model = makeModel(camera: StubCamera(access: false))
        await model.start()
        #expect(model.cameraState == .denied)
    }

    @Test func captureProducesAPendingScanWithRankedCandidates() async throws {
        let model = makeModel()
        await model.start()
        await model.capture()
        let pending = try #require(model.pendingScan)
        #expect(pending.record.candidates.map(\.card.id) == [Fixtures.vi.id, Fixtures.jinx.id])
        #expect(pending.record.verdict == .pending)
        #expect(pending.record.decisions.isEmpty)
        #expect(pending.record.id == ScanRecord.ID(rawValue: recordID))
        #expect(pending.record.placement == .detected(confidence: 0.95))
        #expect(pending.record.engine == Fixtures.engineStamp)
        let analysis = try #require(pending.record.analysis)
        #expect(analysis.descriptor == Fixtures.descriptor)
        #expect(analysis.shortlist.map(\.cardID) == [Fixtures.vi.id, Fixtures.jinx.id])
        #expect(analysis.quad != nil)
        #expect(analysis.codeSource == nil, "the fixture result reads no code")
        #expect(analysis.codeAlternatives.isEmpty)
        #expect(pending.record.captureQuality == .legacy, "an uncropped 63x88 photo cannot train")
        #expect(model.isBusy == false)
    }

    @Test func captureCropsToTheGuideAndKeepsTheCropAsThePhoto() async throws {
        // A 63×88 fixture photo in a preview of the same aspect; the guide covers
        // the middle half of each axis, and the 15 % margin grows it to 65 %.
        let model = makeModel(camera: StubCamera(photo: try ImageFile.encode(Fixtures.image(width: 630, height: 880), as: .jpeg(quality: 0.9))))
        model.guideCrop = GuideCrop(
            guideFrame: CGRect(x: 78.75, y: 110, width: 157.5, height: 220),
            previewFrame: CGRect(x: 0, y: 0, width: 315, height: 440)
        )
        await model.start()
        await model.capture()
        let pending = try #require(model.pendingScan)
        #expect(pending.photo.width == 410)
        #expect(pending.photo.height == 572)
        let saved = try await PhotoDecoder.decode(pending.photoData, maxPixelSize: 4096)
        #expect(saved.width == 410)
        #expect(saved.height == 572)
    }

    @Test func captureWithoutAGuideUsesTheWholePhoto() async throws {
        let model = makeModel()
        await model.start()
        await model.capture()
        let pending = try #require(model.pendingScan)
        #expect(pending.photo.width == 63)
        #expect(pending.photo.height == 88)
    }

    @Test func resolvingPersistsTheRecordWithItsVerdict() async throws {
        let store = InMemoryScanStore()
        let model = makeModel(store: store)
        await model.start()
        await model.capture()
        await model.resolve(.corrected(Fixtures.jinx.id))

        let batch = try #require(model.batch)
        let stored = await store.records(in: batch.id)
        #expect(stored.count == 1)
        #expect(stored.first?.verdict == .corrected(Fixtures.jinx.id))
        #expect(stored.first?.verdictAt == Fixtures.epoch)
        #expect(stored.first?.decisions.map(\.source) == [.human])
        #expect(stored.first?.confirmedCardID == Fixtures.jinx.id)
        #expect(model.records.first?.decisions.count == 1)
        #expect(await store.photos[ScanRecord.ID(rawValue: recordID)] != nil)
        #expect(model.pendingScan == nil)
        #expect(model.records.count == 1)
        #expect(model.savedVerdictCount == 1)
    }

    @Test func retakeDropsThePendingScan() async throws {
        let store = InMemoryScanStore()
        let model = makeModel(store: store)
        await model.start()
        await model.capture()
        model.retake()
        #expect(model.pendingScan == nil)
        let batchID = try #require(model.batch?.id)
        #expect(await store.records(in: batchID).isEmpty)
    }

    @Test func recognitionFailureIsReportedAndRecoverable() async {
        let model = makeModel(identifier: StubIdentifier(outcome: .failure(StubFailure())))
        await model.start()
        await model.capture()
        #expect(model.problem != nil)
        model.dismissProblem()
        #expect(model.problem == nil)
        #expect(model.pendingScan == nil)
    }

    @Test func newBatchReplacesTheCurrentOne() async {
        let model = makeModel()
        await model.start()
        let first = model.batch?.id
        await model.beginNewBatch(label: "lamp")
        #expect(model.batch?.id != first)
        #expect(model.batch?.label == "lamp")
        #expect(model.batch?.purpose == .calibration, "a batch started without the run sheet ledgers nothing")

        await model.beginNewBatch(ScanBatch.Setup(label: " box 1 ", purpose: .collection, product: .sealedBox(set: SetCode(rawValue: "OGN")!), defaultFinish: .normal))
        #expect(model.batch?.label == "box 1")
        #expect(model.batch?.purpose == .collection)
        #expect(model.batch?.product?.expectedSet?.rawValue == "OGN")
        #expect(model.batch?.defaultFinish == .normal)
    }

    @Test func modelDeallocates() async {
        weak var weakModel: ScannerModel?
        do {
            let model = makeModel()
            weakModel = model
            await model.start()
            await model.capture()
        }
        #expect(weakModel == nil, "ScannerModel leaked; check task and closure captures")
    }
}

/// What the run tells the recogniser (ADR-002, decision 14).
@Suite("Scanner model hints")
struct ScannerModelHintTests {
    private func makeModel(identifier: SequenceIdentifier) -> ScannerModel {
        ScannerModel(
            camera: StubCamera(),
            feeder: StubFeeder(script: [.fed]),
            identifier: identifier,
            store: InMemoryScanStore(),
            vault: Fixtures.vault,
            directory: Fixtures.directory,
            makeBatch: Fixtures.makeBatch,
            now: { Fixtures.epoch },
            makeID: Fixtures.unsampledIDs,
            settleDelay: .zero
        )
    }

    @Test func aSealedBoxBatchPassesItsSetAsTheExpectedSet() async throws {
        let identifier = SequenceIdentifier(results: [Fixtures.result(cards: [Fixtures.vi, Fixtures.jinx])])
        let model = makeModel(identifier: identifier)
        await model.start()
        await model.beginNewBatch(ScanBatch.Setup(label: "box", purpose: .collection, product: .sealedBox(set: SetCode(rawValue: "OGN")!), defaultFinish: .normal))
        #expect(model.recognitionHints == RecognitionHints(expectedSet: SetCode(rawValue: "OGN")!))

        await model.capture()
        #expect(await identifier.hints == [RecognitionHints(expectedSet: SetCode(rawValue: "OGN")!)], "the single-shot path hints too")
        model.retake()

        model.connectFeeder()
        model.startAutoScan()
        await model.autoScanTask?.value
        #expect(await identifier.hints.count == 2)
        #expect(await identifier.hints.last == RecognitionHints(expectedSet: SetCode(rawValue: "OGN")!), "and so does the feeder run")
    }

    @Test func aLoosePileOrACalibrationBatchHintsNothing() async throws {
        let identifier = SequenceIdentifier(results: [Fixtures.result(cards: [Fixtures.vi, Fixtures.jinx])])
        let model = makeModel(identifier: identifier)
        await model.start()
        #expect(model.batch?.purpose == .calibration)
        #expect(model.recognitionHints == .none)
        await model.capture()
        model.retake()
        await model.beginNewBatch(ScanBatch.Setup(label: "pile", purpose: .collection, product: .loose, defaultFinish: .normal))
        #expect(model.recognitionHints == .none)
        await model.capture()
        #expect(await identifier.hints == [.none, .none])
    }
}
