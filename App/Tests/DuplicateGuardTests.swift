import Foundation
import RiftboundRecognizer
import Testing
@testable import RiftboundScannerApp

/// The duplicate capture guard (ADR-002, decision 16): a card the feeder
/// fed twice is caught at identify time, kept out of bulk acceptance, and
/// dropped from the review queue as `rejected(duplicateCapture)` with no
/// ledger item.
@Suite("Duplicate guard")
struct DuplicateGuardTests {
    private let batch = Fixtures.batch(purpose: .collection, defaultFinish: .normal)

    private func scan(_ cards: [Card] = [Fixtures.vi, Fixtures.jinx], descriptor: OrientedDescriptor = Fixtures.descriptor, at offset: TimeInterval = 0, analysed: Bool = true) -> ScanRecord {
        Fixtures.record(
            batch: batch.id,
            candidates: cards,
            capturedAt: Fixtures.epoch.addingTimeInterval(offset),
            analysis: analysed ? Fixtures.analysis(for: Fixtures.result(cards: cards, descriptor: descriptor)) : nil
        )
    }

    @Test func aNearIdenticalDescriptorOfTheSameArtIsADuplicate() {
        let first = scan()
        let second = scan(at: 1)
        #expect(DuplicateGuard.standard.duplicate(of: second, among: [first]) == first.id)
        let marked = DuplicateGuard.standard.marking(second, among: [first])
        #expect(marked.analysis?.duplicateOf == first.id)
        #expect(marked.id == second.id)
        #expect(marked.candidates == second.candidates)
        #expect(marked.analysis?.descriptor == second.analysis?.descriptor)
    }

    @Test func aDifferentArtGroupOrADifferentPhotoIsNotADuplicate() {
        let vi = scan()
        let jinx = scan([Fixtures.jinx, Fixtures.vi], at: 1)
        #expect(DuplicateGuard.standard.duplicate(of: jinx, among: [vi]) == nil, "same descriptor, different top art group")
        let otherPhoto = scan(descriptor: Fixtures.otherDescriptor, at: 2)
        #expect(DuplicateGuard.standard.duplicate(of: otherPhoto, among: [vi]) == nil, "cosine 0 is far under 0.985")
        #expect(DuplicateGuard.standard.marking(otherPhoto, among: [vi]).analysis?.duplicateOf == nil)
    }

    /// The same art twice, `a` and the base printing: one `ArtGroup`, so it
    /// still counts (the printed code, not the art, tells them apart).
    @Test func sameArtSiblingsShareAGroup() {
        let base = scan([Fixtures.vi])
        let alternate = scan([Fixtures.viAlt], at: 1)
        #expect(DuplicateGuard.standard.duplicate(of: alternate, among: [base]) == base.id)
    }

    @Test func onlyTheLastFiveCapturesAreCompared() {
        let first = scan()
        let fillers = (1...5).map { scan([Fixtures.jinx], descriptor: Fixtures.otherDescriptor, at: TimeInterval($0)) }
        let latest = scan(at: 6)
        #expect(DuplicateGuard.standard.duplicate(of: latest, among: [first] + fillers) == nil, "the match is six captures back")
        #expect(DuplicateGuard.standard.duplicate(of: latest, among: [first] + fillers.dropLast()) == first.id, "five back is still in the window")
    }

    @Test func theMostSimilarMatchWinsAndUnanalysedScansAreSkipped() {
        let far = Fixtures.record(batch: batch.id, analysis: Fixtures.analysis(for: Fixtures.result(cards: [Fixtures.vi], descriptor: OrientedDescriptor(descriptor: CardDescriptor(wholeDifferenceHash: ImageHash(bits: 0), wholePerceptualHash: ImageHash(bits: 0), artDifferenceHash: ImageHash(bits: 0), featurePrint: FeaturePrint(elements: [0.99, 0.141, 0])), orientation: .upright))))
        let exact = scan(at: 1)
        let unanalysed = scan(at: 2, analysed: false)
        let latest = scan(at: 3)
        #expect(DuplicateGuard.standard.duplicate(of: latest, among: [far, exact, unanalysed]) == exact.id)
        #expect(DuplicateGuard.standard.duplicate(of: latest, among: [far]) == far.id, "0.99 clears the threshold on its own")
        #expect(DuplicateGuard.standard.duplicate(of: unanalysed, among: [exact]) == nil, "a scan without an analysis cannot be compared")
    }

    @Test func theOffGuardComparesAgainstNothing() {
        let first = scan()
        #expect(DuplicateGuard.off.duplicate(of: scan(at: 1), among: [first]) == nil)
        #expect(DuplicateGuard.standard.similarityThreshold == 0.985)
        #expect(DuplicateGuard.standard.window == 5)
    }

