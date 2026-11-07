import Foundation
import RiftboundRecognizer
import Testing
@testable import RiftboundScannerApp

@Suite("Card vault")
struct CardVaultTests {
    @Test func keysDropTheDenominatorAndKeepPromoSuffixes() {
        #expect(Fixtures.vaultCard(code: "OGN-066a", name: "Ahri").key == PrintingKey(rawValue: "OGN-066a"))
        #expect(Fixtures.vaultCard(code: "RAD-SP1", name: "Ahri").key == PrintingKey(rawValue: "RAD-SP1"))
        #expect(Fixtures.vaultCard(code: "OGN-066-P", name: "Ahri promo").key == PrintingKey(rawValue: "OGN-066-P"))
        // Was "SFD-227-STAR" before ADR-002: the vault's STAR spelling now joins the index's `*`.
        #expect(Fixtures.vaultCard(code: "SFD-227-STAR", name: "Ahri").key == PrintingKey(rawValue: "SFD-227*"))
        #expect(PrintingKey(Fixtures.vi.code) == PrintingKey(rawValue: "OGN-001"))
        #expect(PrintingKey(Fixtures.viAlt.code) == PrintingKey(rawValue: "OGN-001a"))
    }

    @Test func joinsTheIndexCardByCode() {
        #expect(Fixtures.vault[Fixtures.vi]?.code == "OGN-001")
        #expect(Fixtures.vault[Fixtures.viAlt]?.code == "OGN-001a")
        #expect(Fixtures.vault[Fixtures.radRune]?.code == "RAD-R01")
    }

    @Test func decodesTheBundledFileShape() async throws {
        let json = """
        {"asOf":"2026-11-04","source":"test","cards":[{"code":"OGN-001","name":"Vi","set":"OGN","setName":"Origins","rarity":"Rare","type":"Unit","supertype":"Champion","domains":["Body"],"energy":3,"might":3,"power":1,"text":"Hit.","flavor":null,"tags":["Vi"],"tcgplayerID":652900,"marketNormal":null,"marketFoil":1.5,"hasNormal":false,"hasFoil":true,"promo":false,"banned":false,"cardmarketURL":null,"image":"https://example.invalid/OGN-001.webp"}]}
        """
        let url = URL.temporaryDirectory.appending(path: "vault-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = try await CardVault.read(from: url)
        #expect(vault.cards.count == 1)
        #expect(vault.cards.first?.tcgplayerID == 652900)
        #expect(vault.cards.first?.supertype == "Champion")
        #expect(Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: vault.asOf).day == 4)
    }
}

@Suite("Collection filter")
struct CollectionFilterTests {
    private var entries: [CollectionEntry] {
        Fixtures.vault.cards.map { vault in
            CollectionEntry(vault: vault, card: nil, quantity: ["OGN-001": 3, "OGN-002": 1, "OGN-002-P": 1][vault.code] ?? 0, normalPrice: vault.marketNormal, foilPrice: vault.marketFoil)
        }
    }

    @Test func ownedOnlyKeepsCardsWithAQuantity() {
        var filter = CollectionFilter()
        #expect(filter.apply(to: entries).map(\.id) == ["OGN-001", "OGN-002", "OGN-002-P"])
        filter.ownedOnly = false
        #expect(filter.apply(to: entries).count == 5)
    }

    @Test func bestPricePrefersNormalThenFoil() {
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        #expect(byID["OGN-001"]?.bestPrice == 2.5)
        #expect(byID["OGN-001a"]?.bestPrice == 40, "foil-only printings show the foil price")
        #expect(byID["OGN-002-P"]?.bestPrice == nil)
        #expect(byID["OGN-001"]?.value == 7.5)
    }

    @Test func chipsNarrowByAttribute() {
        var filter = CollectionFilter(ownedOnly: false)
        filter.rarities = ["Showcase"]
        #expect(filter.apply(to: entries).map(\.id) == ["OGN-001a"])
        filter = CollectionFilter(ownedOnly: false)
        filter.domains = ["Chaos", "Calm"]
        #expect(filter.apply(to: entries).map(\.id) == ["OGN-002", "OGN-002-P", "RAD-R01"])
        filter = CollectionFilter(ownedOnly: false)
        filter.sets = ["RAD"]
        filter.types = ["Rune"]
        #expect(filter.apply(to: entries).map(\.id) == ["RAD-R01"])
    }

    @Test func togglesDropPromosUnpricedAndBanned() {
        var filter = CollectionFilter(ownedOnly: false)
        filter.includesPromos = false
        #expect(!filter.apply(to: entries).contains { $0.vault.promo })
        filter = CollectionFilter(ownedOnly: false)
        filter.pricedOnly = true
        #expect(filter.apply(to: entries).map(\.id) == ["OGN-001", "OGN-001a", "OGN-002", "RAD-R01"])
    }

    @Test func priceBandsUseTheBestPrice() {
        var filter = CollectionFilter(ownedOnly: false)
        filter.minimumPrice = 1
        filter.maximumPrice = 5
        #expect(filter.apply(to: entries).map(\.id) == ["OGN-001"])
        filter.maximumPrice = nil
        #expect(filter.apply(to: entries).map(\.id) == ["OGN-001", "OGN-001a"])
    }

    @Test func searchMatchesNameCodeTagsAndOptionallyRulesText() {
        var filter = CollectionFilter(ownedOnly: false)
        filter.query = "zaun"
        #expect(filter.apply(to: entries).map(\.id) == ["OGN-002"])
        filter.query = "rad-r"
        #expect(filter.apply(to: entries).map(\.id) == ["RAD-R01"])
        filter.query = "deal 2"
        #expect(filter.apply(to: entries).isEmpty)
        filter.searchesText = true
        #expect(filter.apply(to: entries).map(\.id) == ["OGN-002"])
    }

