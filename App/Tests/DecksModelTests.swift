import Foundation
import SwiftUI
import Testing
@testable import RiftboundScannerApp

// MARK: - Fixtures

nonisolated private enum DeckFixtures {
    static let now = Fixtures.epoch
    static let savedAt = Fixtures.epoch.addingTimeInterval(-3_600)

    static let ahriDeck = DeckSummary(id: 1, name: "Ahri tempo", format: "constructed", cardCount: 26, shortCount: 3, updatedAt: "2026-11-07T21:42:05Z")
    static let sealedDeck = DeckSummary(id: 2, name: "Sealed pool", format: "sealed", cardCount: 4)

    static func card(_ cardID: String, slot: DeckSlot, quantity: Int, name: String, type: String? = "Unit", supertype: String? = nil, owned: Int, usedElsewhere: Int = 0) -> DeckCard {
        let available = owned - usedElsewhere
        return DeckCard(cardID: cardID, slot: slot, quantity: quantity, name: name, setCode: String(cardID.prefix(3)), rarity: "Common", type: type, supertype: supertype, domains: ["Calm"], owned: owned, usedElsewhere: usedElsewhere, available: available, short: max(0, quantity - available))
    }

    /// A deck whose server-side arithmetic is deliberately *not* what the
    /// phone would recompute: `shortCount` 7 against cards summing to 3.
    static let ahriDetail = DeckDetail(
        id: 1,
        name: "Ahri tempo",
        format: "constructed",
        notes: "Test deck",
        cards: [
            card("OGN-255", slot: .legend, quantity: 1, name: "Ahri - Nine-Tailed Fox", type: "Legend", owned: 1),
            card("OGN-066", slot: .champion, quantity: 1, name: "Ahri - Alluring", supertype: "Champion", owned: 0),
            card("RAD-R01", slot: .rune, quantity: 12, name: "Fury Rune", type: "Rune", owned: 12),
            card("OGN-275", slot: .battlefield, quantity: 1, name: "Altar to Unity", type: "Battlefield", owned: 1),
            card("OGN-206", slot: .main, quantity: 3, name: "Back to Back", type: "Spell", owned: 2, usedElsewhere: 1),
            card("OGN-025", slot: .sideboard, quantity: 2, name: "Blind Fury", type: "Spell", owned: 2),
        ],
        cardCount: 20,
        shortCount: 7,
        validation: DeckValidation(
            isOK: false,
            format: "constructed",
            rulesAsOf: "2026-10-09",
            issues: [
                DeckIssue(code: "main_size", severity: .error, message: "Main Deck: 3 cards, needs 40", slot: .main),
                DeckIssue(code: "legend_count", severity: .warning, message: "two legends", cardIDs: ["OGN-255"]),
            ]
        )
    )

    static let piltover = "Legend\n1 Ahri - Nine-Tailed Fox (OGN-255)\n\nMain Deck\n3 Back to Back (OGN-206)\n"

    /// A Signature spell: the one case where the type alone would mislead.
    static let signatureCard = VaultCard(
        code: "VEN-150", name: "Acceleration Gate", set: "VEN", setName: "Venture", rarity: "Epic", type: "Spell", supertype: "Signature",
        domains: ["Body"], energy: 2, might: nil, power: nil, text: nil, flavor: nil, tags: ["Jayce"], tcgplayerID: nil,
        marketNormal: nil, marketFoil: 1, hasNormal: false, hasFoil: true, promo: false, banned: false,
        cardmarketURL: nil, image: URL(string: "https://example.invalid/VEN-150.webp")!
    )

    static func script(decks: [DeckSummary] = [ahriDeck, sealedDeck], detail: DeckDetail = ahriDetail) -> ServerScript {
        var script = ServerScript()
        script.decks = .success(Versioned(value: decks, validator: "d1"))
        script.deckDetails = [detail.id: .success(detail)]
        script.deckExports = [detail.id: .success(piltover)]
        return script
    }

    static func cache(listingAt savedAt: Date = savedAt, withDetail: Bool = true) -> DeckCache {
        DeckCache(
            listing: DeckCache.Listing(decks: [ahriDeck], validator: "d0", fetchedAt: savedAt),
            details: withDetail ? [1: DeckCache.Detail(deck: ahriDetail, export: piltover, fetchedAt: savedAt)] : [:]
        )
    }
}

