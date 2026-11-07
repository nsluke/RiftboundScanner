import Foundation
import Testing
@testable import RiftboundScannerApp

@Suite("HTTP collection client")
struct CollectionClientTests {
    static let healthJSON = """
    {"status":"ok","version":"2.0.0","cards":1822,"catalog_as_of":"2026-11-04","prices_refreshed_at":"2026-11-07T03:10:00Z",
     "user_version":5,"api_version":2,"catalog_version":"3f9a1c","last_backup_at":"2026-11-07T03:00:00Z","free_disk_mb":11234.5,
     "rss_mb":88.25,"assets_bytes":1048576,"scans_stored":144,"exemplars":12,"overlay_versions":3,"catalog_warnings":["UNL-T01: alias skipped"]}
    """

    @Test func healthDecodesEveryField() async throws {
        let server = StubServer()
        server.on("/health", .json(200, Self.healthJSON))
        let report = try await server.client().health()
        #expect(report.cards == 1822)
        #expect(report.userVersion == 5)
        #expect(report.apiVersion == 2)
        #expect(report.catalogVersion == "3f9a1c")
        #expect(report.lastBackupAt == "2026-11-07T03:00:00Z")
        #expect(report.freeDiskMB == 11234.5)
        #expect(report.rssMB == 88.25)
        #expect(report.assetsBytes == 1_048_576)
        #expect(report.scansStored == 144)
        #expect(report.exemplars == 12)
        #expect(report.catalogWarnings == ["UNL-T01: alias skipped"])
        #expect(report.isSupported)
    }

