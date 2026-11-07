import Foundation
import Testing
@testable import RiftboundScannerApp

@Suite("Server DTO coding")
struct DTOCodingTests {
    @Test func aSerialisedScanUploadContainsNoURL() throws {
        let record = Fixtures.record(batch: ScanBatch.ID(rawValue: UUID()), verdict: .correct)
        let stored = try JSONEncoder.scanStore.encode(record)
        #expect(String(decoding: stored, as: UTF8.self).contains("http"), "the fixture record does carry image URLs")

        let upload = ScanUpload(
            id: record.id.rawValue,
            batchID: record.batchID.rawValue,
            record: try ScanUpload.record(from: record),
            descriptor: DescriptorUpload(calibrationHash: "cal", orientation: .upright, featurePrint: Data(repeating: 0, count: 8).base64EncodedString(), hashes: ["dHash": "ff00"]),
            referenceSimilarity: 0.91,
            bestOtherReference: ReferenceSimilarityUpload(cardRef: "ogn-002-298", similarity: 0.6),
            codeAlternatives: [CodeAlternativeUpload(code: "OGN-001", cardRef: "ogn-001-298", referenceSimilarity: 0.91, isLiteral: true)],
            analysisStamp: "stamp",
            engine: EngineStampUpload(packageVersion: "1", calibrationHash: "cal", platform: "iOS", osVersion: "26.1")
        )
        let wire = try JSONEncoder.server.encode(upload)
        let text = String(decoding: wire, as: UTF8.self)
        #expect(!text.contains("http"))
        #expect(!text.contains("imageURL"))
        #expect(text.contains("\"candidates\""), "the record's own keys are kept")
        #expect(text.contains("\"capturedAt\""), "record keys keep the phone's camelCase spelling")
        #expect(text.contains("\"calibration_hash\""), "envelope keys are snake_case")
        #expect(text.contains("\"literal\":true"))
        #expect(!upload.record.containsString("http"))
    }

    @Test func removingKeysStripsAtAnyDepth() {
        let value = JSONValue.object([
            "imageURL": .string("https://x"),
            "candidates": .array([.object(["card": .object(["imageURL": .string("https://y"), "name": .string("Vi")])])]),
        ])
        let stripped = value.removingKeys(["imageURL"])
        #expect(stripped == .object(["candidates": .array([.object(["card": .object(["name": .string("Vi")])])])]))
        #expect(value.containsString("https"))
        #expect(!stripped.containsString("https"))
    }

    @Test func ledgerItemsRoundTripThroughTheirWireShape() throws {
        let items: [LedgerSyncItem] = [
            .delta(LedgerSyncItem.Delta(clientRef: "manual:1", cardKey: "OGN-066-P", quantityDelta: 2, finish: .foil, condition: "NM")),
            .undo(LedgerSyncItem.Undo(clientRef: "scan:X:2:undo", undoOf: "scan:X:1", occurredAt: Fixtures.epoch, scanID: UUID(uuidString: "8D59A000-0000-0000-0000-000000000000")!)),
        ]
        let data = try JSONEncoder.server.encode(items)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#"{"card_key":"OGN-066-P","client_ref":"manual:1","condition":"NM","finish":"foil","quantity_delta":2}"#))
        #expect(text.contains(#""occurred_at":"2023-11-14T22:13:20.000Z""#))
        #expect(text.contains(#""scan_id":"8D59A000-0000-0000-0000-000000000000""#))
        let decoded = try JSONDecoder.server.decode([LedgerSyncItem].self, from: data)
        #expect(decoded == items)
    }

    @Test func ledgerStatusesCoverTheServerVocabulary() throws {
        let raws = ["applied", "duplicate", "duplicate_mismatch", "unknown_card", "would_go_negative", "nothing_to_undo", "invalid"]
        let decoded = try JSONDecoder.server.decode([LedgerItemStatus].self, from: try JSONEncoder.server.encode(raws))
        #expect(decoded == [.applied, .duplicate, .duplicateMismatch, .unknownCard, .wouldGoNegative, .nothingToUndo, .invalid])
        #expect(decoded.map(\.rawValue) == raws)
        #expect(LedgerItemStatus(rawValue: "later") == .unknown("later"))
    }

    @Test func healthDecodesTheDeployedV1Shape() throws {
        let json = #"{"status":"ok","version":"0.1.0","cards":1822,"catalog_as_of":"2026-11-04","prices_refreshed_at":null}"#
        let report = try JSONDecoder.server.decode(HealthReport.self, from: Data(json.utf8))
        #expect(report.cards == 1822)
        #expect(report.catalogAsOf == "2026-11-04")
        #expect(report.userVersion == nil)
        #expect(!report.isSupported)
        #expect(HealthReport(userVersion: 3).isSupported)
        #expect(!HealthReport(userVersion: 2).isSupported)
    }

