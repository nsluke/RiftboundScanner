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
    let parser = PrintedCodeParser()

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
    ])
    func repairs(text: String, expected: String) {
        #expect(parser.codes(in: text).first?.canonical == expected)
    }

    @Test("ignores text without a code", arguments: [
        "Kudos Productions ©2025RGI", "Envar Studio", "", "ABC-001/298", "OGN", "2025", "SET • 001/298",
    ])
    func ignores(text: String) {
        #expect(parser.codes(in: text).isEmpty)
    }

    @Test func vocabularyComesFromTheCatalog() throws {
        let only = PrintedCodeParser(vocabulary: .init(sets: [try #require(SetCode(rawValue: "ZZZ"))], numberPrefixes: ["", "Q"]))
        #expect(only.codes(in: "ZZZ • Q12/100").first?.canonical == "ZZZ-Q12/100")
        #expect(only.codes(in: "OGN • 001/298").isEmpty)
    }
}
