import CoreGraphics
import Foundation
import Testing
@testable import RiftboundRecognizer

@Suite("Synthetic photos")
struct SyntheticPhotoRendererTests {
    let renderer = ImageRenderer()

    @Test func parametersAreReproducibleFromASeed() {
        var a = SeededRandomNumberGenerator(seed: 5)
        var b = SeededRandomNumberGenerator(seed: 5)
        var c = SeededRandomNumberGenerator(seed: 6)
        #expect(SyntheticPhotoParameters.random(severity: .harsh, using: &a) == SyntheticPhotoParameters.random(severity: .harsh, using: &b))
        #expect(SyntheticPhotoParameters.random(severity: .harsh, using: &a) != SyntheticPhotoParameters.random(severity: .harsh, using: &c))
    }

    @Test func renderingIsDeterministicAndKeepsTheCardInFrame() throws {
        let card = TestImages.card(seed: 31, code: "OGN • 031/298")
        var generator = SeededRandomNumberGenerator(seed: 31)
        let parameters = SyntheticPhotoParameters.random(severity: .harsh, using: &generator)
        let first = try SyntheticPhotoRenderer(renderer: renderer).render(card: card, parameters: parameters)
        let second = try SyntheticPhotoRenderer(renderer: renderer).render(card: card, parameters: parameters)
        #expect(first.image.width == parameters.photoSize.width && first.image.height == parameters.photoSize.height)
        let a = PerceptualHashing.differenceHash(of: try PerceptualHashing.workingBitmap(for: first.image))
        let b = PerceptualHashing.differenceHash(of: try PerceptualHashing.workingBitmap(for: second.image))
        #expect(a.distance(to: b) == 0)
        let frame = CGRect(x: 0, y: 0, width: parameters.photoSize.width, height: parameters.photoSize.height)
        #expect(first.quad.corners.allSatisfy { frame.contains($0) })
    }

    @Test func placementShrinksOversizedCardsToFit() {
        var generator = SeededRandomNumberGenerator(seed: 1)
        var parameters = SyntheticPhotoParameters.random(severity: .mild, using: &generator)
        parameters.cardHeightFraction = 0.95
        parameters.sideways = true
        parameters.jitterFraction = 0
        let quad = SyntheticPhotoRenderer.placement(cardSize: PixelSize(width: 756, height: 1056), in: parameters)
        let frame = CGRect(x: 0, y: 0, width: parameters.photoSize.width, height: parameters.photoSize.height).insetBy(dx: 100, dy: 100)
        #expect(quad.corners.allSatisfy { frame.contains($0) })
        let xs = quad.corners.map(\.x)
        let ys = quad.corners.map(\.y)
        #expect((xs.max() ?? 0) - (xs.min() ?? 0) > (ys.max() ?? 0) - (ys.min() ?? 0), "the card lies on its side in the frame")
    }

    @Test func manifestRoundTrips() throws {
        var generator = SeededRandomNumberGenerator(seed: 2)
        let parameters = SyntheticPhotoParameters.random(severity: .moderate, using: &generator)
        let manifest = EvaluationManifest(generatedAt: Date(timeIntervalSince1970: 1_700_000_000), seed: 2, cases: [
            EvaluationCase(file: "moderate/000-ogn-001-298.jpg", expected: Card.ID(rawValue: "ogn-001-298"), group: "moderate", parameters: parameters),
        ])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("riftbound-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try manifest.write(to: folder)
        let reloaded = try EvaluationManifest.read(from: folder)
        #expect(reloaded.cases == manifest.cases && reloaded.seed == 2)
    }
}
