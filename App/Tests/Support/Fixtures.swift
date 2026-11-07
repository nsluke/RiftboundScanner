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

    /// A reading of the first fixture card's code, for results that should count as confident.
    static let viCodeReading = CodeReading(code: PrintedCode(parsing: "OGN-001/298")!, confidence: 0.9, orientation: .upright, layout: .portrait, text: "OGN • 001/298", source: .edgeBand)

    /// A stand-in query descriptor; stubbed results never compare it with anything.
    static let descriptor = OrientedDescriptor(
        descriptor: CardDescriptor(
            wholeDifferenceHash: ImageHash(bits: 0x0F0F_0F0F_0F0F_0F0F),
            wholePerceptualHash: ImageHash(bits: 0xF0F0_F0F0_F0F0_F0F0),
            artDifferenceHash: ImageHash(bits: 0xFFFF_0000_FFFF_0000),
            featurePrint: FeaturePrint(elements: [1, 0, 0])
        ),
        orientation: .upright
    )

    static let engine = EngineFingerprint(packageVersion: "test", calibrationHash: FeaturePrint(elements: [1, 0, 0]).digest, platform: "iOS", osVersion: "26.1.0")

    static func result(cards: [Card], codeReading: CodeReading? = nil) -> RecognitionResult {
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
        return RecognitionResult(matches: matches, location: .detected(quad, confidence: 0.95), codeReading: codeReading, rectifiedCard: image(), descriptor: descriptor, engine: engine)
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

    static func record(
        id: UUID = UUID(),
        batch: ScanBatch.ID,
        verdict: Verdict = .pending,
        candidates: [Card] = [vi, jinx],
        capturedAt: Date = epoch,
        codeRead: Bool = true,
        score: Double = 1,
        descriptorScore: Double = 0.9,
        codeAgreement: CodeAgreement? = .exact
    ) -> ScanRecord {
        ScanRecord(
            id: ScanRecord.ID(rawValue: id),
            batchID: batch,
            capturedAt: capturedAt,
            photoFileName: "photos/\(id.uuidString).jpg",
            rectifiedFileName: "rectified/\(id.uuidString).jpg",
            processingSeconds: 1.25,
            placement: .detected(confidence: 0.95),
            codeReading: codeRead ? CodeReadingSummary(code: PrintedCode(parsing: "OGN-001/298")!, confidence: 0.9, text: "OGN • 001/298", orientation: .upright, layout: .portrait) : nil,
            candidates: candidates.enumerated().map { offset, card in
                Candidate(card: card, score: offset == 0 ? score : score - 0.3, descriptorScore: descriptorScore, orientation: .upright, codeAgreement: offset == 0 ? codeAgreement : nil)
            },
            verdict: verdict,
            verdictAt: verdict == .pending ? nil : epoch
        )
    }

    static let radRune = card(id: "rad-r01", code: "RAD-R01", name: "Calm Rune")
    static let viAlt = card(id: "ogn-001a-298", code: "OGN-001a/298", name: "Vi, Piltover Enforcer")
    static let directory = CardDirectory(cards: [vi, jinx, viAlt, radRune])
}


extension Fixtures {
    static func vaultCard(
        code: String,
        name: String,
        set: String = "OGN",
        rarity: String = "Common",
        type: String? = "Unit",
        domains: [String] = ["Fury"],
        tags: [String] = [],
        text: String? = nil,
        tcgplayerID: Int? = nil,
        marketNormal: Double? = nil,
        marketFoil: Double? = nil,
        hasNormal: Bool = true,
        promo: Bool = false,
        banned: Bool = false
    ) -> VaultCard {
        VaultCard(
            code: code, name: name, set: set, setName: set == "OGN" ? "Origins" : set, rarity: rarity, type: type, supertype: nil,
            domains: domains, energy: 2, might: 2, power: 0, text: text, flavor: nil, tags: tags, tcgplayerID: tcgplayerID,
            marketNormal: marketNormal, marketFoil: marketFoil, hasNormal: hasNormal, hasFoil: true, promo: promo, banned: banned,
            cardmarketURL: nil, image: URL(string: "https://example.invalid/\(code).webp")!
        )
    }

    static let vault = CardVault(asOf: epoch, cards: [
        vaultCard(code: "OGN-001", name: "Vi, Piltover Enforcer", rarity: "Rare", tcgplayerID: 1001, marketNormal: 2.5, marketFoil: 9),
        vaultCard(code: "OGN-001a", name: "Vi, Piltover Enforcer", rarity: "Showcase", tcgplayerID: 1002, marketFoil: 40, hasNormal: false),
        vaultCard(code: "OGN-002", name: "Jinx, Loose Cannon", rarity: "Epic", domains: ["Chaos"], tags: ["Jinx", "Zaun"], text: "Deal 2 to a unit.", tcgplayerID: 1003, marketNormal: 0.4, marketFoil: 1.2),
        vaultCard(code: "RAD-R01", name: "Calm Rune", set: "RAD", type: "Rune", domains: ["Calm"], tcgplayerID: 1004, marketNormal: 0.1),
        vaultCard(code: "OGN-002-P", name: "Jinx, Loose Cannon (Promo)", rarity: "Epic", domains: ["Chaos"], promo: true),
    ])
}
