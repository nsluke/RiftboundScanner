import Foundation
import RiftboundRecognizer
import Testing
@testable import RiftboundScannerApp

@Suite("Review queue")
struct ReviewQueueModelTests {
    private let batch = Fixtures.batch()
    private let store = InMemoryScanStore()

    private func makeModel(
        records: [ScanRecord],
        rule: ConfidenceRule = .default,
        mode: ReviewQueueModel.Mode = .pending,
        sample: @escaping ReviewQueueModel.Sampler = { Array($0.prefix($1)) }
    ) async throws -> ReviewQueueModel {
        await store.save(batch)
        for record in records {
            try await store.append(record, photo: Data(), rectified: nil)
        }
        let model = ReviewQueueModel(batch: batch, store: store, directory: Fixtures.directory, vault: Fixtures.vault, rule: rule, mode: mode, sample: sample)
        await model.load()
        return model
    }

    /// A confident scan whose id the audit sample never picks.
    private func unsampledConfident(at offset: TimeInterval = 0) -> ScanRecord {
        Fixtures.record(id: Fixtures.uuid(firstByte: Fixtures.unsampledByte), batch: batch.id, capturedAt: Fixtures.epoch.addingTimeInterval(offset))
    }

    @Test func queuesOnlyUncertainPendingScansInCaptureOrder() async throws {
        let later = Fixtures.record(batch: batch.id, capturedAt: Fixtures.epoch.addingTimeInterval(20), codeRead: false)
        let earlier = Fixtures.record(batch: batch.id, capturedAt: Fixtures.epoch.addingTimeInterval(10), score: 0.8)
        let confident = unsampledConfident()
        let decided = Fixtures.record(batch: batch.id, verdict: .correct, codeRead: false)
        let model = try await makeModel(records: [later, confident, decided, earlier])

        #expect(model.queue.value?.map(\.id) == [earlier.id, later.id])
        #expect(model.progress == .reviewing(position: 1, of: 2))
        #expect(model.current?.id == earlier.id)
        #expect(model.currentKind == .uncertain(.weakArtMatch))
    }

    /// Audit rows follow the uncertain ones (ADR-002 §6) and their verdicts
    /// are `audit` decisions, so the server can bound precision from them.
    @Test func auditRowsFollowTheUncertainOnesAndWriteAuditDecisions() async throws {
        let uncertain = Fixtures.record(batch: batch.id, capturedAt: Fixtures.epoch.addingTimeInterval(30), codeRead: false)
        let heldEarly = Fixtures.record(id: Fixtures.uuid(firstByte: 0), batch: batch.id, capturedAt: Fixtures.epoch.addingTimeInterval(10))
        let heldLate = Fixtures.record(id: Fixtures.uuid(firstByte: 12), batch: batch.id, capturedAt: Fixtures.epoch.addingTimeInterval(20))
        let accepted = unsampledConfident(at: 15)
        let model = try await makeModel(records: [heldLate, accepted, uncertain, heldEarly])

        #expect(model.queue.value?.map(\.id) == [uncertain.id, heldEarly.id, heldLate.id])
        #expect(model.progress == .reviewing(position: 1, of: 3))
        #expect(model.currentKind == .uncertain(.noCodeRead))

        await model.confirm()
        #expect(model.current?.id == heldEarly.id)
        #expect(model.currentKind == .audit)
        await model.confirm()
        #expect(model.currentKind == .audit)
        await model.correct(to: Fixtures.jinx.id)
        #expect(model.progress == .done(.init(confirmed: 2, corrected: 1, rejected: 0, skipped: 0)))

        let stored = await store.records(in: batch.id)
        #expect(stored.first { $0.id == uncertain.id }?.decisions.map(\.source) == [.human])
        #expect(stored.first { $0.id == heldEarly.id }?.decisions.map(\.source) == [.audit])
        #expect(stored.first { $0.id == heldEarly.id }?.verdict == .correct)
        #expect(stored.first { $0.id == heldLate.id }?.decisions.map(\.source) == [.audit])
        #expect(stored.first { $0.id == heldLate.id }?.verdict == .corrected(Fixtures.jinx.id))
        #expect(stored.first { $0.id == accepted.id }?.verdict == .pending, "not sampled, not in the queue; the strip accepts it")
    }

