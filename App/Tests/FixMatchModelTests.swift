import Foundation
import RiftboundRecognizer
import Testing
@testable import RiftboundScannerApp

@Suite("Fix match code field")
struct FixMatchModelTests {
    private let batch = ScanBatch.ID(rawValue: UUID())

    private func makeModel(preferredSet: String? = nil, candidates: [Card] = [Fixtures.vi, Fixtures.jinx]) -> FixMatchModel {
        FixMatchModel(
            record: Fixtures.record(batch: batch, candidates: candidates),
            directory: Fixtures.directory,
            preferredSet: preferredSet.flatMap(SetCode.init(rawValue:))
        )
    }

    @Test func setIsPrefilledFromTheBatchThenTheTopCandidate() {
        #expect(makeModel(preferredSet: "RAD").set.rawValue == "RAD")
        #expect(makeModel().set.rawValue == "OGN")
        #expect(makeModel(candidates: [Fixtures.radRune]).set.rawValue == "RAD")
    }

    @Test func typingANumberResolvesEveryPrintingWithThatNumber() {
        let model = makeModel()
        #expect(model.matches.isEmpty)
        model.numberText = "1"
        #expect(model.matches.map(\.id) == [Fixtures.vi.id, Fixtures.viAlt.id])
        model.numberText = "001"
        #expect(model.matches.map(\.id) == [Fixtures.vi.id, Fixtures.viAlt.id])
        model.numberText = "2"
        #expect(model.matches.map(\.id) == [Fixtures.jinx.id])
    }

    @Test func changingTheSetReResolves() {
        let model = makeModel()
        model.numberText = "1"
        model.set = SetCode(rawValue: "RAD")!
        #expect(model.matches.isEmpty)
        model.numberText = "R1"
        #expect(model.matches.map(\.id) == [Fixtures.radRune.id])
        model.numberText = "r01"
        #expect(model.matches.map(\.id) == [Fixtures.radRune.id])
    }

    @Test func unknownOrMalformedNumbersResolveToNothing() {
        let model = makeModel()
        model.numberText = "999"
        #expect(model.matches.isEmpty)
        model.numberText = "12345"
        #expect(model.matches.isEmpty)
        model.numberText = ""
        #expect(model.matches.isEmpty)
    }

    @Test func otherCandidatesExcludeTheTopOne() {
        #expect(makeModel().otherCandidates.map(\.card.id) == [Fixtures.jinx.id])
    }

    @Test func directoryListsSetsInOrder() {
        #expect(Fixtures.directory.sets.map(\.rawValue) == ["OGN", "RAD"])
    }
}

/// The fix sheet explains what the server said about a scan's ledger item
/// (ADR-002, principle 2) in words that say what to do next.
@Suite("Fix match server explanation")
struct FixMatchExplanationTests {
    private let batch = ScanBatch.ID(rawValue: UUID())

    private func makeModel(status: TerminalStatus?, decisions: [Decision] = []) -> FixMatchModel {
        FixMatchModel(record: Fixtures.record(batch: batch, decisions: decisions, candidates: [Fixtures.jinx, Fixtures.vi]), directory: Fixtures.directory, preferredSet: nil, serverStatus: status)
    }

    @Test func unknownCardNamesTheKeyThatWasSent() throws {
        let plain = try #require(makeModel(status: .unknownCard(catalogVersion: "cat-1")).explanation)
        #expect(plain.contains("OGN-002"))
        #expect(plain.contains("does not know"))
        let promo = makeModel(status: .unknownCard(catalogVersion: nil), decisions: [Fixtures.decision(.correct, cardID: Fixtures.jinx.id, ledgerPrintingCode: .set(PrintingKey(rawValue: "OGN-002-P")))])
        #expect(promo.ledgeredKey == PrintingKey(rawValue: "OGN-002-P"))
        #expect(promo.explanation?.contains("OGN-002-P") == true, "the override, not the recognised printing, is what the server rejected")
    }

    @Test func duplicateMismatchSaysTheServerKeptWhatItHad() throws {
        let text = try #require(makeModel(status: .duplicateMismatch).explanation)
        #expect(text.contains("different content"))
        #expect(text.contains("new item"))
    }

    @Test func cleanOutcomesExplainNothing() {
        #expect(makeModel(status: nil).explanation == nil)
        #expect(makeModel(status: .duplicate).explanation == nil)
        #expect(makeModel(status: .wouldGoNegative).explanation?.contains("web") == true)
    }
}
