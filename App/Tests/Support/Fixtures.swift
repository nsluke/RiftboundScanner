import CoreGraphics
import Foundation
import RiftboundRecognizer
@testable import RiftboundScannerApp

nonisolated enum Fixtures {
    static let vi = card(id: "ogn-001-298", code: "OGN-001/298", name: "Vi, Piltover Enforcer")
    static let jinx = card(id: "ogn-002-298", code: "OGN-002/298", name: "Jinx, Loose Cannon")
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    static func card(id: String, code: String, name: String) -> Card {
        Card(
            id: Card.ID(rawValue: id),
            name: name,
            displayName: name,
            code: PrintedCode(parsing: code)!,
            setName: "Origins",
            rarity: .common,
            kind: .unit,
            printing: [],
            orientation: .portrait,
            imageURL: URL(string: "https://example.invalid/\(id).png")!
        )
    }

    /// A flat blue bitmap; tests never need real card art.
    static func image(width: Int = 63, height: Int = 88) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static func jpeg() -> Data {
        try! ImageFile.encode(image(), as: .jpeg(quality: 0.8))
    }

    static func result(cards: [Card]) -> RecognitionResult {
        let matches = cards.enumerated().map { offset, card in
            Match(
                card: card,
                score: 1.0 - Double(offset) * 0.1,
                descriptorScore: 0.9 - Double(offset) * 0.1,
                components: ScoreComponents(featurePrint: 0.9, wholeDifferenceHash: 0.9, wholePerceptualHash: 0.9, artDifferenceHash: 0.9),
                orientation: .upright,
                codeAgreement: offset == 0 ? .exact : nil
            )
        }
        let quad = CardQuad(fullImageOfSize: PixelSize(width: 63, height: 88))
        return RecognitionResult(matches: matches, location: .detected(quad, confidence: 0.95), codeReading: nil, rectifiedCard: image())
    }

    static func batch(id: UUID = UUID()) -> ScanBatch {
        ScanBatch(
            id: ScanBatch.ID(rawValue: id),
            startedAt: epoch,
            label: "Test batch",
            device: ScanBatch.Device(model: "iPhone17,1", systemVersion: "Version 26.1", appVersion: "0.1.0"),
            index: IndexSummary(builtAt: epoch, entryCount: 2, formatVersion: 1)
        )
    }

    static func record(id: UUID = UUID(), batch: ScanBatch.ID, verdict: Verdict = .pending, candidates: [Card] = [vi, jinx]) -> ScanRecord {
        ScanRecord(
            id: ScanRecord.ID(rawValue: id),
            batchID: batch,
            capturedAt: epoch,
            photoFileName: "photos/\(id.uuidString).jpg",
            rectifiedFileName: "rectified/\(id.uuidString).jpg",
            processingSeconds: 1.25,
            placement: .detected(confidence: 0.95),
            codeReading: CodeReadingSummary(code: PrintedCode(parsing: "OGN-001/298")!, confidence: 0.9, text: "OGN • 001/298", orientation: .upright, layout: .portrait),
            candidates: candidates.map { Candidate(card: $0, score: 1, descriptorScore: 0.9, orientation: .upright, codeAgreement: .exact) },
            verdict: verdict,
            verdictAt: verdict == .pending ? nil : epoch
        )
    }
}
