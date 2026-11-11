import Foundation
import RiftboundRecognizer
import Testing
@testable import RiftboundScannerApp

/// The server's scan archive, scripted: batches, records as a device uploads
/// them (`ScanUpload.record`, image URLs stripped) and JPEGs per scan.
actor StubScanArchive: ServerScanReading {
    private(set) var batches: [ServerScanBatch]
    private var order: [UUID] = []
    private var scans: [UUID: ServerScan] = [:]
    private var files: [UUID: [AssetKind: Data]] = [:]
    private(set) var scanFetches = 0
    /// Scan fetches after which the archive stops answering, like a dropped link.
    private var failsAfter: Int?

    init(batches: [ServerScanBatch] = []) {
        self.batches = batches
    }

    func add(_ record: ScanRecord, assets: [AssetKind: Data] = [:]) throws {
        try add(json: ScanUpload.record(from: record), id: record.id.rawValue, batch: record.batchID.rawValue, assets: assets)
    }

    func add(json: JSONValue, id: UUID, batch: UUID, assets: [AssetKind: Data]) {
        order.append(id)
        scans[id] = ServerScan(id: id, batchID: batch, record: json, assets: assets.keys.sorted { $0.rawValue < $1.rawValue }.map { ServerScan.Asset(kind: $0.rawValue, bytes: assets[$0]?.count) })
        files[id] = assets
    }

    func failAfter(_ fetches: Int?) {
        failsAfter = fetches
    }

    func scanBatches() throws(ServerError) -> [ServerScanBatch] {
        batches
    }

    func scanIDs(inBatch id: UUID) throws(ServerError) -> [UUID] {
        order.filter { scans[$0]?.batchID == id }
    }

    func scan(id: UUID) throws(ServerError) -> ServerScan {
        if let failsAfter, scanFetches >= failsAfter { throw .unreachable("link dropped") }
        scanFetches += 1
        guard let scan = scans[id] else { throw .notFound }
        return scan
    }

    func asset(_ kind: AssetKind, scanID: UUID) throws(ServerError) -> Data {
        guard let data = files[scanID]?[kind] else { throw .notFound }
        return data
    }
}

extension ServerScanBatch {
    /// What an iPhone's batch looks like on the server.
    static func iPhone(id: UUID = UUID(), purpose: String = "collection", product: String? = "sealedBox:OGN", defaultFinish: Finish? = .foil, scans: Int = 2, decided: Int = 0) -> ServerScanBatch {
        ServerScanBatch(id: id, startedAt: Fixtures.epoch, label: "Box 3", purpose: purpose, product: product, defaultFinish: defaultFinish, trainingQuality: "standard", deviceModel: "iPhone17,1", systemVersion: "26.1", appVersion: "0.2.0", scanCount: scans, decidedCount: decided)
    }
}

@Suite("Server batch import")
struct ServerBatchImportTests {
    private let index = IndexSummary(builtAt: Fixtures.epoch, entryCount: 4, formatVersion: 1)

    private func importer(_ archive: StubScanArchive, into store: any ScanStoring) -> ServerBatchImporter {
        ServerBatchImporter(server: archive, store: store, directory: Fixtures.directory, index: index)
    }

    @Test func importsEveryScanWithItsPhotoAndTheArtTheServerDropped() async throws {
        let remote = ServerScanBatch.iPhone()
        let batchID = ScanBatch.ID(rawValue: remote.id)
        let first = Fixtures.record(batch: batchID, capturedAt: Fixtures.epoch, codeRead: false)
        let second = Fixtures.record(batch: batchID, candidates: [Fixtures.jinx, Fixtures.vi], capturedAt: Fixtures.epoch.addingTimeInterval(1), codeRead: false)
        let archive = StubScanArchive(batches: [remote])
        try await archive.add(first, assets: [.photo: Data("photo-1".utf8), .canvas: Data("canvas-1".utf8)])
        try await archive.add(second, assets: [.photo: Data("photo-2".utf8)])
        #expect(try ScanUpload.record(from: first).containsString("https") == false, "the archive holds what the server holds: no image URLs")
        let store = InMemoryScanStore()

        let outcome = try await importer(archive, into: store).importBatch(remote)

        #expect(outcome.imported == 2)
        #expect(outcome.skipped.isEmpty)
        #expect(await store.records(in: batchID) == [first, second], "the cards' art URLs come back from this catalog")
        #expect(await store.photos[first.id] == Data("photo-1".utf8))
        #expect(await store.photos[second.id] == Data("photo-2".utf8))
    }

