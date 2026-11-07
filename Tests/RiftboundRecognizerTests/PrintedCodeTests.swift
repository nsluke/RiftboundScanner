import Foundation
import Testing
@testable import RiftboundRecognizer

@Suite("Printed codes")
struct PrintedCodeTests {
    @Test("parses catalog and printed spellings", arguments: [
        ("OGN-001/298", "OGN", "001", PrintedCode.Variant.standard, 298),
        ("OGN • 001/298", "OGN", "001", PrintedCode.Variant.standard, 298),
        ("OGN-007a/298", "OGN", "007", PrintedCode.Variant.alternateArt, 298),
        ("OGN • 007a/298", "OGN", "007", PrintedCode.Variant.alternateArt, 298),
        ("OGN • 299*/298", "OGN", "299", PrintedCode.Variant.signature, 298),
        ("RAD • R01 • EN", "RAD", "R01", PrintedCode.Variant.standard, nil),
        ("RAD-R01a", "RAD", "R01", PrintedCode.Variant.alternateArt, nil),
        ("UNL-T01", "UNL", "T01", PrintedCode.Variant.standard, nil),
        ("VEN-SP1/166", "VEN", "SP1", PrintedCode.Variant.standard, 166),
        ("OGS-001/024", "OGS", "001", PrintedCode.Variant.standard, 24),
    ])
    func parses(text: String, set: String, number: String, variant: PrintedCode.Variant, total: Int?) throws {
        let code = try #require(PrintedCode(parsing: text))
        #expect(code.set.rawValue == set)
        #expect(code.number.rawValue == number)
        #expect(code.variant == variant)
        #expect(code.total == total)
    }

    @Test("canonical spelling matches the catalog", arguments: [
        "OGN-001/298", "OGN-007a/298", "OGN-299*/298", "RAD-R01", "RAD-R01a", "UNL-T01", "VEN-SP1/166", "OGS-001/024",
    ])
    func canonicalRoundTrip(text: String) throws {
        #expect(try #require(PrintedCode(parsing: text)).canonical == text)
    }

    @Test("rejects text without a code", arguments: ["", "Envar Studio", "©2025RGI", "12/34", "OGN"])
    func rejects(text: String) {
        #expect(PrintedCode(parsing: text) == nil)
    }

    @Test func collectorNumberParts() throws {
        let plain = try #require(CollectorNumber(rawValue: "007"))
        #expect(plain.prefix == "" && plain.digits == 7)
        let special = try #require(CollectorNumber(rawValue: "SP1"))
        #expect(special.prefix == "SP" && special.digits == 1)
        #expect(CollectorNumber(rawValue: "ABC1") == nil)
        #expect(SetCode(rawValue: "ogn") == nil)
        #expect(SetCode(rawValue: "O") == nil)
    }

    @Test func encodesAsCanonicalString() throws {
        let code = try #require(PrintedCode(parsing: "OGN-299*/298"))
        let data = try JSONEncoder().encode([code])
        #expect(String(decoding: data, as: UTF8.self) == #"["OGN-299*\/298"]"# || String(decoding: data, as: UTF8.self) == #"["OGN-299*/298"]"#)
        #expect(try JSONDecoder().decode([PrintedCode].self, from: data) == [code])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([PrintedCode].self, from: Data(#"["nonsense"]"#.utf8))
        }
    }
}

@Suite("OCR code parsing")
struct PrintedCodeParserTests {
    /// The printings the parser knows, as an index would list them. Every code
    /// the repair tests expect is here; the denominators per set are the real ones.
    static let known = [
        "OGN-001/298", "OGN-007a/298", "OGN-299*/298", "OGN-202a/298", "OGN-123/298", "OGN-045/298", "OGN-046/298",
        "RAD-R01", "VEN-SP1/166", "VEN-R04", "VEN-040/166", "VEN-001/166",
        "UNL-T01", "UNL-040/219", "UNL-024/219", "UNL-014/219",
        "SFD-024/221", "SFD-014/221", "SFD-121/221", "SFD-221/221", "SFD-211/221", "SFD-127/221",
    ].map(TestRig.code)