    /// Captured from `python -m riftbound_collection serve` on 2026-11-07
    /// (server main after S1): schema v1, so the app must say "needs updating".
    @Test func healthDecodesTheS1ShapeAsOutdated() throws {
        let json = #"{"status":"ok","version":"0.2.0","api_version":1,"user_version":1,"cards":1822,"catalog_as_of":"2026-11-04","catalog_warnings":[],"prices_refreshed_at":null,"last_backup_at":null,"free_disk_mb":517300.4,"rss_mb":83.0,"disk_warning":null,"backup_warning":null}"#
        let report = try JSONDecoder.server.decode(HealthReport.self, from: Data(json.utf8))
        #expect(report.userVersion == 1)
        #expect(report.apiVersion == 1)
        #expect(report.freeDiskMB == 517300.4)
        #expect(report.rssMB == 83.0)
        #expect(report.catalogWarnings == [])
        #expect(!report.isSupported)
    }

    @Test func catalogCardsUseTheVaultFieldNamesWithoutImages() throws {
        let json = """
        {"as_of":"2026-11-04","catalog_version":"3f9a","cards":[{"code":"OGN-001","name":"Vi","set":"OGN","setName":"Origins","rarity":"Rare","type":"Unit","supertype":"Champion","domains":["Body"],"energy":3,"might":3,"power":1,"text":"Hit.","flavor":null,"tags":["Vi"],"tcgplayerID":652900,"marketNormal":null,"marketFoil":1.5,"hasNormal":false,"hasFoil":true,"promo":false,"banned":false,"name_key":"Vi","art_group":"ogn-001","image":"https://example.invalid/OGN-001.webp"}]}
        """
        let catalog = try JSONDecoder.server.decode(CatalogResponse.self, from: Data(json.utf8))
        #expect(catalog.catalogVersion == "3f9a")
        let card = try #require(catalog.cards.first)
        #expect(card.tcgplayerID == 652900)
        #expect(card.marketFoil == 1.5)
        #expect(card.nameKey == "Vi")
        #expect(card.artGroup == "ogn-001")
        let reencoded = String(decoding: try JSONEncoder.server.encode(catalog), as: UTF8.self)
        #expect(!reencoded.contains("http"), "the image URL is not part of the DTO")
    }

