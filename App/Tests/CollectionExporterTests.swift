import Foundation
import RiftboundRecognizer
import Testing
@testable import RiftboundScannerApp

@Suite("Collection export")
struct CollectionExporterTests {
    private let batch = ScanBatch.ID(rawValue: UUID())

    private var records: [ScanRecord] {
        [
            Fixtures.record(batch: batch, verdict: .correct),                                   // Vi
            Fixtures.record(batch: batch, verdict: .correct),                                   // Vi again
            Fixtures.record(batch: batch, verdict: .corrected(Fixtures.jinx.id)),               // Jinx, corrected
            Fixtures.record(batch: batch, verdict: .corrected(Fixtures.radRune.id)),            // Rune, sorts after OGN
            Fixtures.record(batch: batch, verdict: .pending),
            Fixtures.record(batch: batch, verdict: .rejected(.notACard)),
            Fixtures.record(batch: batch, verdict: .corrected(Card.ID(rawValue: "gone-999"))),  // unknown to the directory
        ]
    }

    @Test func countsConfirmedCardsAndReportsTheRest() {
        let export = CollectionExporter.export(records, directory: Fixtures.directory)
        #expect(export.lines.map { ($0.card.id.rawValue, $0.quantity) }.map { "\($0.0)×\($0.1)" } == ["ogn-001-298×2", "ogn-002-298×1", "rad-r01×1"])
        #expect(export.lines.map(\.key.rawValue) == ["OGN-001", "OGN-002", "RAD-R01"], "lines carry the server's printing key")
        #expect(export.totalCards == 4)
        #expect(export.pending == 1)
        #expect(export.rejected == 1)
        #expect(export.unresolved == 1)
    }

    @Test func decklistIsQuantityNameCodePerLine() {
        let export = CollectionExporter.export(records, directory: Fixtures.directory)
        #expect(CollectionExporter.decklist(export) == """
        2 Vi, Piltover Enforcer (OGN-001/298)
        1 Jinx, Loose Cannon (OGN-002/298)
        1 Calm Rune (RAD-R01)

        """)
    }

    @Test func csvHasAHeaderAndQuotesNamesWithCommas() {
        let export = CollectionExporter.export(records, directory: Fixtures.directory)
        let rows = CollectionExporter.csv(export).split(separator: "\r\n").map(String.init)
        #expect(rows.first == "Quantity,Name,Code,Key,Set,Rarity,Type,Card ID")
        #expect(rows.count == 4)
        #expect(rows[1] == "2,\"Vi, Piltover Enforcer\",OGN-001/298,OGN-001,Origins,Common,Unit,ogn-001-298")
        #expect(rows[3] == "1,Calm Rune,RAD-R01,RAD-R01,Origins,Common,Unit,rad-r01")
    }

    @Test func quotesInsideNamesAreDoubled() {
        let quoted = Fixtures.card(id: "ogn-003-298", code: "OGN-003/298", name: "The \"Boss\"")
        let directory = CardDirectory(cards: [quoted])
        let export = CollectionExporter.export([Fixtures.record(batch: batch, verdict: .corrected(quoted.id))], directory: directory)
        #expect(CollectionExporter.csv(export).contains("\"The \"\"Boss\"\"\""))
    }

    @Test func emptyExportsAreWellFormed() {
        let export = CollectionExporter.export([], directory: Fixtures.directory)
        #expect(CollectionExporter.decklist(export) == "")
        #expect(CollectionExporter.csv(export) == "Quantity,Name,Code,Key,Set,Rarity,Type,Card ID\r\n")
    }

    @Test func writesAFileWithTheFormatsExtension() async throws {
        let export = CollectionExporter.export(records, directory: Fixtures.directory)
        let url = try await CollectionExporter.write(export, as: .csv, named: "test-export-\(UUID().uuidString)")
        #expect(url.pathExtension == "csv")
        #expect(try String(contentsOf: url, encoding: .utf8).hasPrefix("Quantity,"))
        try FileManager.default.removeItem(at: url)
    }
}