    @Test func everyRequestNamesTheClientAndCarriesTheTokenOnlyWhenSet() async throws {
        let server = StubServer()
        server.on("/health", .json(200, Self.healthJSON))
        _ = try await server.client().health()
        _ = try await server.client(token: "secret").health()
        let requests = server.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.headers["X-Client"] == server.identity })
        #expect(requests[0].headers["Authorization"] == nil)
        #expect(requests[1].headers["Authorization"] == "Bearer secret")
        #expect(requests[0].url.absoluteString == "http://riftbound.lan/health")
    }

    @Test func outdatedSchemaIsServerOutdated() async throws {
        let server = StubServer()
        server.on("/health", .json(200, #"{"status":"ok","version":"0.1.0","cards":1822,"user_version":1}"#))
        await #expect(throws: ServerError.serverOutdated(HealthReport(status: "ok", version: "0.1.0", cards: 1822, userVersion: 1))) {
            try await server.client().health()
        }
    }

    @Test func aV1ServerWithoutUserVersionIsOutdatedToo() async throws {
        let server = StubServer()
        server.on("/health", .json(200, #"{"status":"ok","version":"0.1.0","cards":1822,"catalog_as_of":"2026-11-04","prices_refreshed_at":null}"#))
        do {
            _ = try await server.client().health()
            Issue.record("expected serverOutdated")
        } catch ServerError.serverOutdated(let report) {
            #expect(report.cards == 1822)
            #expect(report.userVersion == nil)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func statusCodesMapToTypedErrors() async throws {
        let server = StubServer()
        server.on("/api/sync/ledger", StubResponse(status: 401))
        server.on("/api/scans/00000000-0000-0000-0000-000000000001", .json(409, #"{"detail":"seq_conflict","server_seq":4}"#))
        server.on("/api/learning/overlay/changes", .json(410, #"{"detail":"base version compacted"}"#))
        server.on("/api/scans/00000000-0000-0000-0000-000000000002/photo", StubResponse(status: 413))
        server.on("/api/scans/00000000-0000-0000-0000-000000000003/canvas", StubResponse(status: 507))
        server.on("/api/decks/7", .json(404, #"{"detail":"deck not found"}"#))
        server.on("/api/decks/8/cards", .json(422, #"{"detail":"slot must be one of ..."}"#))
        let client = server.client()

        await #expect(throws: ServerError.unauthorized) {
            try await client.syncLedger(LedgerSyncRequest(device: "test", items: []))
        }
        await #expect(throws: ServerError.conflict(detail: "seq_conflict", serverSeq: 4)) {
            try await client.putScan(ScanUpload(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, batchID: UUID(), record: .object([:]), descriptor: nil, analysisStamp: "s", engine: nil))
        }
        await #expect(throws: ServerError.gone) {
            try await client.overlayChanges(calibration: "abc", sinceVersion: 3)
        }
        await #expect(throws: ServerError.payloadTooLarge) {
            try await client.putAsset(Data(count: 10), kind: .photo, scanID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        }
        await #expect(throws: ServerError.insufficientStorage) {
            try await client.putAsset(Data(count: 10), kind: .canvas, scanID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
        }
        await #expect(throws: ServerError.notFound) {
            try await client.deck(id: 7)
        }
        await #expect(throws: ServerError.unprocessable(detail: "slot must be one of ...")) {
            try await client.setDeckCard(deckID: 8, DeckCardChange(cardID: "OGN-001", slot: .unknown("bogus"), quantity: 1))
        }
        #expect(ServerError.insufficientStorage.isRetryable)
        #expect(!ServerError.conflict(detail: nil, serverSeq: nil).isRetryable)
    }

    @Test func perItemStatusesDecode() async throws {
        let server = StubServer()
        server.on("/api/sync/ledger", .json(200, """
        {"results":[
          {"client_ref":"scan:A:1","status":"applied","card_id":"VEN-014","finish":"foil","ledger_id":41,"finish_warning":"foil-only printing"},
          {"client_ref":"scan:A:2:undo","status":"nothing_to_undo"},
          {"client_ref":"scan:B:1","status":"duplicate_mismatch"},
          {"client_ref":"scan:C:1","status":"unknown_card"},
          {"client_ref":"scan:D:1","status":"would_go_negative"},
          {"client_ref":"scan:E:1","status":"duplicate"},
          {"client_ref":"scan:F:1","status":"invalid"},
          {"client_ref":"scan:G:1","status":"teleported"}
        ]}
        """))
        let request = LedgerSyncRequest(device: "iPhone17,1", items: [
            .delta(LedgerSyncItem.Delta(clientRef: "scan:A:1", cardKey: "VEN-014", quantityDelta: 1, defaultFinish: .normal, occurredAt: Fixtures.epoch, scanID: UUID())),
            .undo(LedgerSyncItem.Undo(clientRef: "scan:A:2:undo", undoOf: "scan:A:1")),
        ])
        let response = try await server.client().syncLedger(request)
        #expect(response.results.map(\.status) == [.applied, .nothingToUndo, .duplicateMismatch, .unknownCard, .wouldGoNegative, .duplicate, .invalid, .unknown("teleported")])
        #expect(response.results[0].ledgerID == 41)
        #expect(response.results[0].finish == .foil)
        #expect(response.results[0].finishWarning == "foil-only printing")

        let sent = try #require(server.requests.first?.json)
        #expect(sent["device"] == .string("iPhone17,1"))
        guard case .array(let items)? = sent["items"], items.count == 2 else {
            Issue.record("items missing")
            return
        }
        #expect(items[0]["card_key"] == .string("VEN-014"))
        #expect(items[0]["finish"] == .null, "a nil finish is sent as null so the server derives it")
        #expect(items[0]["default_finish"] == .string("normal"))
        #expect(items[0]["quantity_delta"] == .number(1))
        #expect(items[0]["undo_of"] == nil)
        #expect(items[1]["undo_of"] == .string("scan:A:1"))
        #expect(items[1]["card_key"] == nil, "an undo carries no card fields")
        #expect(server.requests.first?.method == "POST")
    }

    @Test func aNotModifiedAnswerComesFromTheCacheUnderTheValidator() async throws {
        let server = StubServer()
        let body = #"{"summary":{"distinct_cards":1,"total_cards":3,"market_value":7.5,"ledger_events":3},"items":[{"card_id":"OGN-001","name":"Vi","set_code":"OGN","rarity":"Rare","type":"Unit","normal":2,"foil":1,"total":3}]}"#
        server.on("/api/holdings", sequence: [
            .json(200, body, headers: ["ETag": "W/\"h42-gzip\""]),
            StubResponse(status: 304, headers: ["ETag": "W/\"h42-gzip\""]),
        ])
        let client = server.client()

        let first = try await client.holdings(ifNoneMatch: nil)
        #expect(first.validator == "h42", "W/, quotes and Caddy's encoding suffix are stripped")
        #expect(first.value.items.first?.total == 3)

        let second = try await client.holdings(ifNoneMatch: first.validator)
        #expect(second == first)
        let requests = server.requests
        #expect(requests.count == 2)
        #expect(requests[0].headers["If-None-Match"] == nil)
        #expect(requests[1].headers["If-None-Match"] == "\"h42\"")
    }

    @Test func aNotModifiedWithoutACachedBodyRefetches() async throws {
        let server = StubServer()
        server.on("/api/catalog", sequence: [
            StubResponse(status: 304),
            .json(200, #"{"as_of":"2026-11-04","catalog_version":"c9","cards":[]}"#, headers: ["ETag": "\"c9\""]),
        ])
        let result = try await server.client().catalog(ifNoneMatch: "c9")
        #expect(result.validator == "c9")
        #expect(result.value.cards.isEmpty)
        #expect(server.requests.count == 2)
        #expect(server.requests[1].headers["If-None-Match"] == nil)
    }

    @Test func theCacheSurvivesANewClientWhenItIsOnDisk() async throws {
        let directory = URL.temporaryDirectory.appending(path: "ResponseCache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = StubServer()
        server.on("/api/prices/latest", sequence: [
            .json(200, #"{"day":"2026-11-07","items":{"OGN-001":{"normal":2.5,"foil":9.0}}}"#, headers: ["ETag": "\"2026-11-07\""]),
            StubResponse(status: 304),
        ])
        let first = try await server.client(cache: ResponseCache(directory: directory)).latestPrices(ifNoneMatch: nil)
        let second = try await server.client(cache: ResponseCache(directory: directory)).latestPrices(ifNoneMatch: first.validator)
        #expect(second.value.items["OGN-001"]?.foil == 9.0)
        #expect(server.requests.count == 2)
    }

    @Test func assetUploadsCarryTheirDigestAndMapCreatedVersusReplaced() async throws {
        let server = StubServer()
        let scanID = UUID()
        server.on("/api/scans/\(scanID.uuidString)/photo_small", sequence: [StubResponse(status: 201), StubResponse(status: 200)])
        let client = server.client()
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        let first = try await client.putAsset(bytes, kind: .photoSmall, scanID: scanID)
        let second = try await client.putAsset(bytes, kind: .photoSmall, scanID: scanID)
        #expect(first.outcome == .created)
        #expect(second.outcome == .updated)
        #expect(first.sha256.count == 64)
        let request = try #require(server.requests.first)
        #expect(request.method == "PUT")
        #expect(request.headers["X-Content-SHA256"] == first.sha256)
        #expect(request.headers["Content-Type"] == "image/jpeg")
        #expect(request.body == bytes)
    }

    @Test func scanUploadReceiptsReadTheBody() async throws {
        let server = StubServer()
        let id = UUID()
        server.on("/api/scans/\(id.uuidString)", sequence: [
            StubResponse(status: 201),
            .json(200, #"{"status":"ok","updated":["analysis"]}"#),
            .json(200, #"{"status":"unchanged"}"#),
            .json(200, #"{"deferred":true}"#),
        ])
        let client = server.client()
        let upload = ScanUpload(id: id, batchID: UUID(), record: .object(["id": .string(id.uuidString)]), descriptor: nil, analysisStamp: "stamp", engine: nil)
        #expect(try await client.putScan(upload) == ScanUploadReceipt(outcome: .created))
        #expect(try await client.putScan(upload) == ScanUploadReceipt(outcome: .updated, updated: ["analysis"]))
        #expect(try await client.putScan(upload) == ScanUploadReceipt(outcome: .unchanged))
        #expect(try await client.putScan(upload) == ScanUploadReceipt(outcome: .updated, isDeferred: true))
        let sent = try #require(server.requests.first?.json)
        #expect(sent["analysis_stamp"] == .string("stamp"))
        #expect(sent["record"]?["id"] == .string(id.uuidString))
    }

    @Test func policyKeepsTheBytesAndReadsTheVersion() async throws {
        let server = StubServer()
        let json = #"{"version":4,"confidence":{"auditRate":0.3},"admission":{"referenceFloor":0.62}}"#
        server.on("/api/learning/policy", .json(200, json))
        let policy = try await server.client().policy()
        #expect(policy.version == 4)
        #expect(policy.json == Data(json.utf8))
    }

    @Test func learningStatsAreAPlainGet() async throws {
        let server = StubServer()
        server.on("/api/learning/stats", .json(200, #"{"wilson_lower_bound":0.975,"confidence_level":0.95,"random_audits":150,"random_audits_wrong":0,"spot_checks":4}"#))
        let stats = try await server.client().learningStats()
        #expect(stats.wilsonLowerBound == 0.975)
        #expect(stats.randomAudits == 150)
        #expect(stats.spotChecks == 4)
        #expect(server.requests.first?.method == "GET")
    }

    @Test func decksAndDetailDecodeTheServerShape() async throws {
        let server = StubServer()
        server.on("/api/decks", .json(200, #"{"items":[{"id":3,"name":"Vi aggro","format":"constructed","notes":null,"created_at":"2026-11-01T00:00:00Z","updated_at":"2026-11-02T00:00:00Z","card_count":52}]}"#, headers: ["ETag": "\"d7\""]))
        server.on("/api/decks/3", .json(200, """
        {"id":3,"name":"Vi aggro","format":"constructed","notes":null,"created_at":"2026-11-01T00:00:00Z","updated_at":"2026-11-02T00:00:00Z",
         "cards":[{"card_id":"OGN-001","slot":"champion","quantity":1,"name":"Vi","set_code":"OGN","rarity":"Rare","type":"Unit","supertype":"Champion","domains":"[\\"Body\\"]","energy":3,"image_url":"https://example.invalid/x.png","owned":2,"used_elsewhere":1,"available":1,"short":0},
                  {"card_id":"OGN-300","slot":"sideboard","quantity":2,"name":"New Spell","set_code":"OGN","rarity":"Common","type":"Spell","supertype":null,"domains":["Body","Fury"],"energy":1,"image_url":null,"owned":0,"used_elsewhere":0,"available":0,"short":2}],
         "card_count":3,"short_count":2,"validation":[{"code":"main_size","message":"Main deck has 3 cards; needs 40","severity":"error"}]}
        """))
        let client = server.client()
        let decks = try await client.decks(ifNoneMatch: nil)
        #expect(decks.validator == "d7")
        #expect(decks.value.first?.cardCount == 52)
        let deck = try await client.deck(id: 3)
        #expect(deck.cards.map(\.slot) == [.champion, .sideboard])
        #expect(deck.cards[0].domains == ["Body"])
        #expect(deck.cards[1].domains == ["Body", "Fury"])
        #expect(deck.cards[1].short == 2)
        #expect(deck.shortCount == 2)
        #expect(deck.validation.issues.first?.code == "main_size", "the pre-S9 bare array still decodes")
    }

    @Test func aCellularOnlyPathNeverSendsARequest() async {
        let server = StubServer()
        server.on("/health", .json(200, Self.healthJSON))
        let client = HTTPCollectionClient(session: server.session, endpoints: FixedEndpoints(.unavailable(.cellularOnly)), token: { nil }, clientIdentity: server.identity, cache: ResponseCache(directory: nil))
        await #expect(throws: ServerError.noEndpoint(.cellularOnly)) {
            try await client.health()
        }
        #expect(server.requests.isEmpty)
    }

    @Test func aTransportFailureIsUnreachableAndForgetsTheEndpoint() async {
        let endpoints = FixedEndpoints(.available(.lan, health: HealthReport()))
        let client = HTTPCollectionClient(session: HTTPCollectionClient.makeSession(protocolClasses: [FailingURLProtocol.self]), endpoints: endpoints, token: { nil }, clientIdentity: "test", cache: ResponseCache(directory: nil))
        do {
            _ = try await client.health()
            Issue.record("expected a failure")
        } catch ServerError.unreachable {
            // expected
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(await endpoints.invalidations == 1)
    }

    @Test func theSessionHasNoCacheAndTheDocumentedTimeouts() {
        let configuration = HTTPCollectionClient.makeSession().configuration
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.timeoutIntervalForRequest == 15)
        #expect(configuration.timeoutIntervalForResource == 60)
    }

    @Test func validatorsAreBareValues() {
        #expect(HTTPCollectionClient.bareValidator("W/\"abc-gzip\"") == "abc")
        #expect(HTTPCollectionClient.bareValidator("\"abc\"") == "abc")
        #expect(HTTPCollectionClient.bareValidator("abc-br") == "abc")
        #expect(HTTPCollectionClient.bareValidator("\"\"") == nil)
    }
}