    static let vocabulary = PrintedCodeParser.Vocabulary(codes: known)
    let parser = PrintedCodeParser(vocabulary: Self.vocabulary)

    @Test("repairs common misreads", arguments: [
        ("OGN • 001/298", "OGN-001/298"),
        ("0GN • OO1/298", "OGN-001/298"),
        ("OGN001/298", "OGN-001/298"),
        ("OGN • 007a/298", "OGN-007a/298"),
        ("OGN • 299×/298", "OGN-299*/298"),
        ("RAD • RO1 • EN", "RAD-R01"),
        ("RAD • R01 • EN", "RAD-R01"),
        ("VEN • SP1/166", "VEN-SP1/166"),
        ("UNL - TO1", "UNL-T01"),
        ("ogn • 001/298", "OGN-001/298"),
        ("OGN • 2O2a/298", "OGN-202a/298"),
        ("VEN • R04 • EN", "VEN-R04"),
        ("UNL • 040", "UNL-040"),
    ])
    func repairs(text: String, expected: String) {
        let interpretation = parser.interpretations(in: text).first
        #expect(interpretation?.code.canonical == expected)
        #expect(interpretation?.origin == .literal, "shape repairs are still the literal reading")
        #expect(parser.codes(in: text).first == interpretation?.code)
    }

    @Test("ignores text without a code", arguments: [
        "Kudos Productions ©2025RGI", "Envar Studio", "", "ABC-001/298", "OGN", "2025", "SET • 001/298",
    ])
    func ignores(text: String) {
        #expect(parser.codes(in: text).isEmpty)
        #expect(parser.interpretations(in: text).isEmpty)
    }

    @Test func vocabularyIsBuiltFromCodes() throws {
        let vocabulary = Self.vocabulary
        #expect(vocabulary.sets.map(\.rawValue).sorted() == ["OGN", "RAD", "SFD", "UNL", "VEN"])
        #expect(vocabulary.numberPrefixes == ["", "R", "SP", "T"])
        #expect(vocabulary.totals[try #require(SetCode(rawValue: "VEN"))] == [166])
        #expect(vocabulary.totals[try #require(SetCode(rawValue: "RAD"))] == nil, "runes print no denominator")
        #expect(vocabulary.keys.contains(TestRig.code("SFD-024")))
        #expect(!vocabulary.keys.contains(TestRig.code("SFD-024/221")), "keys carry no denominator")
        #expect(vocabulary.keys.count == Self.known.count)

        let only = PrintedCodeParser(vocabulary: .init(codes: [TestRig.code("ZZZ-Q12/100")]))
        #expect(only.codes(in: "ZZZ • Q12/100").first?.canonical == "ZZZ-Q12/100")
        #expect(only.codes(in: "OGN • 001/298").isEmpty)
        #expect(PrintedCodeParser(vocabulary: .empty).codes(in: "OGN • 001/298").isEmpty)
    }

    @Test func aCodeIsKnownOnlyWhenTheIndexHoldsIt() {
        #expect(Self.vocabulary.isKnown(TestRig.code("VEN-R04")))
        #expect(!Self.vocabulary.isKnown(TestRig.code("VEN-R040")), "a shape-valid number the index lacks")
        #expect(Self.vocabulary.isKnown(TestRig.code("UNL-040/219")))
        #expect(Self.vocabulary.isKnown(TestRig.code("UNL-040")), "a missed denominator is not held against the reading")
        #expect(!Self.vocabulary.isKnown(TestRig.code("UNL-040/166")), "VEN's denominator on a UNL code")
        #expect(!Self.vocabulary.isKnown(TestRig.code("UNL-040a/219")), "the variant is part of the key")
    }

    @Test func aNumberTheIndexLacksYieldsNoCode() {
        // The rune's trailing "• EN" tag glued onto the number: R04D repairs to
        // the shape-valid VEN-R040, which no printing carries.
        #expect(parser.codes(in: "VEN • R04D •").isEmpty)
        #expect(parser.codes(in: "VEN • R04 • EN").first?.canonical == "VEN-R04", "the clean reading is fine")
    }

