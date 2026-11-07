import Foundation
import RiftboundRecognizer
import Testing
@testable import RiftboundScannerApp

@Suite("Printing key")
struct PrintingKeyTests {
    @Test func vaultStarSpellingJoinsTheIndexSignature() throws {
        let vault = PrintingKey(vaultCode: "SFD-227-STAR")
        let index = PrintingKey(try #require(PrintedCode(parsing: "SFD-227*/221")))
        #expect(vault == index)
        #expect(vault.rawValue == "SFD-227*")
        #expect(PrintingKey(cardID: Card.ID(rawValue: "sfd-227*-221")) == vault)
    }

    @Test func vaultUppercaseVariantJoinsTheIndexAlternateArt() throws {
        let vault = PrintingKey(vaultCode: "VEN-038A")
        let index = PrintingKey(try #require(PrintedCode(parsing: "VEN-038a/166")))
        #expect(vault == index)
        #expect(vault.rawValue == "VEN-038a")
        #expect(PrintingKey(cardID: Card.ID(rawValue: "ven-038a-166")) == vault)
    }

    @Test func oversizedRowsKeepTheRawCodeAndNoArtGroup() {
        let oversized = PrintingKey(vaultCode: "OGN-279/298")
        let base = PrintingKey(vaultCode: "OGN-279")
        #expect(oversized.rawValue == "OGN-279/298")
        #expect(base.rawValue == "OGN-279")
        #expect(oversized != base)
        #expect(oversized.artGroupCode == nil)
        #expect(base.artGroupCode == "OGN-279")
    }

    @Test("codes the index cannot produce stay raw", arguments: [
        "OGN-066-P", "SFD-178a-P", "OGN-066-MB-P", "UNL-058-P-Champion", "RAD-038-P2",
        "RAD-R01b-P", "UNL-T01g", "OGN-263-a", "OGN-P", "SGN-001/003-P",
    ])
    func rawForSuffixes(code: String) {
        #expect(PrintingKey(vaultCode: code).rawValue == code)
    }

    @Test("codes the index can produce normalise", arguments: [
        ("OGN-066", "OGN-066"), ("OGN-066a", "OGN-066a"), ("OGN-066A", "OGN-066a"),
        ("OGN-066-STAR", "OGN-066*"), ("RAD-SP1", "RAD-SP1"), ("RAD-R01", "RAD-R01"), ("UNL-T01", "UNL-T01"),
    ])
    func normalisedKeys(code: String, expected: String) {
        #expect(PrintingKey(vaultCode: code).rawValue == expected)
    }

    @Test func artGroupDropsEverySuffix() {
        #expect(PrintingKey(vaultCode: "SFD-178").artGroupCode == "SFD-178")
        #expect(PrintingKey(vaultCode: "SFD-178a-P").artGroupCode == "SFD-178")
        #expect(PrintingKey(vaultCode: "SFD-178-P").artGroupCode == "SFD-178")
        #expect(PrintingKey(vaultCode: "SFD-227-STAR").artGroupCode == "SFD-227")
        #expect(PrintingKey(vaultCode: "RAD-R01b-P").artGroupCode == "RAD-R01")
        #expect(PrintingKey(vaultCode: "OGN-P").artGroupCode == nil)
        #expect(PrintingKey(vaultCode: "SGN-001/003-P").artGroupCode == nil)
    }

    @Test func cardIDsWithoutACodeHaveNoKey() {
        #expect(PrintingKey(cardID: Card.ID(rawValue: "gone-999")) == nil)
        #expect(PrintingKey(cardID: Card.ID(rawValue: "ogn-001-298-x")) == nil, "the whole id must be a code, not contain one")
        #expect(PrintingKey(cardID: Card.ID(rawValue: "OGN-001-298")) == nil, "ids are lowercase")
        #expect(PrintingKey(cardID: Card.ID(rawValue: "rad-r01"))?.rawValue == "RAD-R01")
        #expect(PrintingKey(cardID: Card.ID(rawValue: "ven-sp1-166"))?.rawValue == "VEN-SP1")
    }

    @Test func encodesAsItsRawString() throws {
        let key = PrintingKey(vaultCode: "SFD-227-STAR")
        let data = try JSONEncoder().encode([key])
        #expect(String(decoding: data, as: UTF8.self) == #"["SFD-227*"]"#)
        #expect(try JSONDecoder().decode([PrintingKey].self, from: data) == [key])
    }
}

@Suite("Vault siblings")
struct VaultSiblingTests {
    /// Interleaved so vault order, not grouping order, decides the result.
    private let vault = CardVault(asOf: Fixtures.epoch, cards: [
        Fixtures.vaultCard(code: "SFD-178", name: "Blade of the Ruined King", set: "SFD", hasNormal: false),
        Fixtures.vaultCard(code: "OGN-279", name: "Fortified Position"),
        Fixtures.vaultCard(code: "SFD-178a-P", name: "Blade of the Ruined King (Champion Promo)", set: "SFD", hasNormal: false, promo: true),
        Fixtures.vaultCard(code: "OGN-279/298", name: "Fortified Position (Oversized)", promo: true),
        Fixtures.vaultCard(code: "SFD-178-P", name: "Blade of the Ruined King (Top 8 Promo)", set: "SFD", hasNormal: false, promo: true),
        Fixtures.vaultCard(code: "SFD-227-STAR", name: "Ahri - Inquisitive", set: "SFD", hasNormal: false),
        Fixtures.vaultCard(code: "VEN-038A", name: "Akali - Silent", set: "VEN", hasNormal: false),
    ])

    @Test func siblingsShareSetAndNumberWithAnySuffixInVaultOrder() {
        #expect(vault.siblings(of: "SFD-178").map(\.code) == ["SFD-178", "SFD-178a-P", "SFD-178-P"])
        #expect(vault.siblings(of: "SFD-178-P").map(\.code) == ["SFD-178", "SFD-178a-P", "SFD-178-P"], "any member names the whole group")
    }

    @Test func oversizedRowsAreNotSiblingsOfTheBasePrinting() {
        #expect(vault.siblings(of: "OGN-279").map(\.code) == ["OGN-279"])
        #expect(vault.siblings(of: "OGN-279/298").map(\.code) == ["OGN-279/298"], "an oversized row is only its own sibling")
        #expect(vault.siblings(of: "ZZZ-999").isEmpty)
        #expect(vault.siblings(of: "OGN-280/298").isEmpty)
    }

    @Test func vaultCodeMapsIndexIDsBackToTheVaultSpelling() {
        #expect(vault.vaultCode(for: Card.ID(rawValue: "sfd-227*-221")) == "SFD-227-STAR")
        #expect(vault.vaultCode(for: Card.ID(rawValue: "ven-038a-166")) == "VEN-038A")
        #expect(vault.vaultCode(for: Card.ID(rawValue: "sfd-178-221")) == "SFD-178")
        #expect(vault.vaultCode(for: Card.ID(rawValue: "ogn-279-298")) == "OGN-279", "the base printing, never the oversized row")
        #expect(vault.vaultCode(for: Card.ID(rawValue: "unl-t01")) == nil)
        #expect(vault.vaultCode(for: Card.ID(rawValue: "gone-999")) == nil)
    }

    @Test func lookupsByKeyAndByCard() {
        #expect(vault[PrintingKey(rawValue: "SFD-227*")]?.code == "SFD-227-STAR")
        #expect(vault[PrintingKey(rawValue: "VEN-038a")]?.code == "VEN-038A")
        #expect(vault[PrintingKey(rawValue: "OGN-279/298")]?.code == "OGN-279/298")
        let ahri = Fixtures.card(id: "sfd-227*-221", code: "SFD-227*/221", name: "Ahri")
        #expect(vault[ahri]?.code == "SFD-227-STAR")
    }

    @Test func directoryFindsTheIndexPrintingForAVaultKey() {
        let ahri = Fixtures.card(id: "sfd-227*-221", code: "SFD-227*/221", name: "Ahri")
        let akali = Fixtures.card(id: "ven-038a-166", code: "VEN-038a/166", name: "Akali")
        let directory = CardDirectory(cards: [Fixtures.vi, ahri, akali])
        #expect(directory.card(forKey: PrintingKey(vaultCode: "SFD-227-STAR"))?.id == ahri.id)
        #expect(directory.card(forKey: PrintingKey(vaultCode: "VEN-038A"))?.id == akali.id)
        #expect(directory.card(forKey: PrintingKey(vaultCode: "OGN-001"))?.id == Fixtures.vi.id)
        #expect(directory.card(forKey: PrintingKey(vaultCode: "OGN-001-P")) == nil)
    }

    /// The real bundled vault and index: the ADR's measured 1,403 of 1,408
    /// index printings resolve to a vault row, no two vault rows share a key,
    /// and the Blade of the Ruined King group matches the acceptance list.
    @Test func bundledVaultAndIndexAgreeOnKeys() async throws {
        let vaultURL = try #require(Bundle.main.url(forResource: "CardVault", withExtension: "json"))
        let indexURL = try #require(Bundle.main.url(forResource: "index", withExtension: "json"))
        let vault = try await CardVault.read(from: vaultURL)
        let directory = CardDirectory(index: try CardIndex.read(from: indexURL))

        #expect(Set(vault.cards.map(\.key)).count == vault.cards.count, "no two vault rows share a key")
        let unresolved = directory.cards.filter { vault[$0] == nil }.map(\.id.rawValue).sorted()
        #expect(unresolved == ["unl-t01", "unl-t06", "unl-t07", "unl-t08", "ven-t04"])
        #expect(vault.siblings(of: "SFD-178").map(\.code) == ["SFD-178", "SFD-178a-P", "SFD-178-P"])
        #expect(vault.siblings(of: "OGN-279").map(\.code) == ["OGN-279"])
        #expect(vault.vaultCode(for: Card.ID(rawValue: "sfd-227*-221")) == "SFD-227-STAR")
    }
}
