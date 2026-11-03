import CoreGraphics
import CoreImage
import Foundation
import Testing
import RiftboundRecognizer

@Suite("Image rotation and fitting")
struct ImagingTests {
    let renderer = ImageRenderer()

    @Test func quarterTurnCounterclockwiseMovesTopLeftToBottomLeft() throws {
        let marker = TestImages.marker(width: 4, height: 2)
        let rotated = try renderer.rotated(marker, quarterTurnsCounterclockwise: 1)
        #expect(rotated.width == 2 && rotated.height == 4)
        #expect(TestImages.rgb(of: rotated, x: 0, y: 3).red > 200)
        #expect(TestImages.rgb(of: rotated, x: 0, y: 0).red < 50)
    }

    @Test func halfTurnMovesTopLeftToBottomRight() throws {
        let rotated = try renderer.rotated(TestImages.marker(width: 4, height: 2), quarterTurnsCounterclockwise: 2)
        #expect(rotated.width == 4 && rotated.height == 2)
        #expect(TestImages.rgb(of: rotated, x: 3, y: 1).red > 200)
    }

    @Test func clockwiseTurnMovesTopLeftToTopRight() throws {
        let rotated = try renderer.rotated(TestImages.marker(width: 4, height: 2), quarterTurnsCounterclockwise: 3)
        #expect(rotated.width == 2 && rotated.height == 4)
        #expect(TestImages.rgb(of: rotated, x: 1, y: 0).red > 200)
    }

    @Test func fullTurnIsIdentity() throws {
        let image = CIImage(cgImage: TestImages.marker(width: 4, height: 2))
        #expect(image.rotated(quarterTurnsCounterclockwise: 4).extent == image.extent)
    }

    @Test func fittingProducesTheExactCanvasSize() throws {
        let card = TestImages.card(seed: 3, code: nil)
        let fitted = try renderer.makeCGImage(fitting: CIImage(cgImage: card), to: CanvasSpecification.standard.size)
        #expect(fitted.width == 756 && fitted.height == 1056)
    }

    @Test func rectifyingAKnownQuadRecoversTheCard() throws {
        let card = TestImages.card(seed: 5, code: nil, size: CanvasSpecification.standard.size)
        let (photo, quad) = TestImages.photo(of: card, at: CGRect(x: 300, y: 200, width: 378, height: 528), canvas: PixelSize(width: 1000, height: 1000))
        let rectifier = CardRectifier(renderer: renderer, canvas: .standard)
        let rectified = try rectifier.rectify(photo, quad: quad)
        let expected = PerceptualHashing.differenceHash(of: try PerceptualHashing.workingBitmap(for: card))
        let actual = PerceptualHashing.differenceHash(of: try PerceptualHashing.workingBitmap(for: rectified))
        #expect(expected.distance(to: actual) <= 6)
    }

    @Test func sidewaysQuadsBecomePortrait() {
        let sideways = CardQuad(topLeft: CGPoint(x: 0, y: 100), topRight: CGPoint(x: 300, y: 100), bottomRight: CGPoint(x: 300, y: 0), bottomLeft: CGPoint(x: 0, y: 0))
        #expect(sideways.isSideways)
        let portrait = sideways.portraitOriented()
        #expect(!portrait.isSideways)
        #expect(Set(portrait.corners.map { "\($0)" }) == Set(sideways.corners.map { "\($0)" }))
        #expect(portrait.cornerError(comparedTo: sideways) == 0)
    }

    @Test("fits a card to its bounding box", arguments: [0.0, 4.0, 11.0, -7.0, 23.0])
    func fitsCardToBoundingBox(degrees: Double) {
        let angle = degrees * .pi / 180
        let center = CGPoint(x: 700, y: 900)
        func corner(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: center.x + x * cos(angle) - y * sin(angle), y: center.y + x * sin(angle) + y * cos(angle))
        }
        let truth = CardQuad(topLeft: corner(-315, 440), topRight: corner(315, 440), bottomRight: corner(315, -440), bottomLeft: corner(-315, -440))
        let fitted = CardQuad.fitting(boundingBox: truth.boundingBox)
        #expect(fitted.count == (degrees == 0 ? 1 : 2))
        let best = fitted.map { $0.cornerError(comparedTo: truth) }.min() ?? .infinity
        #expect(best < 0.005)
    }

    @Test func fitsASidewaysCardToItsBoundingBox() {
        let truth = CardQuad(topLeft: CGPoint(x: 100, y: 730), topRight: CGPoint(x: 980, y: 730), bottomRight: CGPoint(x: 980, y: 100), bottomLeft: CGPoint(x: 100, y: 100))
        let fitted = CardQuad.fitting(boundingBox: truth.boundingBox)
        #expect(fitted.count == 1)
        #expect(fitted.first?.cornerError(comparedTo: truth) ?? 1 < 0.005)
        #expect(fitted.first?.isSideways == true)
    }

    @Test func imageFilesRoundTripThroughJPEG() throws {
        let card = TestImages.card(seed: 9, code: nil)
        let data = try ImageFile.encode(card, as: .jpeg(quality: 0.9))
        let decoded = try ImageFile.decode(data)
        #expect(decoded.width == card.width && decoded.height == card.height)
        let a = PerceptualHashing.differenceHash(of: try PerceptualHashing.workingBitmap(for: card))
        let b = PerceptualHashing.differenceHash(of: try PerceptualHashing.workingBitmap(for: decoded))
        #expect(a.distance(to: b) <= 4)
    }
}
