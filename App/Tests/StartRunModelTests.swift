import Foundation
import RiftboundRecognizer
import Testing
@testable import RiftboundScannerApp

/// A run-setup memory that lives for one test.
actor InMemoryRunSetupStore: RunSetupStoring {
    private(set) var memory: RunSetupMemory?
    private(set) var saveCount = 0
    var failure: (any Error)?

    init(_ memory: RunSetupMemory? = nil) {
        self.memory = memory
    }

    func load() -> RunSetupMemory? { memory }

    func save(_ memory: RunSetupMemory) throws {
        if let failure { throw failure }
        self.memory = memory
        saveCount += 1
    }
}

@Suite("Start run sheet")
struct StartRunModelTests {
    private let ogn = SetCode(rawValue: "OGN")!
    private let rad = SetCode(rawValue: "RAD")!
    private let index = IndexSummary(builtAt: Fixtures.epoch, entryCount: 1408, formatVersion: 1)

    private func makeModel(memory: InMemoryRunSetupStore = InMemoryRunSetupStore()) async -> StartRunModel {
        let model = StartRunModel(memory: memory, sets: [ogn, rad], index: index, appVersion: "0.2.0")
        await model.load()
        return model
    }

    @Test func aFreshSheetProposesACollectionRunOfASealedBoxInNormal() async {
        let model = await makeModel()
        #expect(model.isLoaded)
        #expect(model.purpose == .collection)
        #expect(model.productKind == .sealedBox)
        #expect(model.set == ogn)
        #expect(model.defaultFinish == .normal)
        #expect(model.setup == ScanBatch.Setup(label: "", purpose: .collection, product: .sealedBox(set: ogn), defaultFinish: .normal))
        #expect(model.suggestedLabel == "OGN box")
        #expect(model.canStart)
        #expect(model.engineLine.contains("408 printings"), "the count is locale-formatted")
        #expect(model.engineLine.contains("0.2.0"))
    }

    @Test func theLastChoiceIsRemembered() async {
        let memory = InMemoryRunSetupStore(RunSetupMemory(purpose: .calibration, product: .sealedBox(set: rad), defaultFinish: .foil))
        let model = await makeModel(memory: memory)
        #expect(model.purpose == .calibration)
        #expect(model.productKind == .sealedBox)
        #expect(model.set == rad)
        #expect(model.defaultFinish == .foil)
        #expect(model.label.isEmpty, "the label names one sitting and is never remembered")

        let other = await makeModel(memory: InMemoryRunSetupStore(RunSetupMemory(purpose: .collection, product: .other("trade binder"), defaultFinish: nil)))
        #expect(other.productKind == .other)
        #expect(other.otherProductName == "trade binder")
        #expect(other.defaultFinish == .normal)
        #expect(other.suggestedLabel == "trade binder")

        let unknownSet = await makeModel(memory: InMemoryRunSetupStore(RunSetupMemory(purpose: .collection, product: .sealedBox(set: SetCode(rawValue: "ZZZ")!), defaultFinish: .normal)))
        #expect(unknownSet.set == ogn, "a set the index no longer knows falls back to the first")
    }

    @Test func startingSavesTheChoiceAndHandsOverTheSetup() async throws {
        let memory = InMemoryRunSetupStore()
        let model = await makeModel(memory: memory)
        model.label = "  box 1  "
        model.productKind = .loose
        model.defaultFinish = .foil
        var begun: ScanBatch.Setup?
        await model.start { begun = $0 }
        #expect(begun == ScanBatch.Setup(label: "box 1", purpose: .collection, product: .loose, defaultFinish: .foil))
        #expect(await memory.memory == RunSetupMemory(purpose: .collection, product: .loose, defaultFinish: .foil))
        #expect(await memory.saveCount == 1)
        #expect(model.saveProblem == nil)
    }

    @Test func aBlankLabelTakesTheSuggestedOne() async {
        let model = await makeModel()
        model.set = rad
        var begun: ScanBatch.Setup?
        await model.start { begun = $0 }
        #expect(begun?.label == "RAD box")
        #expect(begun?.product == .sealedBox(set: rad))
    }

    @Test func anOtherProductNeedsAName() async {
        let model = await makeModel()
        model.productKind = .other
        #expect(model.canStart == false)
        model.otherProductName = " binder "
        #expect(model.canStart)
        #expect(model.setup.product == .other("binder"))
    }

    @Test func aMemoryThatCannotBeWrittenStillStartsTheRun() async {
        let memory = InMemoryRunSetupStore()
        await memory.setFailure(StubFailure())
        let model = await makeModel(memory: memory)
        var begun: ScanBatch.Setup?
        await model.start { begun = $0 }
        #expect(begun != nil)
        #expect(model.saveProblem != nil)
    }

    @Test func theDefaultsStoreRoundTrips() async throws {
        let suite = "StartRunModelTests-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        // UserDefaults is not Sendable: the store gets its own instance.
        let store = DefaultsRunSetupStore(defaults: UserDefaults(suiteName: suite)!)
        #expect(await store.load() == nil)
        try await store.save(RunSetupMemory(purpose: .collection, product: .sealedBox(set: ogn), defaultFinish: .normal))
        #expect(await store.load() == RunSetupMemory(purpose: .collection, product: .sealedBox(set: ogn), defaultFinish: .normal))
    }
}

extension InMemoryRunSetupStore {
    func setFailure(_ failure: any Error) {
        self.failure = failure
    }
}
