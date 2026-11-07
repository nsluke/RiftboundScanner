import CoreGraphics
import Foundation
import Testing
import RiftboundRecognizer

@Suite("Calibration print and engine fingerprint")
struct CalibrationTests {
    @Test func canvasIsDrawnIdenticallyEveryTime() throws {
        let first = try CalibrationCanvas.render()
        let second = try CalibrationCanvas.render()
        #expect(first.width == CanvasSpecification.standard.size.width && first.height == CanvasSpecification.standard.size.height)
        let firstBytes = try #require(first.dataProvider?.data) as Data
        let secondBytes = try #require(second.dataProvider?.data) as Data
        #expect(firstBytes == secondBytes)
        // It is a picture, not a flat colour: the fake print below must have something to see.
        let bitmap = try GrayscaleBitmap(rendering: first, width: 32, height: 32)
        #expect(Set(bitmap.pixels).count > 20)
    }

    @Test func calibrationPrintIsTheCanvasPrint() async throws {
        let generator = ThumbnailFeaturePrintGenerator()
        let calibration = try await generator.calibrationPrint()
        let direct = try await generator.featurePrint(for: try CalibrationCanvas.render())
        #expect(calibration == direct)
        #expect(calibration.digest == direct.digest)
        let again = try await generator.calibrationPrint()
        #expect(again.digest == calibration.digest, "deterministic across runs")
    }

    @Test func digestIsSixteenBytesInHex() throws {
        let print = FeaturePrint(elements: [0.25, 0.5, 0.75, 1])
        let digest = print.digest
        #expect(digest.bytes.count == 16)
        #expect(digest.hex.count == 32)
        #expect(digest.hex.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(FeaturePrint.Digest(hex: digest.hex) == digest)
        #expect(FeaturePrint(elements: [1, 0.5, 0.75, 0.25]).digest != digest)
        #expect(FeaturePrint.Digest(hex: "not hex") == nil)
        #expect(FeaturePrint.Digest(hex: String(repeating: "zz", count: 16)) == nil)

        let encoded = try JSONEncoder().encode(digest)
        #expect(String(decoding: encoded, as: UTF8.self) == "\"\(digest.hex)\"")
        #expect(try JSONDecoder().decode(FeaturePrint.Digest.self, from: encoded) == digest)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(FeaturePrint.Digest.self, from: Data("\"abc\"".utf8)) }
    }

    @Test func digestCoversTheEncodedBytes() throws {
        // The digest is over the same little-endian Float32 bytes the index stores,
        // so a print decoded from an index digests identically to the one written.
        let print = FeaturePrint(elements: (0..<768).map { Float($0 % 13) / 13 })
        let decoded = try JSONDecoder().decode(FeaturePrint.self, from: try JSONEncoder().encode(print))
        #expect(decoded.digest == print.digest)
        #expect(decoded.float32Data == print.float32Data)
    }

    @Test func fingerprintDescribesThisBuildAndSystem() async throws {
        let hash = FeaturePrint(elements: [1, 0, 0]).digest
        let fingerprint = EngineFingerprint.current(calibrationHash: hash)
        #expect(fingerprint.packageVersion == RecognizerInfo.version)
        #expect(fingerprint.calibrationHash == hash)
        #if os(macOS)
        #expect(fingerprint.platform == "macOS")
        #endif
        #expect(fingerprint.osVersion.wholeMatch(of: #/\d+\.\d+\.\d+/#) != nil)

        let calibrated = try await EngineFingerprint.current(calibrating: ThumbnailFeaturePrintGenerator())
        #expect(calibrated.calibrationHash == (try await ThumbnailFeaturePrintGenerator().calibrationPrint()).digest)
        #expect(calibrated.platform == fingerprint.platform && calibrated.osVersion == fingerprint.osVersion)

        let encoded = try JSONEncoder().encode(calibrated)
        #expect(try JSONDecoder().decode(EngineFingerprint.self, from: encoded) == calibrated)
        let json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["calibrationHash"] as? String == calibrated.calibrationHash.hex)
    }

    @Test(.tags(.vision)) func visionCalibrationPrintIsDeterministic() async throws {
        let generator = VisionFeaturePrintGenerator()
        let first = try await generator.calibrationPrint()
        let second = try await generator.calibrationPrint()
        #expect(first.elements.count == 768, "the ADR's artefacts assume a 768-element embedding")
        #expect(first.digest == second.digest, "the same machine must fingerprint itself the same way twice")
        #expect(first.similarity(to: second) > 0.9999)
        // Sanity: the canvas is not confused with a blank image.
        let blank = try await generator.featurePrint(for: TestImages.card(seed: 1, code: nil))
        #expect(first.similarity(to: blank) < 0.999)
    }
}
