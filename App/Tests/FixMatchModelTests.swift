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