    /// Two feeds of one card in a sealed-box run: the second is a possible
    /// duplicate, accepting the confident scans takes only the first, and
    /// "Drop" in the queue writes `rejected(duplicateCapture)`, which owes
    /// the ledger nothing.
    @Test func aRefedCardIsCaughtHeldBackAndDroppedWithoutALedgerItem() async throws {
        let store = InMemoryScanStore()
        let feeder = StubFeeder(script: [.fed, .fed])
        let same = Fixtures.result(cards: [Fixtures.vi, Fixtures.jinx], codeReading: Fixtures.viCodeReading)
        let identifier = SequenceIdentifier(results: [same, same])
        let model = ScannerModel(
            camera: StubCamera(),
            feeder: feeder,
            identifier: identifier,
            store: store,
            vault: Fixtures.vault,
            directory: Fixtures.directory,
            makeBatch: Fixtures.makeBatch,
            now: { Fixtures.epoch },
            makeID: Fixtures.unsampledIDs,
            settleDelay: .zero
        )
        await model.start()
        await model.beginNewBatch(ScanBatch.Setup(label: "box 1", purpose: .collection, product: .sealedBox(set: SetCode(rawValue: "OGN")!), defaultFinish: .normal))
        let batch = try #require(model.batch)
        model.connectFeeder()
        model.startAutoScan()
        await model.autoScanTask?.value

        #expect(model.runRecords.count == 2)
        let first = try #require(model.runRecords.first)
        let second = try #require(model.runRecords.last)
        #expect(first.analysis?.duplicateOf == nil)
        #expect(second.analysis?.duplicateOf == first.id)
        #expect(model.tier(of: first) == .confident)
        #expect(model.tier(of: second) == .possibleDuplicate)
        #expect(model.runTierCounts[.possibleDuplicate] == 1)
        #expect(model.runTierCounts.acceptable == 1)
        #expect(await store.records(in: batch.id).last?.analysis?.duplicateOf == first.id, "the mark is saved with the record")

        await model.acceptConfidentScans()
        #expect(model.acceptedCount == 1)
        var stored = await store.records(in: batch.id)
        #expect(stored.first { $0.id == first.id }?.verdict == .correct)
        #expect(stored.first { $0.id == second.id }?.verdict == .pending, "a possible duplicate is excluded from bulk acceptance")

        let queue = ReviewQueueModel(batch: batch, store: store, directory: Fixtures.directory, vault: Fixtures.vault)
        await queue.load()
        #expect(queue.queue.value?.map(\.id) == [second.id])
        #expect(queue.currentKind == .possibleDuplicate)
        #expect(queue.duplicateOf?.id == first.id)
        await queue.drop()
        #expect(queue.progress == .done(.init(confirmed: 0, corrected: 0, rejected: 1, skipped: 0)))

        stored = await store.records(in: batch.id)
        let dropped = try #require(stored.first { $0.id == second.id })
        #expect(dropped.verdict == .rejected(.duplicateCapture))
        #expect(dropped.decisions.map(\.source) == [.human])
        #expect(LedgerDeltaBuilder.items(record: dropped, previousState: ScanSyncState(), batch: batch, vault: Fixtures.vault).isEmpty, "a dropped duplicate owes the ledger nothing")
        let kept = try #require(stored.first { $0.id == first.id })
        #expect(LedgerDeltaBuilder.items(record: kept, previousState: ScanSyncState(), batch: batch, vault: Fixtures.vault).count == 1)
    }

    @Test func keepBothConfirmsTheDuplicateAsASecondCopy() async throws {
        let store = InMemoryScanStore()
        await store.save(batch)
        let first = scan()
        let second = DuplicateGuard.standard.marking(scan(at: 1), among: [first])
        try await store.append(first, photo: Data(), rectified: nil)
        try await store.append(second, photo: Data(), rectified: nil)
        let queue = ReviewQueueModel(batch: batch, store: store, directory: Fixtures.directory, vault: Fixtures.vault)
        await queue.load()
        #expect(queue.current?.id == second.id)
        await queue.keepBoth()
        let stored = try #require(await store.records(in: batch.id).first { $0.id == second.id })
        #expect(stored.verdict == .correct)
        #expect(stored.decisions.map(\.source) == [.human])
        #expect(stored.confirmedCardID == Fixtures.vi.id)
        #expect(LedgerDeltaBuilder.items(record: stored, previousState: ScanSyncState(), batch: batch, vault: Fixtures.vault).count == 1, "a kept copy ledgers like any other")
    }
}
