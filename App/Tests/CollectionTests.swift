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

    @Test func aServerRowTakesArtFromTheBundledRowAndNoneWhenTheBundleLacksIt() {
        let known = CatalogState.server(Fixtures.catalog(cards: [Fixtures.catalogCard(code: "OGN-001", name: "Vi, Piltover Enforcer (renamed)"), Fixtures.catalogCard(code: "UNL-999", name: "New Card")]), seed: Fixtures.vault, fetchedAt: Fixtures.epoch)
        #expect(known.vault.cards.map(\.code) == ["OGN-001", "UNL-999"])
        #expect(known.vault.card(code: "OGN-001")?.name == "Vi, Piltover Enforcer (renamed)")
        #expect(known.vault.card(code: "OGN-001")?.image == Fixtures.vault.card(code: "OGN-001")?.image, "art is never served, so it comes from the bundle")
        #expect(known.vault.card(code: "UNL-999")?.image == nil)
        #expect(known.printingsNewerThanBundle == 1)
        #expect(known.origin == .server(version: "cat-2", fetchedAt: Fixtures.epoch))
        #expect(Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: known.vault.asOf).day == 6)
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

@Suite("Pending ledger deltas")
struct PendingLedgerTests {
    @Test func netsDeltasPerPrintingAcrossSpellings() {
        let deltas = [
            PendingDelta(clientRef: "scan:A:1", cardKey: "OGN-001", quantity: 1),
            PendingDelta(clientRef: "manual:1", cardKey: "OGN-001", quantity: 2),
            PendingDelta(clientRef: "scan:B:2:undo", cardKey: "SFD-227-STAR", quantity: -1),
            PendingDelta(clientRef: "scan:C:1", cardKey: "SFD-227*", quantity: 1),
        ]
        #expect(deltas.byPrinting == [PrintingKey(rawValue: "OGN-001"): 3], "the STAR row's undo and +1 cancel; the vault and index spellings are one key")
    }

    @Test func undosResolveThroughSyncJSONOrTheReplayedPlusOne() async throws {
        let directory = URL.temporaryDirectory.appending(path: "pending-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SyncingScanStore(inner: InMemoryScanStore(), directory: directory, now: { Fixtures.epoch })
        let outbox = Outbox(fileURL: directory.appending(path: "outbox.json"))
        let batch = Fixtures.batch(purpose: .collection)
        try await store.save(batch)
        let applied = ScanRecord.ID(rawValue: UUID()), replayed = ScanRecord.ID(rawValue: UUID()), orphan = ScanRecord.ID(rawValue: UUID())
        try await store.updateSyncState(for: batch.id) { state in
            state[applied].items[ClientRef.plusOne(applied, seq: 1).description] = .applied(ledgerID: 7, cardID: "OGN-002", finish: .foil)
        }
        try await outbox.replace(itemsFor: applied, in: batch.id, with: [.undo(.init(clientRef: ClientRef.undo(applied, seq: 2).description, undoOf: ClientRef.plusOne(applied, seq: 1).description))])
        try await outbox.replace(itemsFor: replayed, in: batch.id, with: [
            .delta(.init(clientRef: ClientRef.plusOne(replayed, seq: 1).description, cardKey: "OGN-001a", quantityDelta: 1)),
            .undo(.init(clientRef: ClientRef.undo(replayed, seq: 2).description, undoOf: ClientRef.plusOne(replayed, seq: 1).description)),
        ])
        try await outbox.replace(itemsFor: orphan, in: batch.id, with: [.undo(.init(clientRef: ClientRef.undo(orphan, seq: 2).description, undoOf: ClientRef.plusOne(orphan, seq: 1).description))])

        let deltas = await OutboxPendingLedger(outbox: outbox, store: store).pendingDeltas()
        #expect(deltas.first { $0.clientRef == ClientRef.undo(applied, seq: 2).description } == PendingDelta(clientRef: ClientRef.undo(applied, seq: 2).description, cardKey: "OGN-002", finish: .foil, quantity: -1))
        #expect(deltas.byPrinting == [PrintingKey(rawValue: "OGN-002"): -1], "a replayed +1 and its undo net to nothing; an undo of an unknown row counts for nothing")
    }
}

/// The model over the real sources with in-memory files, a scripted server
/// and a syncing store whose scans must never be counted.
@MainActor
@Suite("Collection model")
struct CollectionModelTests {
    /// What every test builds: the composition root's graph in miniature.
    @MainActor
    final class World {
        let directory: URL
        let store: SyncingScanStore
        let outbox: Outbox
        let client: StubCollectionClient
        let endpoints: FixedEndpoints
        let now: DateBox
        let catalog: ServerCatalogSource
        let holdings: ServerHoldingsSource
        let prices: ServerPriceSource

        init(script: ServerScript = ServerScript(), persisted: Bool = false) {
            directory = URL.temporaryDirectory.appending(path: "collection-\(UUID().uuidString)")
            now = DateBox(Fixtures.epoch)
            let clock = now
            store = SyncingScanStore(inner: InMemoryScanStore(), directory: directory, now: { clock.value })
            outbox = Outbox(fileURL: directory.appending(path: "outbox.json"))
            client = StubCollectionClient(script: script)
            endpoints = FixedEndpoints(.available(.lan, health: HealthReport(userVersion: 5, catalogVersion: "cat-1")))
            catalog = ServerCatalogSource(client: client, seed: Fixtures.vault, url: persisted ? directory.appending(path: "catalog.json") : nil, now: { clock.value })
            holdings = ServerHoldingsSource(client: client, url: persisted ? directory.appending(path: "holdings.json") : nil, now: { clock.value })
            prices = ServerPriceSource(client: client, url: persisted ? directory.appending(path: "prices.json") : nil, now: { clock.value })
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }

        func makeModel(pending: (any PendingLedgerProviding)? = nil, policy: CollectionModel.Policy = CollectionModel.Policy()) -> CollectionModel {
            let clock = now
            return CollectionModel(
                catalog: catalog,
                holdings: holdings,
                prices: prices,
                pending: pending ?? OutboxPendingLedger(outbox: outbox, store: store),
                endpoints: endpoints,
                directory: Fixtures.directory,
                seed: Fixtures.vault,
                now: { clock.value },
                policy: policy
            )
        }

        /// A `collection` batch holding `count` confirmed scans of Vi, the
        /// kind of local evidence the Collection must ignore.
        @discardableResult
        func addConfirmedScans(_ count: Int) async throws -> ScanBatch {
            let batch = Fixtures.batch(purpose: .collection, defaultFinish: .normal)
            try await store.save(batch)
            for _ in 0..<count {
                try await store.append(Fixtures.record(batch: batch.id, verdict: .correct), photo: Data(), rectified: nil)
            }
            return batch
        }
    }

    private func entry(_ code: String, in model: CollectionModel) -> CollectionEntry? {
        model.entries.first { $0.id == code }
    }

    @Test func ownedCountsComeFromTheHoldingsAndIgnoreLocalScans() async throws {
        var script = ServerScript()
        script.holdings = .success(Fixtures.holdings([("OGN-001", 1, 0)], validator: "h1"))
        let world = World(script: script)
        try await world.addConfirmedScans(3)
        let model = world.makeModel()
        await model.load()

        #expect(entry("OGN-001", in: model)?.quantity == 1, "the ledger's count, not the three local scans")
        #expect(entry("OGN-001", in: model)?.owned == OwnedCount(normal: 1, foil: 0))
        #expect(entry("OGN-002", in: model)?.quantity == 0)
        #expect(entry("OGN-001", in: model)?.card?.id == Fixtures.vi.id)
        #expect(model.holdings.value?.freshness == .live)
        #expect(model.ownedTotals.cards == 1)
        #expect(model.notices.isEmpty)
        #expect(await world.client.recording.holdingsValidators == [nil])
    }

    @Test func aNotModifiedAnswerKeepsTheCachedEntries() async throws {
        var script = ServerScript()
        script.holdings = .success(Fixtures.holdings([("OGN-001", 2, 1)], validator: "h1"))
        let world = World(script: script)
        let model = world.makeModel()
        await model.load()
        #expect(entry("OGN-001", in: model)?.owned == OwnedCount(normal: 2, foil: 1))

        // The same validator means the same content; the body is not consulted.
        await world.client.update { $0.holdings = .success(Versioned(value: HoldingsResponse(summary: HoldingsSummary(distinctCards: 0, totalCards: 0), items: []), validator: "h1")) }
        world.now.value = Fixtures.epoch.addingTimeInterval(600)
        await model.refreshHoldings()

        #expect(await world.client.recording.holdingsValidators == [nil, "h1"], "the stored validator went out as If-None-Match")
        #expect(entry("OGN-001", in: model)?.owned == OwnedCount(normal: 2, foil: 1))
        #expect(model.holdings.value?.snapshot.fetchedAt == Fixtures.epoch.addingTimeInterval(600))
        #expect(model.holdings.value?.freshness == .live)
    }

    @Test func unreachableWithASnapshotShowsTheSnapshotPlusUnacknowledgedDeltasAndTheOfflineNotice() async throws {
        var script = ServerScript()
        script.holdings = .success(Fixtures.holdings([("OGN-001", 1, 0), ("OGN-002", 0, 1)], validator: "h1"))
        let world = World(script: script)
        let model = world.makeModel()
        await model.load()

        // What the phone still owes: a +1 of Vi, and the undo of the applied foil Jinx row.
        let batch = try await world.addConfirmedScans(0)
        let scanned = ScanRecord.ID(rawValue: UUID()), undone = ScanRecord.ID(rawValue: UUID())
        try await world.outbox.replace(itemsFor: scanned, in: batch.id, with: [.delta(.init(clientRef: ClientRef.plusOne(scanned, seq: 1).description, cardKey: "OGN-001", quantityDelta: 1))])
        try await world.store.updateSyncState(for: batch.id) { state in
            state[undone].items[ClientRef.plusOne(undone, seq: 1).description] = .applied(ledgerID: 3, cardID: "OGN-002", finish: .foil)
        }
        try await world.outbox.replace(itemsFor: undone, in: batch.id, with: [.undo(.init(clientRef: ClientRef.undo(undone, seq: 2).description, undoOf: ClientRef.plusOne(undone, seq: 1).description))])
        await world.client.update { $0.holdings = .failure(.noEndpoint(.noPath)) }
        world.now.value = Fixtures.epoch.addingTimeInterval(3600)
        await model.load()

        guard case .loaded(let loaded) = model.holdings, case .cached(let reason) = loaded.freshness else {
            Issue.record("expected cached holdings, got \(model.holdings)")
            return
        }
        #expect(reason == .noEndpoint(.noPath))
        #expect(loaded.snapshot.fetchedAt == Fixtures.epoch, "the snapshot keeps the time it was really fetched")
        #expect(entry("OGN-001", in: model)?.quantity == 1)
        #expect(entry("OGN-001", in: model)?.pending == 1)
        #expect(entry("OGN-002", in: model)?.owned == OwnedCount(normal: 0, foil: 1))
        #expect(entry("OGN-002", in: model)?.pending == -1)
        #expect(model.pendingTotal == 0)
        #expect(model.notices == [.offline(asOf: Fixtures.epoch, reason: .noEndpoint(.noPath))])
        #expect(!model.isDisconnected)
    }

    @Test func unreachableWithoutASnapshotShowsTheBundledVaultWithZeroCountsAndAConnectAction() async throws {
        var script = ServerScript()
        script.holdings = .failure(.noEndpoint(.backingOff(retryAt: Fixtures.epoch)))
        let world = World(script: script)
        try await world.addConfirmedScans(2)
        let model = world.makeModel()
        await model.load()

        guard case .failed(let error) = model.holdings else {
            Issue.record("expected failed holdings, got \(model.holdings)")
            return
        }
        #expect(error == .noEndpoint(.backingOff(retryAt: Fixtures.epoch)))
        #expect(model.isDisconnected)
        #expect(model.entries.count == Fixtures.vault.cards.count, "the bundled vault is there to browse")
        #expect(model.entries.allSatisfy { $0.quantity == 0 })
        #expect(model.catalog.origin == .bundled)
        #expect(model.notices.isEmpty, "no snapshot, so nothing is 'as of'; the Connect state says it instead")

        // Connect: discovery is told to probe again, then holdings are asked for.
        await world.client.update { $0.holdings = .success(Fixtures.holdings([("OGN-001", 2, 0)], validator: "h1")) }
        await model.connect()
        #expect(await world.endpoints.invalidations == 1)
        #expect(!model.isDisconnected)
        #expect(entry("OGN-001", in: model)?.quantity == 2)
    }

    @Test func aQueuedManualItemAddsOnePendingAndClearsOnAcknowledgement() async throws {
        var script = ServerScript()
        script.holdings = .success(Fixtures.holdings([], validator: "h0"))
        let world = World(script: script)
        let pending = StubPendingLedger([PendingDelta(clientRef: "manual:3F2A", cardKey: "OGN-001", finish: .foil, quantity: 1)])
        let model = world.makeModel(pending: pending)
        await model.load()

        #expect(entry("OGN-001", in: model)?.pending == 1)
        #expect(entry("OGN-001", in: model)?.quantity == 0)
        #expect(model.pendingTotal == 1)
        #expect(model.shown.map(\.id) == ["OGN-001"], "a pending-only printing shows under My cards")

        // The server acknowledged it: the engine's outbox no longer holds it.
        await pending.set([])
        await model.refreshPending()
        #expect(entry("OGN-001", in: model)?.pending == 0)
        #expect(model.pendingTotal == 0)
        #expect(model.shown.isEmpty)
    }

    @Test func theServerCatalogReplacesTheBundledVaultAndFlagsPrintingsNewerThanTheBundle() async throws {
        var script = ServerScript()
        script.catalog = .success(Versioned(value: Fixtures.catalog(cards: [
            Fixtures.catalogCard(code: "OGN-001", name: "Vi, Piltover Enforcer"),
            Fixtures.catalogCard(code: "UNL-999", name: "New Card", set: "UNL"),
        ]), validator: "cat-2"))
        script.holdings = .success(Fixtures.holdings([("UNL-999", 1, 0)], validator: "h1"))
        let world = World(script: script)
        let model = world.makeModel()
        #expect(model.vault.cards.count == Fixtures.vault.cards.count, "the bundle shows until the server answers")
        await model.load()

        #expect(model.vault.cards.map(\.code) == ["OGN-001", "UNL-999"])
        #expect(model.catalog.origin == .server(version: "cat-2", fetchedAt: Fixtures.epoch))
        #expect(model.notices == [.catalogNewerThanBundle(printings: 1)])
        #expect(entry("UNL-999", in: model)?.quantity == 1, "holdings join the server's rows, bundle or not")
        #expect(entry("UNL-999", in: model)?.artURL == nil)
        #expect(entry("OGN-001", in: model)?.artURL == Fixtures.vi.imageURL)
        #expect(model.availableSets.map(\.code) == ["OGN", "UNL"])

        // /health reports a version the cache does not have: fetched now; the same one: not.
        await world.client.update { $0.catalog = .success(Versioned(value: Fixtures.catalog(version: "cat-3", cards: [Fixtures.catalogCard(code: "OGN-001", name: "Vi")]), validator: "cat-3")) }
        await model.noteServerCatalogVersion("cat-2")
        #expect(model.catalog.origin.version == "cat-2")
        await model.noteServerCatalogVersion("cat-3")
        #expect(model.catalog.origin.version == "cat-3")
        #expect(model.notices.isEmpty)
    }

    @Test func aCatalogFetchFailureKeepsWhatIsOnScreen() async throws {
        var script = ServerScript()
        script.catalog = .failure(.unreachable("refused"))
        let world = World(script: script)
        let model = world.makeModel()
        await model.load()
        #expect(model.catalog.origin == .bundled)
        #expect(model.vault.cards.count == Fixtures.vault.cards.count)
    }

    @Test func serverPricesOverrideTheSnapshotByCodeAndAStaleSheetOutlivesAFailure() async throws {
        var script = ServerScript()
        script.prices = .success(Versioned(value: PriceSheetResponse(day: "2026-11-06", items: ["OGN-001": PriceQuote(normal: 5, foil: 20)]), validator: "prices-2026-11-06.x"))
        let world = World(script: script)
        let model = world.makeModel()
        await model.load()

        #expect(entry("OGN-001", in: model)?.normalPrice == 5, "the server's latest sheet overrides the snapshot")
        #expect(entry("OGN-001", in: model)?.foilPrice == 20)
        #expect(entry("OGN-001a", in: model)?.foilPrice == 40, "no quote keeps the snapshot")
        #expect(model.prices.value?.day == "2026-11-06")
        #expect(model.pricesAsOf == CardVault.date(fromDay: "2026-11-06"))

        // Forced refresh fails: the sheet stays (stale beats blank).
        await world.client.update { $0.prices = .failure(.timedOut) }
        await model.refresh()
        #expect(model.prices.value?.day == "2026-11-06")
        #expect(entry("OGN-001", in: model)?.normalPrice == 5)
    }

    @Test func noPricesOnTheServerYetKeepsSnapshotPrices() async throws {
        var script = ServerScript()
        script.prices = .failure(.notFound)
        let world = World(script: script)
        let model = world.makeModel()
        await model.load()
        guard case .failed(let error) = model.prices else {
            Issue.record("expected failed prices, got \(model.prices)")
            return
        }
        #expect(error == .notFound)
        #expect(entry("OGN-001", in: model)?.normalPrice == 2.5)
        #expect(model.pricesAsOf == Fixtures.epoch)
    }

    @Test func aFreshPriceSheetIsNotRefetchedWithinThePolicyAge() async throws {
        var script = ServerScript()
        script.prices = .success(Versioned(value: PriceSheetResponse(day: "2026-11-06", items: [:]), validator: "p1"))
        let world = World(script: script)
        let model = world.makeModel()
        await model.load()
        await world.client.update { $0.prices = .failure(.timedOut) }
        world.now.value = Fixtures.epoch.addingTimeInterval(3600)
        await model.load()
        #expect(model.prices.value?.fetchedAt == Fixtures.epoch, "served from the cache: the failing server was never asked")
        world.now.value = Fixtures.epoch.addingTimeInterval(13 * 3600)
        await model.load()
        #expect(model.prices.value?.fetchedAt == Fixtures.epoch, "asked and failed: the stale sheet stays")
    }

    @Test func snapshotsSurviveARelaunch() async throws {
        var script = ServerScript()
        script.holdings = .success(Fixtures.holdings([("OGN-001", 4, 0)], validator: "h9"))
        script.catalog = .success(Versioned(value: Fixtures.catalog(cards: [Fixtures.catalogCard(code: "OGN-001", name: "Vi")]), validator: "cat-2"))
        script.prices = .success(Versioned(value: PriceSheetResponse(day: "2026-11-06", items: ["OGN-001": PriceQuote(normal: 1, foil: nil)]), validator: "p1"))
        let world = World(script: script, persisted: true)
        await world.makeModel().load()

        // A new launch with the server gone: every file comes back.
        let relaunched = ServerHoldingsSource(client: StubCollectionClient(), url: world.directory.appending(path: "holdings.json"), now: { Fixtures.epoch })
        #expect(await relaunched.snapshot()?["OGN-001"] == OwnedCount(normal: 4, foil: 0))
        #expect(await relaunched.snapshot()?.validator == "h9")
        let catalog = ServerCatalogSource(client: StubCollectionClient(), seed: Fixtures.vault, url: world.directory.appending(path: "catalog.json"), now: { Fixtures.epoch })
        #expect(await catalog.current().origin == .server(version: "cat-2", fetchedAt: Fixtures.epoch))
        let prices = ServerPriceSource(client: StubCollectionClient(), url: world.directory.appending(path: "prices.json"), now: { Fixtures.epoch })
        #expect(await prices.cached()?["OGN-001"] == PriceQuote(normal: 1, foil: nil))
    }
}

/// A clock a test moves by hand.
nonisolated final class DateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date

    init(_ date: Date) {
        stored = date
    }

    var value: Date {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

nonisolated extension Fixtures {
    static func holdings(_ rows: [(String, Int, Int)], validator: String?) -> Versioned<HoldingsResponse> {
        let items = rows.map { Holding(cardID: $0.0, normal: $0.1, foil: $0.2) }
        return Versioned(value: HoldingsResponse(summary: HoldingsSummary(distinctCards: items.count, totalCards: items.reduce(0) { $0 + $1.total }), items: items), validator: validator)
    }

    static func catalogCard(code: String, name: String, set: String = "OGN") -> CatalogCard {
        CatalogCard(
            code: code, name: name, set: set, setName: set == "OGN" ? "Origins" : set, rarity: "Rare", type: "Unit", supertype: nil,
            domains: ["Body"], energy: 3, might: 3, power: 1, text: nil, flavor: nil, tags: [], tcgplayerID: nil,
            marketNormal: 1.5, marketFoil: nil, hasNormal: true, hasFoil: true, promo: false, banned: false, nameKey: nil, artGroup: nil
        )
    }

    static func catalog(version: String = "cat-2", cards: [CatalogCard]) -> CatalogResponse {
        CatalogResponse(asOf: "2026-11-06", catalogVersion: version, cards: cards)
    }
}