    @Test func sortsAreStableAndPutUnpricedLast() {
        var filter = CollectionFilter(ownedOnly: false)
        filter.sort = .priceDescending
        #expect(filter.apply(to: entries).map(\.id) == ["OGN-001a", "OGN-001", "OGN-002", "RAD-R01", "OGN-002-P"])
        filter.sort = .priceAscending
        #expect(filter.apply(to: entries).map(\.id) == ["RAD-R01", "OGN-002", "OGN-001", "OGN-001a", "OGN-002-P"])
        filter.sort = .rarity
        #expect(filter.apply(to: entries).first?.id == "OGN-001a")
        filter.sort = .quantity
        #expect(filter.apply(to: entries).first?.id == "OGN-001")
        filter.sort = .name
        #expect(filter.apply(to: entries).first?.vault.name == "Calm Rune")
        filter.sort = .setAndNumber
        #expect(filter.apply(to: entries).map(\.id) == ["OGN-001", "OGN-001a", "OGN-002", "OGN-002-P", "RAD-R01"])
    }

    @Test func activeCountIgnoresScopeAndSort() {
        var filter = CollectionFilter(ownedOnly: false, sort: .name)
        #expect(filter.activeCount == 0)
        filter.sets = ["OGN"]
        filter.pricedOnly = true
        #expect(filter.activeCount == 2)
    }

    @Test func totalsSumQuantitiesAndValue() {
        let totals = CollectionTotals(CollectionFilter().apply(to: entries))
        #expect(totals.printings == 3)
        #expect(totals.cards == 5)
        #expect(totals.value == 7.5 + 0.4)
    }
}

@Suite("Price feed")
struct PriceFeedTests {
    @Test func foldsNormalAndFoilRowsPerProduct() throws {
        let json = """
        {"success":true,"results":[
          {"productId":1,"marketPrice":2.5,"subTypeName":"Normal"},
          {"productId":1,"marketPrice":9.0,"subTypeName":"Foil"},
          {"productId":2,"marketPrice":null,"subTypeName":"Foil"},
          {"productId":3,"marketPrice":1.0,"subTypeName":"Sealed"}
        ]}
        """
        let envelope = try JSONDecoder.tcgcsv.decode(TCGCSVPriceSource.Envelope<TCGCSVPriceSource.Price>.self, from: Data(json.utf8))
        let sheet = TCGCSVPriceSource.sheet(from: envelope.results)
        #expect(sheet[1] == ProductPrice(normal: 2.5, foil: 9.0))
        #expect(sheet[2] == ProductPrice(normal: nil, foil: nil))
        #expect(sheet[3] == nil)
    }

    @Test func sheetRoundTripsThroughTheCache() throws {
        let sheet = PriceSheet(fetchedAt: Fixtures.epoch, byProduct: [7: ProductPrice(normal: 1, foil: 2)])
        let data = try JSONEncoder.tcgcsv.encode(sheet)
        #expect(try JSONDecoder.tcgcsv.decode(PriceSheet.self, from: data) == sheet)
    }
}

@Suite("Collection model")
struct CollectionModelTests {
    @Test func countsConfirmedCardsAcrossBatchesAndAppliesLivePrices() async throws {
        let store = InMemoryScanStore()
        let first = Fixtures.batch(), second = Fixtures.batch()
        await store.save(first)
        await store.save(second)
        try await store.append(Fixtures.record(batch: first.id, verdict: .correct), photo: Data(), rectified: nil)             // Vi
        try await store.append(Fixtures.record(batch: second.id, verdict: .corrected(Fixtures.vi.id)), photo: Data(), rectified: nil)
        try await store.append(Fixtures.record(batch: second.id, verdict: .corrected(Fixtures.viAlt.id)), photo: Data(), rectified: nil)
        try await store.append(Fixtures.record(batch: second.id, verdict: .pending), photo: Data(), rectified: nil)
        try await store.append(Fixtures.record(batch: second.id, verdict: .rejected(.notACard)), photo: Data(), rectified: nil)

        let live = PriceSheet(fetchedAt: Fixtures.epoch, byProduct: [1001: ProductPrice(normal: 5, foil: 20)])
        let model = CollectionModel(store: store, directory: Fixtures.directory, vault: Fixtures.vault, priceSource: StubPriceSource(outcome: .success(live)))
        await model.load()

        #expect(model.owned.value == [PrintingKey(rawValue: "OGN-001"): 2, PrintingKey(rawValue: "OGN-001a"): 1])
        let byID = Dictionary(uniqueKeysWithValues: model.entries.map { ($0.id, $0) })
        #expect(byID["OGN-001"]?.quantity == 2)
        #expect(byID["OGN-001"]?.normalPrice == 5, "the live feed overrides the snapshot")
        #expect(byID["OGN-001a"]?.foilPrice == 40, "no live price keeps the snapshot")
        #expect(byID["OGN-001"]?.card?.id == Fixtures.vi.id)
        #expect(model.ownedTotals.cards == 3)
        #expect(model.ownedTotals.value == 10 + 40)
        #expect(model.pricesAsOf == Fixtures.epoch)
    }

    @Test func priceFailureIsAStateAndSnapshotPricesRemain() async {
        let model = CollectionModel(store: InMemoryScanStore(), directory: Fixtures.directory, vault: Fixtures.vault, priceSource: StubPriceSource(outcome: .failure(.badResponse(401))))
        await model.load()
        guard case .failed(let failure) = model.prices else {
            Issue.record("expected a failed price state, got \(model.prices)")
            return
        }
        #expect(failure == .badResponse(401))
        #expect(model.owned.value == [:])
        #expect(model.entries.first { $0.id == "OGN-001" }?.normalPrice == 2.5)
    }
}