    @Test func theAuditRateComesFromTheRuleTheQueueWasOpenedWith() async throws {
        let bucketTwo = Fixtures.record(id: Fixtures.uuid(firstByte: 2), batch: batch.id)
        let bucketZero = Fixtures.record(id: Fixtures.uuid(firstByte: 10), batch: batch.id, capturedAt: Fixtures.epoch.addingTimeInterval(1))
        let model = try await makeModel(records: [bucketTwo, bucketZero], rule: ConfidenceRule(randomAudits: 300))
        #expect(model.queue.value?.map(\.id) == [bucketZero.id], "at 0.1 only bucket zero is sampled")
    }

    /// Spot-check 10: a sample of the run's accepted scans, re-judged as
    /// `spotCheck` decisions appended after the machine's.
    @Test func aSpotCheckReJudgesAcceptedScansWithSpotCheckDecisions() async throws {
        let accepted = (0..<4).map { offset in
            Fixtures.record(id: Fixtures.uuid(firstByte: Fixtures.unsampledByte), batch: batch.id, verdict: .correct, source: .autoAccepted, capturedAt: Fixtures.epoch.addingTimeInterval(Double(offset)))
        }
        let human = Fixtures.record(batch: batch.id, verdict: .correct, source: .human)
        let pending = unsampledConfident(at: 9)
        let candidates = accepted.map(\.id) + [human.id, pending.id]
        // Picks the last `limit` offered, to show the sampler decides.
        let model = try await makeModel(records: accepted + [human, pending], mode: .spotCheck(candidates: candidates, limit: 2)) { Array($0.suffix($1)) }

        #expect(model.queue.value?.map(\.id) == [accepted[2].id, accepted[3].id], "only accepted scans qualify; rows run in capture order")
        #expect(model.currentKind == .spotCheck)
        #expect(model.progress == .reviewing(position: 1, of: 2))

        await model.confirm()
        await model.correct(to: Fixtures.jinx.id)
        #expect(model.progress == .done(.init(confirmed: 1, corrected: 1, rejected: 0, skipped: 0)))

        let stored = await store.records(in: batch.id)
        let confirmed = try #require(stored.first { $0.id == accepted[2].id })
        #expect(confirmed.decisions.map(\.source) == [.autoAccepted, .spotCheck])
        #expect(confirmed.decisions.map(\.seq) == [1, 2])
        #expect(confirmed.verdict == .correct)
        let corrected = try #require(stored.first { $0.id == accepted[3].id })
        #expect(corrected.decisions.map(\.source) == [.autoAccepted, .spotCheck])
        #expect(corrected.confirmedCardID == Fixtures.jinx.id)
        #expect(stored.first { $0.id == accepted[0].id }?.decisions.count == 1, "unsampled scans are untouched")
        #expect(stored.first { $0.id == human.id }?.decisions.count == 1)
    }

    @Test func aSpotCheckWithNothingAcceptedSaysSo() async throws {
        let pending = unsampledConfident()
        let model = try await makeModel(records: [pending], mode: .spotCheck(candidates: [pending.id], limit: 10))
        #expect(model.progress == .nothingToReview)
        #expect(model.mode.isSpotCheck)
    }

    @Test func confirmingWritesCorrectAndAdvances() async throws {
        let first = Fixtures.record(batch: batch.id, capturedAt: Fixtures.epoch, codeRead: false)
        let second = Fixtures.record(batch: batch.id, capturedAt: Fixtures.epoch.addingTimeInterval(1), codeRead: false)
        let model = try await makeModel(records: [first, second])

        await model.confirm()
        #expect(model.current?.id == second.id)
        #expect(model.progress == .reviewing(position: 2, of: 2))
        let stored = await store.records(in: batch.id)
        let decided = try #require(stored.first { $0.id == first.id })
        #expect(decided.verdict == .correct)
        #expect(decided.verdictAt == Fixtures.epoch)
        #expect(decided.decisions.map(\.source) == [.human], "a reviewed verdict is a human label")
        #expect(decided.decisions.first?.cardID == Fixtures.vi.id)
        #expect(model.tally.confirmed == 1)
    }

