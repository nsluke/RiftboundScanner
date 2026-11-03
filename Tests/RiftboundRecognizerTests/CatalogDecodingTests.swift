import Foundation
import Testing
import RiftboundRecognizer

@Suite("Catalog decoding")
struct CatalogDecodingTests {
    static let fixture = """
    {"schema_version":1,"total":5,"cards":[
     {"id":"ogn-001-298","public_code":"OGN-001/298","collector_number":1,"name":"Blazing Scorcher","display_name":"Blazing Scorcher","set":{"id":"OGN","name":"Origins"},"type":"Unit","rarity":"Common","printing":{"alternate_art":false,"signature":false,"overnumbered":false},"image":{"url":"https://cmsassets.rgpub.io/x/1.png","width":744,"height":1039},"orientation":"portrait"},
     {"id":"ogn-007a-298","public_code":"OGN-007a/298","name":"Fury Rune","set":{"id":"OGN","name":"Origins"},"type":"Rune","rarity":"Showcase","printing":{"alternate_art":true,"signature":false,"overnumbered":false},"image":{"url":"https://cmsassets.rgpub.io/x/2.png","width":1488,"height":2078},"orientation":"portrait"},
     {"id":"ogn-275-298","public_code":"OGN-275/298","name":"Altar to Unity","set":{"id":"OGN","name":"Origins"},"type":"Battlefield","rarity":"Mythic","printing":{"alternate_art":false,"signature":false,"overnumbered":false},"image":{"url":"https://cmsassets.rgpub.io/x/3.png","width":1038,"height":744},"orientation":null},
     {"id":"ogn-299*-298","public_code":"OGN-299*/298","name":"Daughter of the Void","subtitle":"Kai'Sa","display_name":"Daughter of the Void — Kai'Sa","set":{"id":"OGN","name":"Origins"},"type":null,"rarity":"Epic","printing":{"alternate_art":false,"signature":true,"overnumbered":true},"image":{"url":"https://cmsassets.rgpub.io/x/4.png","width":1488,"height":2078},"orientation":"portrait"},
     {"id":"xxx-token","public_code":null,"name":"Token","set":{"id":"XXX","name":"X"},"type":"Unit","rarity":"Common","printing":{},"image":{"url":"https://cmsassets.rgpub.io/x/5.png"},"orientation":null}
    ]}
    """

    @Test func mapsRecordsToCards() throws {
        let catalog = try CardCatalog(jsonData: Data(Self.fixture.utf8))
        #expect(catalog.cards.count == 4)
        #expect(catalog.skipped == [CardCatalog.SkippedRecord(id: "xxx-token", reason: "no public_code")])

        let scorcher = try #require(catalog[Card.ID(rawValue: "ogn-001-298")])
        #expect(scorcher.code.canonical == "OGN-001/298")
        #expect(scorcher.kind == .unit && scorcher.rarity == .common && scorcher.orientation == .portrait)
        #expect(scorcher.imageURL.host == "cmsassets.rgpub.io")

        let altArt = try #require(catalog[Card.ID(rawValue: "ogn-007a-298")])
        #expect(altArt.printing == [.alternateArt] && altArt.code.variant == .alternateArt)

        let battlefield = try #require(catalog[Card.ID(rawValue: "ogn-275-298")])
        #expect(battlefield.orientation == .landscape, "orientation is derived from the image size when the catalog has none")
        #expect(battlefield.rarity == .unknown("Mythic"))

        let signature = try #require(catalog[Card.ID(rawValue: "ogn-299*-298")])
        #expect(signature.printing == [.signature, .overnumbered])
        #expect(signature.kind == nil)
        #expect(signature.displayName == "Daughter of the Void — Kai'Sa")
        #expect(signature.code.variant == .signature)
    }

    @Test func vocabularyReflectsTheCatalog() throws {
        let catalog = try CardCatalog(jsonData: Data(Self.fixture.utf8))
        #expect(catalog.vocabulary.sets.map(\.rawValue) == ["OGN"])
        #expect(catalog.vocabulary.numberPrefixes == [""])
    }

    @Test func malformedJSONIsReported() {
        #expect(throws: CatalogError.self) {
            try CardCatalog(jsonData: Data("{not json".utf8))
        }
    }

    @Test func cardsSurviveACodableRoundTrip() throws {
        let catalog = try CardCatalog(jsonData: Data(Self.fixture.utf8))
        let data = try JSONEncoder().encode(catalog.cards)
        #expect(try JSONDecoder().decode([Card].self, from: data) == catalog.cards)
    }
}

/// Contract test against the real catalog snapshot, when one has been fetched.
@Suite("Catalog snapshot", .enabled(if: RealCatalog.exists, "run Scripts/fetch-images.py to fetch data/cards.json"))
struct RealCatalogTests {
    @Test func everyPrintingRoundTripsItsCode() throws {
        let catalog = try CardCatalog.load(from: RealCatalog.url)
        #expect(catalog.skipped.isEmpty)
        #expect(catalog.cards.count >= 1400)
        let ids = Set(catalog.cards.map(\.id))
        #expect(ids.count == catalog.cards.count, "ids are unique per printing")
        let codes = Set(catalog.cards.map(\.code))
        #expect(codes.count == catalog.cards.count, "codes are unique per printing")
        let records = try JSONDecoder().decode(RawCatalog.self, from: try Data(contentsOf: RealCatalog.url)).cards
        let publicCodes = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.public_code) })
        for card in catalog.cards {
            #expect(card.code.canonical == publicCodes[card.id.rawValue], "\(card.id)")
        }
        #expect(catalog.cards.filter { $0.orientation == .landscape }.count > 50)
        #expect(catalog.vocabulary.sets.count >= 6)
    }

    private struct RawCatalog: Decodable {
        struct Record: Decodable {
            let id: String
            let public_code: String
        }
        let cards: [Record]
    }
}

enum RealCatalog {
    static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("data/cards.json")
    static var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
}