// MARK: - DTOs

@Suite("Deck DTOs")
struct DeckDTOTests {
    @Test func decodesTheServersDeckDetail() throws {
        // Captured from RiftboundCollection main (user_version 4) with S9 merged.
        let deck = try JSONDecoder.server.decode(DeckDetail.self, from: Fixtures.fixtureData("deck-detail-v4", extension: "json"))
        #expect(deck.id == 1)
        #expect(deck.format == "constructed")
        #expect(deck.cardCount == 26)
        #expect(deck.shortCount == 22, "the server's short count is read, not recomputed")
        #expect(deck.counts == [.legend: 1, .champion: 1, .rune: 12, .battlefield: 2, .main: 8, .sideboard: 2])
        #expect(deck.cards.map(\.slot).contains(.sideboard))

        let rune = try #require(deck.cards.first { $0.cardID == "RAD-R01" })
        #expect(rune.owned == 8)
        #expect(rune.usedElsewhere == 4)
        #expect(rune.available == 4)
        #expect(rune.short == 8)
        #expect(rune.nameKey == "Fury Rune")
        #expect(rune.domains == ["Fury"])
        #expect(!rune.banned)
        #expect(try #require(deck.cards.first { $0.cardID == "OGN-276" }).banned)

        let validation = deck.validation
        #expect(!validation.isOK)
        #expect(validation.format == "constructed")
        #expect(validation.rulesAsOf == "2026-10-09")
        #expect(validation.errorCount == 9)
        #expect(validation.warningCount == 0)
        #expect(validation.issues.count == 9)
        let banned = try #require(validation.issues.first { $0.code == "banned" })
        #expect(banned.severity == .error)
        #expect(banned.cardIDs == ["OGN-276"])
        #expect(banned.slot == .battlefield)
        #expect(banned.text == "Aspirant's Climb is banned in constructed")
        #expect(validation.issues.map(\.code).contains("domain_identity"))
    }

    @Test func decodesTheServersDeckList() throws {
        let page = try JSONDecoder.server.decode(DecksResponse.self, from: Fixtures.fixtureData("decks-v4", extension: "json"))
        #expect(page.items.map(\.id) == [1, 2])
        #expect(page.items.first?.cardCount == 26)
        #expect(page.items.first?.shortCount == nil, "the list has no short count; only the detail does")
        #expect(page.items.first?.formatTitle == "Constructed")
    }