    @Test func correctingToAnotherCardWritesCorrectedButToTheTopCandidateWritesCorrect() async throws {
        let first = Fixtures.record(batch: batch.id, capturedAt: Fixtures.epoch, codeRead: false)
        let second = Fixtures.record(batch: batch.id, capturedAt: Fixtures.epoch.addingTimeInterval(1), codeRead: false)
        let model = try await makeModel(records: [first, second])

        await model.correct(to: Fixtures.jinx.id)
        await model.correct(to: Fixtures.vi.id)
        let stored = await store.records(in: batch.id)
        #expect(stored.first { $0.id == first.id }?.verdict == .corrected(Fixtures.jinx.id))
        #expect(stored.first { $0.id == first.id }?.confirmedCardID == Fixtures.jinx.id)
        #expect(stored.first { $0.id == second.id }?.verdict == .correct)
        #expect(stored.allSatisfy { $0.decisions.allSatisfy { $0.source == .human } })
        #expect(model.tally == .init(confirmed: 1, corrected: 1, rejected: 0, skipped: 0))
    }

    @Test func rejectingAndSkippingAdvanceAndFinishWithADoneState() async throws {
        let first = Fixtures.record(batch: batch.id, capturedAt: Fixtures.epoch, codeRead: false)
        let second = Fixtures.record(batch: batch.id, capturedAt: Fixtures.epoch.addingTimeInterval(1), codeRead: false)
        let model = try await makeModel(records: [first, second])

        await model.reject(.notACard)
        model.skip()
        #expect(model.progress == .done(.init(confirmed: 0, corrected: 0, rejected: 1, skipped: 1)))
        #expect(model.current == nil)
        let stored = await store.records(in: batch.id)
        #expect(stored.first { $0.id == first.id }?.verdict == .rejected(.notACard))
        #expect(stored.first { $0.id == second.id }?.verdict == .pending, "skipping leaves the scan pending")

        // Verdicts after the end are ignored rather than crashing.
        await model.confirm()
        model.skip()
        #expect(model.progress == .done(.init(confirmed: 0, corrected: 0, rejected: 1, skipped: 1)))
    }

    @Test func aBatchWithNothingUncertainSaysSo() async throws {
        let model = try await makeModel(records: [unsampledConfident()])
        #expect(model.progress == .nothingToReview)
    }

    @Test func dominantSetFollowsTheMostCommonTopCandidate() async throws {
        let rune = Fixtures.record(batch: batch.id, candidates: [Fixtures.radRune])
        let model = try await makeModel(records: [rune, Fixtures.record(batch: batch.id), Fixtures.record(batch: batch.id)])
        #expect(model.dominantSet?.rawValue == "OGN")
    }

    @Test func storageFailureIsSurfacedAndDoesNotAdvance() async throws {
        let record = Fixtures.record(batch: batch.id, codeRead: false)
        let model = try await makeModel(records: [record])
        await store.deleteBatch(batch.id)
        await model.confirm()
        #expect(model.storageProblem != nil)
        #expect(model.current?.id == record.id)
        model.dismissStorageProblem()
        #expect(model.storageProblem == nil)
    }
}

/// Finish and printing are inherited from the decision log and written as
/// `.set` only on change (ADR-002, decisions 3 and 13); the five tiers order
/// the queue (ADR-002 §6).
@Suite("Review queue finish and printing")
struct ReviewQueueOverrideTests {
    private let store = InMemoryScanStore()
    private let promo = PrintingKey(rawValue: "OGN-002-P")

