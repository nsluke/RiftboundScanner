import Foundation
import Testing
@testable import RiftboundScannerApp

/// Collection -> Add card: one `manual:<id>` ledger item per add, kept in
/// `manual.json` and sent through the same outbox as scan decisions
/// (ADR-002, decision 13).
@MainActor
@Suite("Manual add")
struct ManualItemTests {
    private func makeStore() -> ManualItemStore {
        ManualItemStore(fileURL: URL.temporaryDirectory.appending(path: "ManualItemTests-\(UUID().uuidString)/manual.json"))
    }

    private func makeModel(store: ManualItemStore, id: UUID = UUID()) -> AddCardModel {
        AddCardModel(vault: Fixtures.vault, store: store, now: { Fixtures.epoch }, makeID: { id })
    }

    @Test func addingACardEnqueuesOneManualItem() async throws {
        let store = makeStore()
        let id = UUID()
        let model = makeModel(store: store, id: id)
        model.query = "jinx"
        #expect(model.results.map(\.code) == ["OGN-002", "OGN-002-P"])
        model.select(try #require(model.results.last))
        #expect(model.finishResolution == .prompt(default: .normal), "the fixture promo lists both finishes")
        #expect(model.finish == .normal, "pre-selected from the policy")
        model.finish = .foil
        model.quantity = 2

        let item = try #require(await model.add())
        #expect(item.clientRef == "manual:\(id.uuidString)")
        #expect(item.cardKey == "OGN-002-P")
        #expect(item.finish == .foil)
        #expect(item.quantity == 2)
        #expect(item.condition == "NM")
        #expect(item.createdAt == Fixtures.epoch)
        #expect(item.state == .queued)
        #expect(model.outcome.value == item)

        let stored = await store.allItems()
        #expect(stored == [item], "exactly one item, and it is on disk")
        #expect(await store.pending() == [item])
        guard case .delta(let delta) = item.ledgerItem else {
            Issue.record("a manual add is a +N delta")
            return
        }
        #expect(delta.clientRef == item.clientRef)
        #expect(delta.cardKey == "OGN-002-P")
        #expect(delta.quantityDelta == 2)
        #expect(delta.finish == .foil)
        #expect(delta.condition == "NM")
        #expect(delta.scanID == nil)
    }

    @Test func aSingleFinishPrintingIsSentWithItsFinishAndABothFinishOneWithTheChoice() async throws {
        let store = makeStore()
        let rune = makeModel(store: store)
        rune.query = "RAD-R01"
        rune.select(try #require(rune.results.first))
        #expect(rune.finishResolution == .forced(.normal))
        #expect(rune.finish == .normal)
        let runeItem = try #require(await rune.add())
        #expect(runeItem.finish == .normal)

        let vi = makeModel(store: store)
        vi.query = "ogn 001"
        #expect(vi.results.map(\.code) == ["OGN-001", "OGN-001a"], "a space in the query matches the hyphen in the code")
        vi.select(try #require(vi.results.first))
        #expect(vi.finishResolution == .prompt(default: .normal))
        #expect(vi.finish == .normal)
        vi.finish = .foil
        let viItem = try #require(await vi.add())
        #expect(viItem.finish == .foil)
        #expect(await store.allItems().count == 2)
    }

    @Test func nothingIsQueuedWithoutASelection() async {
        let store = makeStore()
        let model = makeModel(store: store)
        #expect(model.canAdd == false)
        #expect(await model.add() == nil)
        #expect(await store.allItems().isEmpty)
        model.query = "nothing like this"
        #expect(model.results.isEmpty)
    }

    /// The engine sends the item in a ledger page, records the server's
    /// answer in `manual.json`, and the outbox empties.
    @Test func theSyncEngineSendsAManualItemAndRecordsTheAnswer() async throws {
        let world = try await SyncEngineTests.World()
        let model = AddCardModel(vault: Fixtures.vault, store: world.manual, now: { Fixtures.epoch }, makeID: { UUID() })
        model.query = "OGN-002-P"
        model.select(try #require(model.results.first))
        let item = try #require(await model.add())

        await world.engine.flush()
        let sent = await world.client.recording.syncRequests
        #expect(sent.count == 1)
        #expect(sent.first?.items.map(\.clientRef) == [item.clientRef])
        #expect(await world.outbox.isEmpty)
        let stored = try #require(await world.manual.allItems().first)
        #expect(stored.state == .applied(ledgerID: 1, cardID: "OGN-002-P", finish: nil))
        #expect(await world.manual.pending().isEmpty)
        #expect(world.engine.manualItems == [stored])
        #expect(world.engine.ledgerGeneration == 1)

        // Flushing again sends nothing: the item is acknowledged.
        await world.engine.flush()
        #expect(await world.client.recording.syncRequests.count == 1)
    }

    @Test func anUnansweredManualItemSurvivesALostOutbox() async throws {
        let world = try await SyncEngineTests.World()
        await world.client.update { $0.syncFailure = .timedOut }
        let item = ManualItem(id: UUID(), cardKey: "OGN-001", finish: .normal, quantity: 1, createdAt: Fixtures.epoch)
        try await world.manual.add(item)
        await world.engine.flush()
        #expect(await world.outbox.manualCount == 1)
        #expect(await world.manual.allItems().first?.state == .sent, "handed to the server without an answer")

        try FileManager.default.removeItem(at: world.directory.appending(path: "outbox.json"))
        let relaunched = world.relaunched()
        #expect(await relaunched.outbox.isEmpty)
        await relaunched.client.update { $0.syncFailure = nil }
        await relaunched.engine.flush()
        #expect(await relaunched.client.recording.syncRequests.last?.items.map(\.clientRef) == [item.clientRef], "rebuilt from manual.json and sent")
        #expect(await relaunched.manual.allItems().first?.state.isApplied == true)
    }

    @Test func aTerminalAnswerIsKeptAndNotResent() async throws {
        let world = try await SyncEngineTests.World()
        let item = ManualItem(id: UUID(), cardKey: "ZZZ-999", finish: nil, quantity: 1, createdAt: Fixtures.epoch)
        await world.client.update { $0.itemStatuses[item.clientRef] = .unknownCard }
        try await world.manual.add(item)
        await world.engine.flush()
        #expect(await world.manual.allItems().first?.state == .terminal(.unknownCard(catalogVersion: "cat-1")))
        #expect(await world.outbox.isEmpty)
        await world.engine.flush()
        #expect(await world.client.recording.syncRequests.count == 1)
    }
}