    @Test func toleratesTheEarlierValidationArrayAndMissingCounts() throws {
        let json = #"{"id":3,"name":"Old","format":"constructed","cards":[{"card_id":"OGN-001","slot":"main","quantity":2,"name":"Vi","owned":1}],"validation":[{"code":"main_size","card_id":"OGN-001"}]}"#
        let deck = try JSONDecoder.server.decode(DeckDetail.self, from: Data(json.utf8))
        #expect(deck.cardCount == 2)
        #expect(deck.shortCount == 1)
        #expect(deck.counts[.main] == 2)
        #expect(deck.counts[.sideboard] == 0)
        #expect(deck.validation.issues == [DeckIssue(code: "main_size", severity: .error, cardIDs: ["OGN-001"])])
        #expect(!deck.validation.isOK)

        let unjudged = try JSONDecoder.server.decode(DeckDetail.self, from: Data(#"{"id":4,"name":"Bare","format":"draft","cards":[]}"#.utf8))
        #expect(unjudged.validation == .unjudged)
        #expect(unjudged.validation.isOK)
    }

    @Test func unknownSeveritiesAndSlotsSurvive() throws {
        let issue = try JSONDecoder.server.decode(DeckIssue.self, from: Data(#"{"code":"x","severity":"notice","message":"m","card_ids":[],"slot":"bench"}"#.utf8))
        #expect(issue.severity == .unknown("notice"))
        #expect(!issue.isError)
        #expect(issue.slot == .unknown("bench"))
    }

    @Test func deckDetailRoundTrips() throws {
        let data = try JSONEncoder.server.encode(DeckFixtures.ahriDetail)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""short_count":7"#))
        #expect(text.contains(#""counts":{"#))
        #expect(text.contains(#""as_of":"2026-10-09""#))
        #expect(try JSONDecoder.server.decode(DeckDetail.self, from: data) == DeckFixtures.ahriDetail)
    }

    @Test func exportStylesMatchTheServersQueryValues() {
        #expect(DeckExportStyle.piltover.rawValue == "piltover")
        #expect(DeckExportStyle.text.rawValue == "text")
    }
}

// MARK: - Decks list

@Suite("Decks model")
struct DecksModelTests {
    private func makeModel(client: StubCollectionClient, cache: InMemoryDeckCacheStore = InMemoryDeckCacheStore()) -> DecksModel {
        DecksModel(client: client, cache: cache, now: { DeckFixtures.now })
    }

    @Test func loadsTheListAndCachesItWithItsValidator() async {
        let client = StubCollectionClient(script: DeckFixtures.script())
        let cache = InMemoryDeckCacheStore()
        let model = makeModel(client: client, cache: cache)
        await model.load()
        guard case .loaded(let listing) = model.decks else {
            Issue.record("expected a listing, got \(model.decks)")
            return
        }
        #expect(listing.decks.map(\.name) == ["Ahri tempo", "Sealed pool"])
        #expect(listing.freshness == .live)
        #expect(await cache.cache.listing == DeckCache.Listing(decks: listing.decks, validator: "d1", fetchedAt: DeckFixtures.now))
        #expect(await client.recording.decksValidators == [nil])
    }

    @Test func aFailureWithoutACacheFailsAndRetryRecovers() async {
        var script = DeckFixtures.script()
        script.decks = .failure(.timedOut)
        let client = StubCollectionClient(script: script)
        let model = makeModel(client: client)
        await model.load()
        guard case .failed(let error) = model.decks else {
            Issue.record("expected a failure, got \(model.decks)")
            return
        }
        #expect(error == .timedOut)

        await client.update { $0.decks = .success(Versioned(value: [DeckFixtures.ahriDeck], validator: "d2")) }
        await model.load()
        #expect(model.decks.value?.decks.count == 1)
        #expect(model.decks.value?.freshness == .live)
    }

    @Test func offlineWithACacheShowsTheCachedDecksWithWhenTheyWereSaved() async {
        var script = DeckFixtures.script()
        script.decks = .failure(.noEndpoint(.noPath))
        let client = StubCollectionClient(script: script)
        let cache = InMemoryDeckCacheStore(DeckFixtures.cache())
        let model = makeModel(client: client, cache: cache)
        await model.load()
        guard case .loaded(let listing) = model.decks else {
            Issue.record("expected the cached listing, got \(model.decks)")
            return
        }
        #expect(listing.decks == [DeckFixtures.ahriDeck])
        #expect(listing.freshness == .cached(asOf: DeckFixtures.savedAt, reason: .noEndpoint(.noPath)))
        #expect(listing.freshness.isCached)
        #expect(await client.recording.decksValidators == ["d0"], "the cached validator rides along as If-None-Match")
        #expect(await cache.saveCount == 0, "a failed fetch does not touch the cache")
    }

    @Test func aRefreshKeepsTheLoadedListOnScreen() async {
        let client = StubCollectionClient(script: DeckFixtures.script())
        let model = makeModel(client: client)
        await model.load()
        await client.update { $0.decks = .failure(.timedOut) }
        await model.load()
        guard case .loaded(let listing) = model.decks else {
            Issue.record("expected the previous list, got \(model.decks)")
            return
        }
        #expect(listing.freshness == .cached(asOf: DeckFixtures.now, reason: .timedOut))
    }
}

// MARK: - Deck detail

@Suite("Deck detail model")
struct DeckDetailModelTests {
    private func makeModel(client: StubCollectionClient, cache: InMemoryDeckCacheStore = InMemoryDeckCacheStore(), deckID: Int = 1) -> DeckDetailModel {
        DeckDetailModel(deckID: deckID, name: "Ahri tempo", client: client, cache: cache, now: { DeckFixtures.now })
    }

    @Test func loadsSlotsOwnershipValidationAndTheShareText() async {
        let client = StubCollectionClient(script: DeckFixtures.script())
        let cache = InMemoryDeckCacheStore()
        let model = makeModel(client: client, cache: cache)
        await model.load()
        guard case .loaded(let loaded) = model.deck else {
            Issue.record("expected a deck, got \(model.deck)")
            return
        }
        #expect(loaded.freshness == .live)
        #expect(model.shortCount == 7, "the short count is the server's, not a sum over the rows")
        #expect(loaded.deck.cards.reduce(0) { $0 + $1.short } == 3, "which the rows would not reproduce")
        #expect(loaded.sections.map(\.slot) == DeckSlot.allCases)
        #expect(loaded.sections.map(\.count) == [1, 1, 12, 1, 3, 2])
        #expect(loaded.sections.first { $0.slot == .sideboard }?.cards.map(\.cardID) == ["OGN-025"])
        #expect(loaded.deck.validation.errors.map(\.code) == ["main_size"])
        #expect(loaded.deck.validation.warnings.map(\.code) == ["legend_count"])
        #expect(model.export.value == DeckFixtures.piltover)
        #expect(await client.recording.deckExports.map(\.style) == [.piltover])
        #expect(await cache.cache.details[1] == DeckCache.Detail(deck: DeckFixtures.ahriDetail, export: DeckFixtures.piltover, fetchedAt: DeckFixtures.now))
    }

    @Test func anUnknownSlotFromANewerServerIsStillListed() async {
        var detail = DeckFixtures.ahriDetail
        let extra = DeckFixtures.card("OGN-300", slot: .unknown("maybeboard"), quantity: 1, name: "Future", owned: 0)
        detail = DeckDetail(id: detail.id, name: detail.name, format: detail.format, cards: detail.cards + [extra], cardCount: detail.cardCount + 1, shortCount: detail.shortCount + 1, validation: detail.validation)
        let client = StubCollectionClient(script: DeckFixtures.script(detail: detail))
        let model = makeModel(client: client)
        await model.load()
        #expect(model.deck.value?.sections.last?.slot == .unknown("maybeboard"))
        #expect(model.deck.value?.sections.last?.title == "Maybeboard")
    }

    @Test func aFailedExportLeavesTheDeckLoaded() async {
        var script = DeckFixtures.script()
        script.deckExports = [1: .failure(.unexpectedStatus(500, detail: nil))]
        let model = makeModel(client: StubCollectionClient(script: script))
        await model.load()
        #expect(model.deck.value?.deck.id == 1)
        guard case .failed(let error) = model.export else {
            Issue.record("expected the export to fail, got \(model.export)")
            return
        }
        #expect(error == .unexpectedStatus(500, detail: nil))
    }

    @Test func aFailureWithoutACacheFailsAndRetryRecovers() async {
        var script = DeckFixtures.script()
        script.deckDetails = [1: .failure(.unreachable("refused"))]
        let client = StubCollectionClient(script: script)
        let model = makeModel(client: client)
        await model.load()
        guard case .failed(let error) = model.deck else {
            Issue.record("expected a failure, got \(model.deck)")
            return
        }
        #expect(error == .unreachable("refused"))

        await client.update { $0.deckDetails = [1: .success(DeckFixtures.ahriDetail)] }
        await model.load()
        #expect(model.deck.value?.freshness == .live)
        #expect(model.deck.value?.deck == DeckFixtures.ahriDetail)
    }

    @Test func offlineWithACacheShowsTheSavedDeckAndItsShareText() async {
        var script = DeckFixtures.script()
        script.deckDetails = [1: .failure(.noEndpoint(.cellularOnly))]
        script.deckExports = [1: .failure(.noEndpoint(.cellularOnly))]
        let model = makeModel(client: StubCollectionClient(script: script), cache: InMemoryDeckCacheStore(DeckFixtures.cache()))
        await model.load()
        guard case .loaded(let loaded) = model.deck else {
            Issue.record("expected the cached deck, got \(model.deck)")
            return
        }
        #expect(loaded.deck == DeckFixtures.ahriDetail)
        #expect(loaded.freshness == .cached(asOf: DeckFixtures.savedAt, reason: .noEndpoint(.cellularOnly)))
        #expect(model.export.value == DeckFixtures.piltover, "the saved share text still shares")
    }

    @Test func aDeckNeverSeenBeforeFailsOffline() async {
        var script = DeckFixtures.script()
        script.deckDetails = [:]
        let model = makeModel(client: StubCollectionClient(script: script), cache: InMemoryDeckCacheStore(DeckFixtures.cache(withDetail: false)))
        await model.load()
        guard case .failed(let error) = model.deck else {
            Issue.record("expected a failure, got \(model.deck)")
            return
        }
        #expect(error == .notFound)
    }
}

// MARK: - Add to deck

@Suite("Add to deck")
struct AddToDeckModelTests {
    private func makeModel(
        card: VaultCard = DeckFixtures.signatureCard,
        client: StubCollectionClient,
        endpoints: FixedEndpoints = FixedEndpoints(.available(.lan, health: HealthReport(userVersion: 5))),
        cache: InMemoryDeckCacheStore = InMemoryDeckCacheStore()
    ) -> AddToDeckModel {
        AddToDeckModel(card: card, client: client, endpoints: endpoints, cache: cache, now: { DeckFixtures.now })
    }

    @Test func theDefaultSlotFollowsTheServersRule() {
        #expect(DeckSlot.defaultSlot(type: "Legend", supertype: nil) == .legend)
        #expect(DeckSlot.defaultSlot(type: "Legend", supertype: "Champion") == .legend, "starter legends are legends")
        #expect(DeckSlot.defaultSlot(type: "Rune", supertype: "Basic") == .rune)
        #expect(DeckSlot.defaultSlot(type: "Battlefield", supertype: nil) == .battlefield)
        #expect(DeckSlot.defaultSlot(type: "Spell", supertype: "Signature") == .main)
        #expect(DeckSlot.defaultSlot(type: "Unit", supertype: "Signature") == .main)
        #expect(DeckSlot.defaultSlot(type: "Unit", supertype: "Champion") == .champion)
        #expect(DeckSlot.defaultSlot(type: "Unit", supertype: nil) == .main)
        #expect(DeckSlot.defaultSlot(type: "Gear", supertype: nil) == .main)
        #expect(DeckSlot.defaultSlot(type: nil, supertype: "Token") == .main)
        #expect(DeckSlot.defaultSlot(for: DeckFixtures.signatureCard) == .main)
    }

    @Test func loadingGoesOnlinePicksTheFirstDeckAndReadsItsCopies() async {
        let client = StubCollectionClient(script: DeckFixtures.script())
        let model = makeModel(client: client)
        #expect(model.slot == .main)
        #expect(model.availability == .checking)
        await model.load()
        #expect(model.availability == .online(.lan))
        #expect(model.selectedDeckID == 1)
        #expect(model.selectedDeck.value?.id == 1)
        #expect(model.existingQuantity == 0)
        #expect(model.quantity == 1)
        #expect(model.canSubmit)
    }

    @Test func addingSendsOnePutWithTheDefaultSlotAndRefreshes() async throws {
        let client = StubCollectionClient(script: DeckFixtures.script())
        let cache = InMemoryDeckCacheStore()
        let refreshed = DeckDetail(
            id: 1, name: "Ahri tempo", format: "constructed",
            cards: DeckFixtures.ahriDetail.cards + [DeckFixtures.card("VEN-150", slot: .main, quantity: 1, name: "Acceleration Gate", type: "Spell", supertype: "Signature", owned: 0)],
            cardCount: 21, shortCount: 8
        )
        await client.update { $0.setDeckCard = .success(refreshed) }
        let model = makeModel(client: client, cache: cache)
        await model.load()
        await model.submit()

        let changes = await client.recording.deckChanges
        #expect(changes.count == 1)
        #expect(changes.first?.deckID == 1)
        #expect(changes.first?.change == DeckCardChange(cardID: "VEN-150", slot: .main, quantity: 1))
        #expect(model.submission.value == refreshed)
        #expect(model.selectedDeck.value == refreshed, "the sheet shows the server's refreshed deck")
        #expect(model.existingQuantity == 1)
        #expect(await cache.cache.details[1]?.deck == refreshed, "the detail screen's cache is refreshed too")
        #expect(await client.recording.decksValidators.count == 2, "the deck list is reloaded after the write")
    }

    @Test func theQuantityIsTheNewTotalOnTopOfWhatTheDeckHolds() async {
        let client = StubCollectionClient(script: DeckFixtures.script())
        let vi = Fixtures.vaultCard(code: "OGN-206", name: "Back to Back", type: "Spell")
        let model = makeModel(card: vi, client: client)
        await model.load()
        #expect(model.existingQuantity == 3)
        #expect(model.quantity == 4)
        model.slot = .sideboard
        #expect(model.existingQuantity == 0)
        #expect(model.quantity == 1, "changing the slot re-reads the copies held there")
        await model.submit()
        #expect(await client.recording.deckChanges.first?.change == DeckCardChange(cardID: "OGN-206", slot: .sideboard, quantity: 1))
    }

    @Test func offlineDisablesTheWriteWithAnExplanation() async {
        let client = StubCollectionClient(script: DeckFixtures.script())
        let endpoints = FixedEndpoints(.unavailable(.cellularOnly))
        let model = makeModel(client: client, endpoints: endpoints, cache: InMemoryDeckCacheStore(DeckFixtures.cache()))
        await model.load()
        #expect(model.availability == .offline(.cellularOnly))
        #expect(!model.canSubmit)
        let message = model.offlineMessage ?? ""
        #expect(message.contains(EndpointUnavailability.cellularOnly.message))
        #expect(message.contains("Wi-Fi or your home VPN"))
        await model.submit()
        #expect(await client.recording.deckChanges.isEmpty, "nothing is sent while offline")

        await endpoints.set(.available(.local, health: HealthReport(userVersion: 5)))
        await model.retryConnection()
        #expect(await endpoints.invalidations == 1)
        #expect(model.availability == .online(.local))
        #expect(model.offlineMessage == nil)
        #expect(model.canSubmit)
    }

    @Test func aRejectedWriteIsShownAndCanBeRetried() async {
        let client = StubCollectionClient(script: DeckFixtures.script())
        await client.update { $0.setDeckCard = .failure(.unauthorized) }
        let model = makeModel(client: client)
        await model.load()
        await model.submit()
        guard case .failed(let error) = model.submission else {
            Issue.record("expected a failure, got \(model.submission)")
            return
        }
        #expect(error == .unauthorized)
        #expect(model.canSubmit, "the button comes back for another try")
    }

    @Test func noDecksMeansNothingToSubmit() async {
        let client = StubCollectionClient(script: DeckFixtures.script(decks: []))
        let model = makeModel(client: client)
        await model.load()
        #expect(model.selectedDeckID == nil)
        #expect(!model.canSubmit)
    }
}

// MARK: - Accessibility

@Suite("Deck accessibility")
struct DeckAccessibilityTests {
    @Test func slotHeadersStackAtAccessibilitySizesSoNothingTruncates() {
        for size in [DynamicTypeSize.xSmall, .large, .xxxLarge] {
            #expect(DeckSlotHeader.Arrangement.fitting(size) == .inline, "\(size)")
        }
        for size in [DynamicTypeSize.accessibility1, .accessibility3, .accessibility5] {
            #expect(DeckSlotHeader.Arrangement.fitting(size) == .stacked, "\(size)")
        }
        #expect(DeckSlotHeader(title: DeckSlot.battlefield.title, count: 3).accessibilityLabel == "Battlefields, 3 cards")
    }

    @Test func rowsReadAsOneElementWithOwnership() {
        let short = DeckFixtures.card("OGN-206", slot: .main, quantity: 3, name: "Back to Back", owned: 2, usedElsewhere: 1)
        #expect(short.ownershipBadge == .short(2))
        #expect(short.accessibilitySummary == "3 × Back to Back, OGN-206, Main Deck, 2 short, 1 in other decks")

        let owned = DeckFixtures.card("RAD-R01", slot: .rune, quantity: 12, name: "Fury Rune", owned: 12)
        #expect(owned.ownershipBadge == .owned)
        #expect(owned.accessibilitySummary == "12 × Fury Rune, RAD-R01, Runes, owned")

        #expect(DeckFixtures.ahriDeck.accessibilitySummary == "Ahri tempo, Constructed, 26 cards, 3 short")
        #expect(DeckFixtures.sealedDeck.accessibilitySummary == "Sealed pool, Sealed, 4 cards")
    }

    @Test func slotTitlesMatchTheBuilder() {
        #expect(DeckSlot.allCases.map(\.title) == ["Legend", "Champion", "Runes", "Battlefields", "Main Deck", "Sideboard"])
        #expect(DeckIssue(code: "copy_limit").text == "Copy Limit")
    }
}

// MARK: - Transport

@Suite("Deck export over HTTP")
struct DeckExportClientTests {
    @Test func fetchesThePiltoverTextAsPlainText() async throws {
        let server = StubServer()
        server.on("/api/decks/1/export", StubResponse(status: 200, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(DeckFixtures.piltover.utf8)))
        let client = server.client()
        let text = try await client.deckExport(id: 1, style: .piltover)
        #expect(text == DeckFixtures.piltover)
        let request = try #require(server.requests.first)
        #expect(request.method == "GET")
        #expect(request.url.query() == "style=piltover")
    }

    @Test func aMissingDeckIsNotFound() async {
        let server = StubServer()
        let client = server.client()
        await #expect(throws: ServerError.notFound) {
            try await client.deckExport(id: 9, style: .text)
        }
    }
}

// MARK: - Cache file

@Suite("Deck cache file")
struct DeckCacheFileTests {
    @Test func roundTripsThroughDiskAndTreatsGarbageAsEmpty() async throws {
        let directory = URL.temporaryDirectory.appending(path: "DeckCache-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "decks.json")
        let store = FileDeckCacheStore(url: url)
        #expect(await store.load() == .empty)
        try await store.save(DeckFixtures.cache())
        #expect(await FileDeckCacheStore(url: url).load() == DeckFixtures.cache())

        try Data("not json".utf8).write(to: url)
        #expect(await FileDeckCacheStore(url: url).load() == .empty)
    }
}