    private func makeModel(batch: ScanBatch, records: [ScanRecord], mode: ReviewQueueModel.Mode = .pending) async throws -> ReviewQueueModel {
        await store.save(batch)
        for record in records {
            try await store.append(record, photo: Data(), rectified: nil)
        }
        let model = ReviewQueueModel(batch: batch, store: store, directory: Fixtures.directory, vault: Fixtures.vault, mode: mode) { Array($0.prefix($1)) }
        await model.load()
        return model
    }

    private func items(_ record: ScanRecord, batch: ScanBatch) -> [LedgerSyncItem] {
        LedgerDeltaBuilder.items(record: record, previousState: ScanSyncState(), batch: batch, vault: Fixtures.vault)
    }

    private func cardKey(of item: LedgerSyncItem?) -> String? {
        if case .delta(let delta)? = item { return delta.cardKey }
        return nil
    }

    private func finish(of item: LedgerSyncItem?) -> Finish? {
        if case .delta(let delta)? = item { return delta.finish }
        return nil
    }

    /// Vi (OGN-001) comes in both finishes: the toggle shows with the batch
    /// default pre-selected; confirming untouched writes `.inherit`, toggling
    /// writes `.set(.foil)`.
    @Test func aBothFinishCardRecordsSetFoilOnlyWhenToggled() async throws {
        let batch = Fixtures.batch(purpose: .collection, defaultFinish: .normal)
        let untouched = Fixtures.record(batch: batch.id, capturedAt: Fixtures.epoch, codeRead: false)
        let toggled = Fixtures.record(batch: batch.id, capturedAt: Fixtures.epoch.addingTimeInterval(1), codeRead: false)
        let model = try await makeModel(batch: batch, records: [untouched, toggled])

        #expect(model.asksForFinish)
        #expect(model.finishResolution == .prompt(default: .normal))
        #expect(model.inheritedFinish == .normal)
        #expect(model.selectedFinish == .normal, "pre-selected from the batch default")
        #expect(model.finishOverride == .inherit)
        await model.confirm()

        #expect(model.current?.id == toggled.id)
        #expect(model.selectedFinish == .normal, "the selection resets per scan")
        model.selectedFinish = .foil
        #expect(model.finishOverride == .set(.foil))
        await model.confirm()

        let stored = await store.records(in: batch.id)
        let first = try #require(stored.first { $0.id == untouched.id })
        #expect(first.decisions.map(\.finish) == [.inherit])
        #expect(first.effectiveFinish == nil)
        #expect(finish(of: items(first, batch: batch).first) == .normal, "the batch default, derived the same way on both sides")
        let second = try #require(stored.first { $0.id == toggled.id })
        #expect(second.decisions.map(\.finish) == [.set(.foil)])
        #expect(second.effectiveFinish == .foil)
        #expect(finish(of: items(second, batch: batch).first) == .foil)
    }

    /// The fixture vault's RAD-R01 is normal-only: no toggle, no override.
    @Test func aSingleFinishPrintingNeverAsksAndNeverWritesAFinish() async throws {
        let batch = Fixtures.batch(purpose: .collection, defaultFinish: .foil)
        let rune = Fixtures.record(batch: batch.id, candidates: [Fixtures.radRune], codeRead: false)
        let model = try await makeModel(batch: batch, records: [rune])
        #expect(model.finishResolution == .forced(.normal))
        #expect(model.asksForFinish == false)
        model.selectedFinish = .foil
        #expect(model.finishOverride == .inherit, "a forced finish ignores the control")
        await model.confirm()
        let stored = try #require(await store.records(in: batch.id).first)
        #expect(stored.decisions.first?.finish == .inherit)
        #expect(finish(of: items(stored, batch: batch).first) == .normal)
    }