    @Test func theBatchKeepsItsPurposeProductAndFinish() async throws {
        let remote = ServerScanBatch.iPhone(scans: 0)
        let store = InMemoryScanStore()

        let outcome = try await importer(StubScanArchive(batches: [remote]), into: store).importBatch(remote)

        let batch = try #require(await store.batches().first)
        #expect(batch == outcome.batch)
        #expect(batch.id.rawValue == remote.id)
        #expect(batch.purpose == .collection)
        #expect(batch.product == .sealedBox(set: SetCode(rawValue: "OGN")!))
        #expect(batch.defaultFinish == .foil)
        #expect(batch.trainingQuality == .standard)
        #expect(batch.device == ScanBatch.Device(model: "iPhone17,1", systemVersion: "26.1", appVersion: "0.2.0"))
        #expect(batch.label == "Box 3")
        #expect(batch.index == index, "the server keeps no index summary; this device's stands in")
    }

    @Test func aScanWithOnlyThePreviewUsesItAndOneWithNoPhotoIsSkipped() async throws {
        let remote = ServerScanBatch.iPhone()
        let batchID = ScanBatch.ID(rawValue: remote.id)
        let decidedEarlier = Fixtures.record(batch: batchID, verdict: .correct, capturedAt: Fixtures.epoch)
        let bare = Fixtures.record(batch: batchID, capturedAt: Fixtures.epoch.addingTimeInterval(1))
        let archive = StubScanArchive(batches: [remote])
        try await archive.add(decidedEarlier, assets: [.photoSmall: Data("small".utf8)])
        try await archive.add(bare)
        let store = InMemoryScanStore()

        let outcome = try await importer(archive, into: store).importBatch(remote)

        #expect(outcome.imported == 1)
        #expect(outcome.skipped == [.noPhoto(bare.id.rawValue)])
        #expect(await store.photos[decidedEarlier.id] == Data("small".utf8))
        #expect(await store.records(in: batchID).first?.decisions.map(\.verdict) == [.correct], "decisions made on the iPhone come along")
    }

    @Test func anInterruptedImportResumesWithoutImportingTwice() async throws {
        let remote = ServerScanBatch.iPhone(scans: 3)
        let batchID = ScanBatch.ID(rawValue: remote.id)
        let records = (0..<3).map { Fixtures.record(batch: batchID, capturedAt: Fixtures.epoch.addingTimeInterval(TimeInterval($0)), codeRead: false) }
        let archive = StubScanArchive(batches: [remote])
        for record in records {
            try await archive.add(record, assets: [.photo: Data("p".utf8)])
        }
        let store = InMemoryScanStore()
        await archive.failAfter(1)

        await #expect(throws: ServerError.unreachable("link dropped")) {
            try await importer(archive, into: store).importBatch(remote)
        }
        #expect(await store.records(in: batchID).count == 1)

        await archive.failAfter(nil)
        let outcome = try await importer(archive, into: store).importBatch(remote)

