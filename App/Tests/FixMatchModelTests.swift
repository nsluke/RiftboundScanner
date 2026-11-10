import Foundation
import RiftboundRecognizer
import Testing
@testable import RiftboundScannerApp

@Suite("Fix match search")
struct FixMatchModelTests {
    private let batch = ScanBatch.ID(rawValue: UUID())

    private func makeModel(preferredSet: String? = nil, candidates: [Card] = [Fixtures.vi, Fixtures.jinx]) -> FixMatchModel {
        FixMatchModel(
            record: Fixtures.record(batch: batch, candidates: candidates),
            directory: Fixtures.directory,
            preferredSet: preferredSet.flatMap(SetCode.init(rawValue:))
        )
    }

    @Test func theSetForBareNumbersComesFromTheQueueThenTheTopCandidate() {
        #expect(makeModel(preferredSet: "RAD").preferredSet?.rawValue == "RAD")
        #expect(makeModel().preferredSet?.rawValue == "OGN")
        #expect(makeModel(candidates: [Fixtures.radRune]).preferredSet?.rawValue == "RAD")
    }

    @Test func aBareNumberResolvesEveryPrintingWithThatNumber() {
        let model = makeModel()
        #expect(model.results.isEmpty)
        model.query = "1"
        #expect(model.results.map(\.id) == [Fixtures.vi.id, Fixtures.viAlt.id])
        model.query = "001"
        #expect(model.results.map(\.id) == [Fixtures.vi.id, Fixtures.viAlt.id])
        model.query = "2"
        #expect(model.results.map(\.id) == [Fixtures.jinx.id])
    }

    @Test func aBareNumberLooksInEverySetWithThePreferredSetFirst() {
        let model = makeModel(preferredSet: "RAD")
        model.query = "r1"
        #expect(model.results.map(\.id) == [Fixtures.radRune.id], "a rune number is found without picking RAD")
        let ogn = makeModel(preferredSet: "RAD")
        ogn.query = "1"
        #expect(ogn.results.map(\.id) == [Fixtures.vi.id, Fixtures.viAlt.id], "OGN-001 is still offered when RAD has no 1")
    }

    @Test func aCodeWithItsSetResolvesOnlyThatSet() {
        let model = makeModel()
        for typed in ["rad r1", "RAD-R01", "radr01", "RAD • R01"] {
            model.query = typed
            #expect(model.results.map(\.id) == [Fixtures.radRune.id], "\(typed)")
        }
        model.query = "OGN-001/298"
        #expect(model.results.map(\.id) == [Fixtures.vi.id, Fixtures.viAlt.id])
    }

    @Test func aNameFindsCardsWhoseNameStartsWithItFirst() {
        let model = makeModel()
        model.query = "jinx"
        #expect(model.results.map(\.id) == [Fixtures.jinx.id])
        model.query = "enf"
        #expect(model.results.map(\.id) == [Fixtures.vi.id, Fixtures.viAlt.id], "a word in the name counts")
        model.query = "rune"
        #expect(model.results.map(\.id) == [Fixtures.radRune.id])
    }

    @Test func unknownOrMalformedQueriesResolveToNothing() {
        let model = makeModel()
        model.query = "999"
        #expect(model.results.isEmpty)
        model.query = "zzz"
        #expect(model.results.isEmpty)
        model.query = "  "
        #expect(model.results.isEmpty)
        #expect(model.parsedQuery == .empty)
    }

    @Test func theFirstResultIsSelectedAndTheArrowsMoveWithinTheResults() {
        let model = makeModel()
        model.query = "1"
        #expect(model.selectedCard?.id == Fixtures.vi.id)
        model.moveSelection(by: 1)
        #expect(model.selectedCard?.id == Fixtures.viAlt.id)
        model.moveSelection(by: 1)
        #expect(model.selectedCard?.id == Fixtures.viAlt.id, "stops at the last result")
        model.moveSelection(by: -5)
        #expect(model.selectedCard?.id == Fixtures.vi.id)
        model.query = "2"
        #expect(model.selectedCard?.id == Fixtures.jinx.id, "new results select their first")
    }

    @Test func otherCandidatesExcludeTheTopOne() {
        #expect(makeModel().otherCandidates.map(\.card.id) == [Fixtures.jinx.id])
    }

    @Test func directoryListsSetsInOrder() {
        #expect(Fixtures.directory.sets.map(\.rawValue) == ["OGN", "RAD"])
    }
}

@Suite("Fix query")
struct FixQueryTests {
    private let sets = ["OGN", "RAD", "SFD", "UNL"].compactMap(SetCode.init(rawValue:))

    private func code(_ set: String, _ number: String) -> FixQuery {
        .code(SetCode(rawValue: set)!, CollectorNumber(rawValue: number)!)
    }

    @Test func readsASetAndNumberHoweverTheyAreWritten() {
        #expect(FixQuery("rad 40", sets: sets) == code("RAD", "40"))
        #expect(FixQuery("RAD-040", sets: sets) == code("RAD", "040"))
        #expect(FixQuery("sfd112", sets: sets) == code("SFD", "112"))
        #expect(FixQuery("OGN • 007a/298", sets: sets) == code("OGN", "007"))
        #expect(FixQuery("OGN-299*", sets: sets) == code("OGN", "299"))
        #expect(FixQuery("rad r01", sets: sets) == code("RAD", "R01"))
    }

    @Test func aBareNumberKeepsItsLetterPrefix() {
        #expect(FixQuery("112", sets: sets) == .number(CollectorNumber(rawValue: "112")!))
        #expect(FixQuery("r1", sets: sets) == .number(CollectorNumber(rawValue: "R1")!))
        #expect(FixQuery("sp1", sets: sets) == .number(CollectorNumber(rawValue: "SP1")!), "two letters before the digits are a number prefix")
    }

    @Test func lettersThatAreNotAKnownSetAreAName() {
        #expect(FixQuery("kato", sets: sets) == .name("kato"))
        #expect(FixQuery("vi", sets: sets) == .name("vi"))
        #expect(FixQuery("xyz 12", sets: sets) == .name("xyz 12"))
        #expect(FixQuery(" Kato the Arm ", sets: sets) == .name("Kato the Arm"))
        #expect(FixQuery("", sets: sets) == .empty)
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