    /// Jinx is recognised as OGN-002; the promo OGN-002-P looks the same. In a
    /// loose pile the scan is "Pick printing"; choosing the promo sets the
    /// ledger printing while the confirmed card stays the base.
    @Test func choosingAPromoSetsTheLedgerPrintingAndKeepsTheConfirmedCard() async throws {
        let batch = Fixtures.makeBatch(ScanBatch.Setup(label: "pile", purpose: .collection, product: .loose, defaultFinish: .normal))
        let jinx = Fixtures.record(batch: batch.id, candidates: [Fixtures.jinx, Fixtures.vi])
        let model = try await makeModel(batch: batch, records: [jinx])

        #expect(model.currentKind == .pickPrinting)
        let options = try #require(model.printingOptions)
        #expect(options.shown.map(\.code) == ["OGN-002", "OGN-002-P"])
        #expect(model.selectedPrinting == PrintingKey(rawValue: "OGN-002"), "pre-selected: the recognised printing")
        #expect(model.printingOverride == .inherit)

        model.selectedPrinting = promo
        #expect(model.printingOverride == .set(promo))
        #expect(model.finishResolution == .prompt(default: .normal), "the fixture promo lists both finishes, so the toggle stays")
        #expect(model.selectedFinish == .normal, "re-derived for the chosen printing")
        await model.confirm()

        let stored = try #require(await store.records(in: batch.id).first)
        #expect(stored.verdict == .correct)
        #expect(stored.confirmedCardID == Fixtures.jinx.id, "the visual class is the label")
        #expect(stored.decisions.map(\.source) == [.human])
        #expect(stored.decisions.first?.ledgerPrintingCode == .set(promo))
        #expect(stored.effectivePrintingCode == promo)
        let sent = items(stored, batch: batch)
        #expect(sent.count == 1)
        #expect(cardKey(of: sent.first) == "OGN-002-P")
    }

    /// Re-confirming a scan whose log already chose the promo leaves the
    /// promo effective: the chip is pre-selected and the new decision inherits.
    @Test func reConfirmingAPromoScanLeavesThePromoEffective() async throws {
        let batch = Fixtures.makeBatch(ScanBatch.Setup(label: "pile", purpose: .collection, product: .loose, defaultFinish: .normal))
        let accepted = Fixtures.record(
            id: Fixtures.uuid(firstByte: Fixtures.unsampledByte),
            batch: batch.id,
            decisions: [Fixtures.decision(.correct, cardID: Fixtures.jinx.id, source: .autoAccepted, ledgerPrintingCode: .set(promo))],
            candidates: [Fixtures.jinx, Fixtures.vi]
        )
        let model = try await makeModel(batch: batch, records: [accepted], mode: .spotCheck(candidates: [accepted.id], limit: 1))

        #expect(model.currentKind == .spotCheck)
        #expect(model.inheritedPrinting == promo)
        #expect(model.selectedPrinting == promo, "the chip row pre-selects what the log settled on")
        #expect(model.printingOverride == .inherit)
        await model.confirm()

        let stored = try #require(await store.records(in: batch.id).first)
        #expect(stored.decisions.map(\.source) == [.autoAccepted, .spotCheck])
        #expect(stored.decisions.last?.ledgerPrintingCode == .inherit)
        #expect(stored.effectivePrintingCode == promo)
        let sent = items(stored, batch: batch)
        #expect(sent.count == 1, "an agreeing re-confirm owes no new item")
        #expect(cardKey(of: sent.first) == "OGN-002-P")
    }

    /// A chip the index also knows (the alternate art) is a correction to that
    /// card, not a ledger override: the two are told apart by the code.
    @Test func choosingAVisibleSiblingCorrectsToThatCard() async throws {
        let batch = Fixtures.batch(purpose: .collection, defaultFinish: .normal)
        let variant = Fixtures.record(batch: batch.id, codeAgreement: .variantDiffers)
        let model = try await makeModel(batch: batch, records: [variant])
        #expect(model.currentKind == .pickPrinting)
        #expect(model.printingOptions?.shown.map(\.code) == ["OGN-001", "OGN-001a"])
        model.selectedPrinting = PrintingKey(rawValue: "OGN-001a")
        #expect(model.finishResolution == .forced(.foil), "the showcase printing is foil only")
        #expect(model.asksForFinish == false)
        await model.confirm()
        let stored = try #require(await store.records(in: batch.id).first)
        #expect(stored.verdict == .corrected(Fixtures.viAlt.id))
        #expect(stored.confirmedCardID == Fixtures.viAlt.id)
        #expect(stored.decisions.first?.ledgerPrintingCode == .inherit)
        #expect(cardKey(of: items(stored, batch: batch).first) == "OGN-001a")
        #expect(finish(of: items(stored, batch: batch).first) == .foil)
        #expect(model.tally == .init(confirmed: 0, corrected: 1, rejected: 0, skipped: 0))
    }

