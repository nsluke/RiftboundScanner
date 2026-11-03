import Foundation
import RiftboundRecognizer
import Testing
@testable import RiftboundScannerApp

@Suite("Scan record coding")
struct ScanRecordCodingTests {
    @Test("verdicts round-trip", arguments: [Verdict.pending, .correct, .corrected(Fixtures.jinx.id), .rejected(.notACard)])
    func verdictRoundTrips(verdict: Verdict) throws {
        let data = try JSONEncoder().encode(verdict)
        #expect(try JSONDecoder().decode(Verdict.self, from: data) == verdict)
    }

    @Test func verdictJSONUsesAKindDiscriminator() throws {
        let data = try JSONEncoder().encode(Verdict.corrected(Fixtures.jinx.id))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: String]
        #expect(object?["kind"] == "corrected")
        #expect(object?["cardID"] == "ogn-002-298")
    }

    @Test func recordRoundTripsThroughTheStoreEncoding() throws {
        let record = Fixtures.record(batch: ScanBatch.ID(rawValue: UUID()), verdict: .rejected(.unreadable))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ScanRecord.self, from: try encoder.encode(record))
        #expect(decoded == record)
        #expect(decoded.candidates.first?.card.code.canonical == "OGN-001/298")
    }

    @Test func identifiersEncodeAsPlainStrings() throws {
        let batch = Fixtures.batch()
        let object = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(batch)) as? [String: Any]
        #expect(object?["id"] as? String == batch.id.rawValue.uuidString)
        let record = Fixtures.record(batch: batch.id)
        let recordObject = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(record)) as? [String: Any]
        #expect(recordObject?["batchID"] as? String == batch.id.rawValue.uuidString)
    }

    @Test func confirmedCardFollowsTheVerdict() {
        let batch = ScanBatch.ID(rawValue: UUID())
        #expect(Fixtures.record(batch: batch, verdict: .correct).confirmedCardID == Fixtures.vi.id)
        #expect(Fixtures.record(batch: batch, verdict: .corrected(Fixtures.jinx.id)).confirmedCardID == Fixtures.jinx.id)
        #expect(Fixtures.record(batch: batch, verdict: .rejected(.notACard)).confirmedCardID == nil)
        #expect(Fixtures.record(batch: batch).confirmedCardID == nil)
    }

    @Test func summaryCountsVerdictsAndAccuracy() {
        let batch = ScanBatch.ID(rawValue: UUID())
        let records = [
            Fixtures.record(batch: batch, verdict: .correct),
            Fixtures.record(batch: batch, verdict: .correct),
            Fixtures.record(batch: batch, verdict: .corrected(Fixtures.jinx.id)),
            Fixtures.record(batch: batch, verdict: .corrected(Card.ID(rawValue: "ogn-099-298"))),
            Fixtures.record(batch: batch, verdict: .rejected(.notACard)),
            Fixtures.record(batch: batch),
        ]
        let summary = BatchSummary(records: records)
        #expect(summary.total == 6)
        #expect(summary.correct == 2)
        #expect(summary.corrected == 2)
        #expect(summary.rejected == 1)
        #expect(summary.pending == 1)
        #expect(summary.judged == 4)
        #expect(summary.topOneAccuracy == 0.5)
        #expect(summary.topThreeAccuracy == 0.75)
    }
}