        #expect(outcome.imported == 2)
        #expect(outcome.alreadyHere == 1)
        #expect(await store.records(in: batchID).map(\.id) == records.map(\.id))
    }

    @Test func aCardThisCatalogLacksStillImportsWithoutArt() async throws {
        let remote = ServerScanBatch.iPhone(scans: 1)
        let batchID = ScanBatch.ID(rawValue: remote.id)
        let stranger = Fixtures.card(id: "ven-001-200", code: "VEN-001/200", name: "Not Yet Released")
        let record = Fixtures.record(batch: batchID, candidates: [stranger, Fixtures.vi], codeRead: false)
        let archive = StubScanArchive(batches: [remote])
        try await archive.add(record, assets: [.photo: Data("p".utf8)])
        let store = InMemoryScanStore()

        _ = try await importer(archive, into: store).importBatch(remote)

        let imported = try #require(await store.records(in: batchID).first)
        #expect(imported.topCandidate?.card.id == stranger.id)
        #expect(imported.topCandidate?.card.imageURL.absoluteString == "about:blank")
        #expect(imported.candidates.last?.card.imageURL == Fixtures.vi.imageURL)
    }

    /// The scans came from the server, so the syncing store owes it nothing
    /// until a decision made here extends a log.
    @Test func theSyncingStoreRecordsThatTheServerAlreadyHoldsTheImport() async throws {
        let remote = ServerScanBatch.iPhone(scans: 1)
        let batchID = ScanBatch.ID(rawValue: remote.id)
        let record = Fixtures.record(batch: batchID, codeRead: false)
        let archive = StubScanArchive(batches: [remote])
        try await archive.add(record, assets: [.photo: Data("p".utf8), .photoSmall: Data("s".utf8)])
        let directory = URL.temporaryDirectory.appending(path: "ServerBatchImportTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SyncingScanStore(inner: InMemoryScanStore(), directory: directory, now: { Fixtures.epoch })

        _ = try await importer(archive, into: store).importBatch(remote)

        let state = await store.syncState(for: batchID)
        #expect(state.batchMeta.isUploaded)
        #expect(state[record.id].record.isUploaded)
        #expect(state[record.id].uploadedSeq == 0)
        #expect(state[record.id].photo.isUploaded)
        #expect(state[record.id].photoSmall.isUploaded)
        #expect(state[record.id].canvas == .notEligible)

        _ = try await store.decide(record.id, in: batchID, DecisionInput(.correct, source: .human))
        let decided = await store.syncState(for: batchID)[record.id]
        #expect(decided.record == .queued, "the decision made here goes back as the scan's next")
        #expect(decided.canvas == .queued)
    }

    @Test func aProductReadsBackFromItsWireSpelling() {
        for product in [BatchProduct.sealedBox(set: SetCode(rawValue: "UNL")!), .loose, .other("Promo pack")] {
            #expect(BatchProduct(wireDescription: product.wireDescription) == product)
        }
        #expect(BatchProduct(wireDescription: "mystery") == nil)
    }
}

@Suite("Server batches in History")
struct ServerBatchesModelTests {
    private func makeModel(_ archive: StubScanArchive, store: any ScanStoring = InMemoryScanStore()) -> ServerBatchesModel {
        ServerBatchesModel(server: archive, importer: ServerBatchImporter(server: archive, store: store, directory: Fixtures.directory, index: IndexSummary(builtAt: Fixtures.epoch, entryCount: 4, formatVersion: 1)))
    }

    @Test func listsOnlyBatchesWithScansThatAreNotHere() async {
        let here = ServerScanBatch.iPhone()
        let empty = ServerScanBatch.iPhone(scans: 0)
        let waiting = ServerScanBatch.iPhone(scans: 43)
        let model = makeModel(StubScanArchive(batches: [here, empty, waiting]))

        await model.load(excluding: [ScanBatch.ID(rawValue: here.id)])

        #expect(model.batches.value?.map(\.id) == [waiting.id])
        #expect(waiting.pendingCount == 43)
    }