    /// Correcting to another card drops the chips' choices; an earlier
    /// printing override is replaced by the new card's own key so the fold
    /// cannot keep ledgering the old printing.
    @Test func correctingToAnotherCardReplacesAnOldPrintingOverride() async throws {
        let batch = Fixtures.makeBatch(ScanBatch.Setup(label: "pile", purpose: .collection, product: .loose, defaultFinish: .normal))
        let accepted = Fixtures.record(
            id: Fixtures.uuid(firstByte: Fixtures.unsampledByte),
            batch: batch.id,
            decisions: [Fixtures.decision(.correct, cardID: Fixtures.jinx.id, source: .autoAccepted, ledgerPrintingCode: .set(promo))],
            candidates: [Fixtures.jinx, Fixtures.vi]
        )
        let model = try await makeModel(batch: batch, records: [accepted], mode: .spotCheck(candidates: [accepted.id], limit: 1))
        await model.correct(to: Fixtures.vi.id)
        let stored = try #require(await store.records(in: batch.id).first)
        #expect(stored.verdict == .corrected(Fixtures.vi.id))
        #expect(stored.decisions.last?.ledgerPrintingCode == .set(PrintingKey(rawValue: "OGN-001")))
        #expect(stored.effectivePrintingCode == PrintingKey(rawValue: "OGN-001"))
        #expect(cardKey(of: items(stored, batch: batch).last) == "OGN-001")
    }

    @Test func rowsRunUncertainThenDuplicatesThenAudits() async throws {
        let batch = Fixtures.makeBatch(ScanBatch.Setup(label: "pile", purpose: .collection, product: .loose, defaultFinish: .normal))
        let held = Fixtures.record(id: Fixtures.uuid(firstByte: 0), batch: batch.id, capturedAt: Fixtures.epoch)
        let earlier = Fixtures.record(id: Fixtures.uuid(firstByte: Fixtures.unsampledByte), batch: batch.id, capturedAt: Fixtures.epoch.addingTimeInterval(1))
        let duplicate = DuplicateGuard.standard.marking(
            Fixtures.record(id: Fixtures.uuid(firstByte: Fixtures.unsampledByte), batch: batch.id, capturedAt: Fixtures.epoch.addingTimeInterval(2), analysis: Fixtures.analysis(for: Fixtures.result(cards: [Fixtures.vi, Fixtures.jinx]))),
            among: [Fixtures.record(batch: batch.id, analysis: Fixtures.analysis(for: Fixtures.result(cards: [Fixtures.vi, Fixtures.jinx])))]
        )
        let unknown = Fixtures.record(batch: batch.id, candidates: [], capturedAt: Fixtures.epoch.addingTimeInterval(3))
        let pick = Fixtures.record(batch: batch.id, candidates: [Fixtures.jinx], capturedAt: Fixtures.epoch.addingTimeInterval(4))
        let uncertain = Fixtures.record(batch: batch.id, capturedAt: Fixtures.epoch.addingTimeInterval(5), codeRead: false)
        let model = try await makeModel(batch: batch, records: [held, earlier, duplicate, unknown, pick, uncertain])

        let rows = try #require(model.queue.value)
        #expect(rows.map(\.id) == [unknown.id, pick.id, uncertain.id, duplicate.id, held.id])
        let kinds: [ReviewKind] = rows.map { model.kind(of: $0) }
        #expect(kinds == [.unknown, .pickPrinting, .uncertain(.noCodeRead), .possibleDuplicate, .audit])
        #expect(earlier.isAcceptable(under: .default, in: batch, vault: Fixtures.vault, directory: Fixtures.directory), "Vi has no invisible sibling, so it stays confident even in a loose pile")
    }
}