    @Test func aDenominatorFromAnotherSetIsRejected() {
        #expect(parser.codes(in: "VEN • 040/221").isEmpty, "221 is Spiritforged's denominator, not Vendetta's")
        #expect(parser.codes(in: "VEN • 040/166").first?.canonical == "VEN-040/166")
        #expect(parser.codes(in: "SFD - 024/166").isEmpty)
        // A denominator no set prints is a misread denominator, not a different set: the key stands.
        #expect(parser.codes(in: "VEN • 040/266").first?.canonical == "VEN-040/266")
        #expect(!Self.vocabulary.isKnown(TestRig.code("UNL-040/166")) && Self.vocabulary.isKnown(TestRig.code("UNL-040/999")))
    }

    @Test func offersRankedDigitAlternativesThatExistInTheIndex() throws {
        let interpretation = try #require(parser.interpretations(in: "SFD - 024/221").first)
        #expect(interpretation.alternatives.map(\.canonical) == ["SFD-024/221", "SFD-014/221"])
        #expect(interpretation.code.canonical == "SFD-024/221")
        #expect(interpretation.origin == .literal)
        #expect(parser.codes(in: "SFD - 024/221").map(\.canonical) == ["SFD-024/221"], "codes(in:) reports the best per interpretation")

        // One substitution at a time, leftmost digit first, table order (1->2 before 1->7) within a
        // position: 221 (first digit) and 127 (last digit) are known; 721, 111 and 122 are not, and
        // 211 would need two substitutions.
        let several = try #require(parser.interpretations(in: "SFD • 121/221").first)
        #expect(several.alternatives.map(\.canonical) == ["SFD-121/221", "SFD-221/221", "SFD-127/221"])

        // Alternatives keep the variant and denominator of the reading.
        #expect(parser.interpretations(in: "SFD • 024a/221").isEmpty, "no alternate-art 024 or 014 exists")
        #expect(parser.interpretations(in: "UNL • 024").first?.alternatives.map(\.canonical) == ["UNL-024", "UNL-014"])
    }

    @Test func anUnknownLiteralFallsBackToItsAlternative() throws {
        // UNL-074 is not indexed; 7->1 gives UNL-014, which is. The reading is then a guess.
        let guessed = try #require(parser.interpretations(in: "UNL • 074/219").first)
        #expect(guessed.alternatives.map(\.canonical) == ["UNL-014/219"])
        #expect(guessed.code.canonical == "UNL-014/219")
        #expect(guessed.origin == .alternative)
        // Where neither the literal nor any alternative is indexed, nothing is offered.
        #expect(parser.interpretations(in: "UNL • 027/219").isEmpty)
    }

    @Test func anExpectedSetBlocksRepairsIntoOtherSets() throws {
        let unl = RecognitionHints(expectedSet: SetCode(rawValue: "UNL"))
        // A VEN code that needs a shape repair (O for 0) is a guess the hint forbids.
        #expect(parser.codes(in: "VEN • O4O/166").first?.canonical == "VEN-040/166")
        #expect(parser.codes(in: "VEN • O4O/166", hints: unl).isEmpty)
        // A clean, index-known VEN reading is evidence and stays, but its alternatives (guesses) do not.
        #expect(parser.codes(in: "VEN • 040/166", hints: unl).first?.canonical == "VEN-040/166")
        #expect(parser.interpretations(in: "SFD - 024/221", hints: unl).first?.alternatives.map(\.canonical) == ["SFD-024/221"])
        // Within the expected set everything works as before.
        #expect(parser.interpretations(in: "UNL • O24/219", hints: unl).first?.alternatives.map(\.canonical) == ["UNL-024/219", "UNL-014/219"])
        #expect(parser.interpretations(in: "UNL • 074/219", hints: unl).first?.alternatives.map(\.canonical) == ["UNL-014/219"])
        #expect(parser.interpretations(in: "VEN • 074/166", hints: unl).isEmpty, "a guessed code in another set is suppressed outright")
    }
}