    @Test func resolveAndPricesDecode() throws {
        let resolve = try JSONDecoder.server.decode(ResolveResponse.self, from: Data(#"{"resolved":{"OGN-066":{"card_id":"OGN-066","finishes":["foil"],"siblings":["OGN-066a","OGN-066-P"],"art_group":"ogn-066"}},"unknown":["XXX-1"]}"#.utf8))
        #expect(resolve.resolved["OGN-066"]?.finishes == [.foil])
        #expect(resolve.resolved["OGN-066"]?.siblings == ["OGN-066a", "OGN-066-P"])
        #expect(resolve.unknown == ["XXX-1"])

        let prices = try JSONDecoder.server.decode(PriceSheetResponse.self, from: Data(#"{"day":"2026-11-07","items":{"OGN-001":{"normal":2.5,"foil":null}}}"#.utf8))
        #expect(prices.items["OGN-001"] == PriceQuote(normal: 2.5, foil: nil))
    }

    @Test func ledgerPagesAndOverlayChangesDecode() throws {
        let page = try JSONDecoder.server.decode(LedgerPage.self, from: Data(#"{"head":12,"items":[{"id":12,"card_id":"OGN-001","finish":"normal","quantity_delta":-1,"condition":"NM","source":"web","batch_id":null,"client_ref":null,"undo_of":null,"created_at":"2026-11-07T10:00:00Z"}]}"#.utf8))
        #expect(page.head == 12)
        #expect(page.items.first?.quantityDelta == -1)
        #expect(page.items.first?.finish == .normal)

        let changes = try JSONDecoder.server.decode(OverlayChanges.self, from: Data(#"{"since_version":3,"version":5,"added":[{"id":9,"art_group":"sfd-227","feature_print":"AAAA","scan_id":"S","batch_id":"B","admitted_at":"2026-11-07T00:00:00Z"}],"revoked":[4]}"#.utf8))
        #expect(changes.added.first?.artGroup == "sfd-227")
        #expect(changes.revoked == [4])

        let meta = try JSONDecoder.server.decode(OverlayMeta.self, from: Data(#"{"version":5,"calibration_hash":"cal","exemplar_count":312,"built_at":"2026-11-07T03:30:00Z","etag":"ov-5"}"#.utf8))
        #expect(meta.exemplarCount == 312)
    }

    @Test func evaluationRunsForwardTheirCases() throws {
        let run = EvaluationRunUpload(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, ranAt: Fixtures.epoch, device: "iPhone17,1", batchID: nil, excludedBatch: UUID(uuidString: "22222222-2222-2222-2222-222222222222"), exemplarCountUsed: 120, overlayVersion: 5, policyVersion: 2, engine: nil, cases: .array([.object(["scanID": .string("S"), "top1Correct": .bool(true)])]))
        let text = String(decoding: try JSONEncoder.server.encode(run), as: UTF8.self)
        #expect(text.contains(#""excluded_batch":"22222222-2222-2222-2222-222222222222""#))
        #expect(text.contains(#""exemplar_count_used":120"#))
        #expect(text.contains(#""top1Correct":true"#), "case keys travel as written")
    }

    @Test func deckSlotsDegradeGracefully() throws {
        let slots = try JSONDecoder.server.decode([DeckSlot].self, from: Data(#"["legend","champion","rune","battlefield","main","sideboard","commander"]"#.utf8))
        #expect(slots == [.legend, .champion, .rune, .battlefield, .main, .sideboard, .unknown("commander")])
        #expect(String(decoding: try JSONEncoder.server.encode(DeckCardChange(cardID: "OGN-001", slot: .sideboard, quantity: 2)), as: UTF8.self) == #"{"card_id":"OGN-001","quantity":2,"slot":"sideboard"}"#)
    }

    @Test func serverDatesDecodeWithAndWithoutFractions() throws {
        struct Stamp: Decodable { let at: Date }
        let plain = try JSONDecoder.server.decode(Stamp.self, from: Data(#"{"at":"2023-11-14T22:13:20Z"}"#.utf8))
        let fractional = try JSONDecoder.server.decode(Stamp.self, from: Data(#"{"at":"2023-11-14T22:13:20.250Z"}"#.utf8))
        #expect(plain.at == Fixtures.epoch)
        #expect(fractional.at == Fixtures.epoch.addingTimeInterval(0.25))
    }
}

@Suite("App paths")
struct AppPathsTests {
    @Test func preparedDirectoriesExistAndAreExcludedFromBackup() throws {
        let root = URL.temporaryDirectory.appending(path: "AppPaths-\(UUID().uuidString)/Riftbound", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let paths = try AppPaths(root: root).prepare()
        #expect(paths.sync.lastPathComponent == "Sync")
        #expect(paths.learning.lastPathComponent == "Learning")
        #expect(paths.catalog.lastPathComponent == "Catalog")
        for directory in paths.all {
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: directory.path(percentEncoded: false), isDirectory: &isDirectory) && isDirectory.boolValue)
            let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(values.isExcludedFromBackup == true, "\(directory.lastPathComponent) must be excluded from backup")
        }
        #expect(AppPaths.live.root.pathComponents.suffix(3) == ["Library", "Application Support", "Riftbound"])
    }

    @Test func preparingTwiceIsHarmlessAndSizesAddUp() throws {
        let root = URL.temporaryDirectory.appending(path: "AppPaths-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppPaths(root: root).prepare()
        try Data(count: 1000).write(to: paths.sync.appending(path: "a.json"))
        try FileManager.default.createDirectory(at: paths.sync.appending(path: "nested"), withIntermediateDirectories: true)
        try Data(count: 24).write(to: paths.sync.appending(path: "nested/b.json"))
        _ = try paths.prepare()
        #expect(paths.size(of: paths.sync) == 1024)
        #expect(paths.size(of: paths.learning) == 0)
    }
}

@Suite("App configuration")
struct AppConfigurationTests {
    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    @Test func thePlistAllowsPlainHTTPToTheHomeServer() throws {
        let ats = try #require(info["NSAppTransportSecurity"] as? [String: Any])
        #expect(ats["NSAllowsLocalNetworking"] as? Bool == true)
        let exceptions = try #require(ats["NSExceptionDomains"] as? [String: Any])
        for host in ["riftbound.lan", "riftbound.local"] {
            let exception = try #require(exceptions[host] as? [String: Any], "\(host) needs an ATS exception")
            #expect(exception["NSExceptionAllowsInsecureHTTPLoads"] as? Bool == true)
        }
    }

    @Test func thePlistDeclaresLocalNetworkUseAndTheVersion() throws {
        #expect((info["NSLocalNetworkUsageDescription"] as? String)?.isEmpty == false)
        #expect(info["NSBonjourServices"] as? [String] == ["_http._tcp"])
        #expect((info["NSCameraUsageDescription"] as? String)?.contains("your own home server") == true)
        #expect(info["CFBundleShortVersionString"] as? String == "0.2.0")
    }
}
