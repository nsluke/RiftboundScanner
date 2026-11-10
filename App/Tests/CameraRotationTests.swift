import CoreGraphics
import Foundation
import ImageIO
import RiftboundRecognizer
import Testing
@testable import RiftboundScannerApp

@Suite("Camera rotation")
struct CameraRotationTests {
    @Test func turnsAQuarterAtATimeAndWraps() {
        #expect(CameraRotation.none.turnedClockwise == .clockwise90)
        #expect(CameraRotation.clockwise90.turnedClockwise == .clockwise180)
        #expect(CameraRotation.clockwise180.turnedClockwise == .clockwise270)
        #expect(CameraRotation.clockwise270.turnedClockwise == CameraRotation.none)
    }

    @Test func quarterTurnsSwapWidthAndHeight() {
        let landscape = CGSize(width: 1920, height: 1440)
        #expect(CameraRotation.clockwise90.turning(landscape) == CGSize(width: 1440, height: 1920))
        #expect(CameraRotation.clockwise270.turning(landscape) == CGSize(width: 1440, height: 1920))
        #expect(CameraRotation.clockwise180.turning(landscape) == landscape)
        #expect(CameraRotation.none.turning(landscape) == landscape)
    }

    @Test("composes with the photo's own orientation", arguments: [
        (CameraRotation.none, CGImagePropertyOrientation.up, CGImagePropertyOrientation.up),
        (.clockwise90, .up, .right),
        (.clockwise180, .up, .down),
        (.clockwise270, .up, .left),
        (.clockwise90, .right, .down),
        (.clockwise90, .left, .up),
        (.clockwise180, .upMirrored, .downMirrored),
        // EXIF 7 is "mirror horizontally, then turn 90° clockwise"; EXIF 5
        // turns 270°, so one more quarter-turn leaves the mirror alone.
        (.clockwise90, .upMirrored, .rightMirrored),
        (.clockwise90, .leftMirrored, .upMirrored),
    ])
    func composesOrientation(rotation: CameraRotation, stored: CGImagePropertyOrientation, expected: CGImagePropertyOrientation) {
        #expect(rotation.applied(to: stored) == expected)
    }

    @Test func fourQuarterTurnsComeBackToEveryOrientation() {
        let all: [CGImagePropertyOrientation] = [.up, .upMirrored, .down, .downMirrored, .leftMirrored, .right, .rightMirrored, .left]
        for orientation in all {
            var turned = orientation
            for _ in 0..<4 {
                turned = CameraRotation.clockwise90.applied(to: turned)
            }
            #expect(turned == orientation)
        }
    }

    @Test func aReorientedPhotoDecodesTurnedClockwise() async throws {
        // A red block in the top-left corner of a portrait photo lands in the
        // top-right corner of the landscape result after a clockwise turn.
        let photo = try PhotoDecoder.reoriented(markedJPEG(width: 60, height: 90), by: .clockwise90)
        let decoded = try await PhotoDecoder.decode(photo, maxPixelSize: 4096)

        #expect(decoded.width == 90)
        #expect(decoded.height == 60)
        #expect(isRed(pixel(of: decoded, x: 80, y: 8)))
        #expect(!isRed(pixel(of: decoded, x: 8, y: 8)))
    }

    @Test func reorientingKeepsTheEncodedPixels() throws {
        let original = markedJPEG(width: 60, height: 90)
        let photo = try PhotoDecoder.reoriented(original, by: .clockwise180)
        let source = try #require(CGImageSourceCreateWithData(photo as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyOrientation] as? UInt32 == CGImagePropertyOrientation.down.rawValue)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 60, "only the EXIF orientation changes")
    }

    @Test func brighteningTurnsAndLightensThePhoto() async throws {
        let original = markedJPEG(width: 60, height: 90)
        let photo = try PhotoDecoder.adjusted(original, turnedBy: .clockwise90, brightenedBy: 0.5)
        let decoded = try await PhotoDecoder.decode(photo, maxPixelSize: 4096)

        #expect(decoded.width == 90 && decoded.height == 60)
        #expect(isRed(pixel(of: decoded, x: 80, y: 8)), "the red corner is top-right once turned")
        let before = try await PhotoDecoder.decode(original, maxPixelSize: 4096)
        #expect(pixel(of: decoded, x: 40, y: 40).green > pixel(of: before, x: 40, y: 60).green + 10, "the grey is lighter")
    }

    @Test func withoutBrighteningOnlyTheOrientationChanges() throws {
        let original = markedJPEG(width: 60, height: 90)
        #expect(try PhotoDecoder.adjusted(original, turnedBy: .none, brightenedBy: 0) == original)
        #expect(try PhotoDecoder.adjusted(original, turnedBy: .clockwise180, brightenedBy: 0) == PhotoDecoder.reoriented(original, by: .clockwise180))
    }

    @Test func onlyContinuityPhotosAreBrightened() {
        #expect(CameraDevice.Kind.continuity.photoExposureBoost == 0.5)
        #expect(CameraDevice.Kind.external.photoExposureBoost == 0)
        #expect(CameraDevice.Kind.builtIn.photoExposureBoost == 0)
    }

    @Test func refusesDataThatIsNotAPhoto() {
        #expect(throws: PhotoDecoder.Failure.undecodable) {
            try PhotoDecoder.reoriented(Data("not a photo".utf8), by: .clockwise90)
        }
    }

    // MARK: - Helpers

    /// A grey JPEG with a red block in its top-left corner.
    private func markedJPEG(width: Int, height: Int) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        // Core Graphics puts y = 0 at the bottom: this is the top-left corner.
        context.fill(CGRect(x: 0, y: height - 20, width: 20, height: 20))
        return try! ImageFile.encode(context.makeImage()!, as: .jpeg(quality: 0.95))
    }

    /// RGBA of the pixel at (x, y), y measured from the top.
    private func pixel(of image: CGImage, x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8) {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let offset = (y * image.width + x) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }

    private func isRed(_ pixel: (red: UInt8, green: UInt8, blue: UInt8)) -> Bool {
        pixel.red > 200 && pixel.green < 80 && pixel.blue < 80
    }
}