    @Test func importingKeepsTheOutcomeForTheReviewThatFollows() async throws {
        let remote = ServerScanBatch.iPhone(scans: 1)
        let archive = StubScanArchive(batches: [remote])
        try await archive.add(Fixtures.record(batch: ScanBatch.ID(rawValue: remote.id), codeRead: false), assets: [.photo: Data("p".utf8)])
        let model = makeModel(archive)
        await model.load(excluding: [])

        let outcome = await model.importBatch(remote)

        #expect(outcome?.imported == 1)
        #expect(model.imports[remote.id] == outcome.map(ServerBatchesModel.ImportState.imported))
        await model.load(excluding: [ScanBatch.ID(rawValue: remote.id)])
        #expect(model.batches.value?.map(\.id) == [remote.id], "the imported row stays to offer its review")
    }

    @Test func aFailedImportSaysWhyAndCanBeTriedAgain() async throws {
        let remote = ServerScanBatch.iPhone(scans: 1)
        let archive = StubScanArchive(batches: [remote])
        try await archive.add(Fixtures.record(batch: ScanBatch.ID(rawValue: remote.id), codeRead: false), assets: [.photo: Data("p".utf8)])
        await archive.failAfter(0)
        let model = makeModel(archive)

        #expect(await model.importBatch(remote) == nil)
        guard case .failed(let message) = model.imports[remote.id] else {
            Issue.record("expected a failed import")
            return
        }
        #expect(message.contains("link dropped"))

        await archive.failAfter(nil)
        #expect(await model.importBatch(remote)?.imported == 1)
    }
}

@Suite("HTTP scan archive")
struct ScanArchiveClientTests {
    @Test func readsEveryPageOfABatchListing() async throws {
        let server = StubServer()
        let first = UUID()
        let second = UUID()
        server.respond { request in
            guard request.path == "/api/scans" else { return nil }
            let offset = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "offset" }?.value
            let id = offset == "0" ? first : second
            return .json(200, #"{"total":2,"items":[{"id":"\#(id.uuidString)","batch_id":"X","verdict":"pending"}]}"#)
        }

        let ids = try await server.client().scanIDs(inBatch: UUID())

        #expect(ids == [first, second])
        #expect(server.requests.count == 2)
        #expect(server.requests.allSatisfy { $0.url.query()?.contains("batch_id=") == true })
    }

    @Test func aBatchAScanAndItsPhotoDecode() async throws {
        let server = StubServer()
        let batch = UUID()
        let scan = UUID()
        server.on("/api/scans/batches", .json(200, """
        {"total":1,"items":[{"id":"\(batch.uuidString)","started_at":"2026-11-10T05:25:34.000Z","label":"","purpose":"collection",
          "product":"loose","default_finish":null,"training_quality":"standard","device_model":"iPhone17,1","system_version":"26.1",
          "app_version":"0.2.0","calibration_hash":"c900","created_at":"2026-11-10T13:31:13Z","updated_at":"2026-11-10T13:31:13Z",
          "scan_count":43,"decided_count":0}]}
        """))
        server.on("/api/scans/\(scan.uuidString)", .json(200, """
        {"id":"\(scan.uuidString)","batch_id":"\(batch.uuidString)","verdict":"pending","last_seq":0,"record":{"id":"\(scan.uuidString)","decisions":[]},
         "verdicts":[],"descriptor":null,"assets":[{"kind":"photo","sha256":"ab","bytes":3,"created_at":"2026-11-10T13:31:13Z"}]}
        """))
        server.on("/api/scans/\(scan.uuidString)/photo", StubResponse(status: 200, headers: ["Content-Type": "image/jpeg"], body: Data([0xFF, 0xD8, 0xFF])))
        let client = server.client()

        let batches = try await client.scanBatches()
        #expect(batches.map(\.id) == [batch])
        #expect(batches.first?.pendingCount == 43)
        let stored = try await client.scan(id: scan)
        #expect(stored.batchID == batch)
        #expect(stored.has(.photo))
        #expect(!stored.has(.canvas))
        #expect(try await client.asset(.photo, scanID: scan) == Data([0xFF, 0xD8, 0xFF]))
    }
}
