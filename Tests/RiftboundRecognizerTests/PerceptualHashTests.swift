import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Testing
import RiftboundRecognizer

@Suite("Perceptual hashing")
struct PerceptualHashTests {
    let renderer = ImageRenderer()

    @Test func boxDownsamplingAverages() {
        let bitmap = GrayscaleBitmap(width: 4, height: 2, pixels: [0, 100, 10, 20, 200, 100, 30, 40])
        let small = bitmap.boxDownsampled(toWidth: 2, height: 1)
        #expect(small.pixels == [100, 25])
    }

    @Test func identicalImagesHashIdentically() throws {
        let image = TestImages.card(seed: 7, code: nil)
        let a = try PerceptualHashing.workingBitmap(for: image)
        let b = try PerceptualHashing.workingBitmap(for: image)
        #expect(PerceptualHashing.differenceHash(of: a).distance(to: PerceptualHashing.differenceHash(of: b)) == 0)
        #expect(PerceptualHashing.perceptualHash(of: a).distance(to: PerceptualHashing.perceptualHash(of: b)) == 0)
    }

    @Test func hashesSurviveResizingAndLighting() throws {
        let small = TestImages.card(seed: 11, code: nil)
        let large = TestImages.card(seed: 11, code: nil, size: PixelSize(width: 756, height: 1056))
        let controls = CIFilter.colorControls()
        controls.inputImage = CIImage(cgImage: large)
        controls.brightness = 0.12
        controls.contrast = 1.25
        let lit = try renderer.makeCGImage(try #require(controls.outputImage))

        let reference = try PerceptualHashing.workingBitmap(for: small)
        for variant in [large, lit] {
            let bitmap = try PerceptualHashing.workingBitmap(for: variant)
            #expect(PerceptualHashing.differenceHash(of: reference).distance(to: PerceptualHashing.differenceHash(of: bitmap)) <= 6)
            #expect(PerceptualHashing.perceptualHash(of: reference).distance(to: PerceptualHashing.perceptualHash(of: bitmap)) <= 8)
        }
    }

    @Test func unrelatedNoiseHashesFarApart() throws {
        var first = SeededRandomNumberGenerator(seed: 1)
        var second = SeededRandomNumberGenerator(seed: 2)
        let a = try PerceptualHashing.workingBitmap(for: try GrayscaleBitmap.noise(width: 64, height: 64, using: &first).makeCGImage())
        let b = try PerceptualHashing.workingBitmap(for: try GrayscaleBitmap.noise(width: 64, height: 64, using: &second).makeCGImage())
        #expect(PerceptualHashing.differenceHash(of: a).distance(to: PerceptualHashing.differenceHash(of: b)) >= 16)
        #expect(PerceptualHashing.perceptualHash(of: a).distance(to: PerceptualHashing.perceptualHash(of: b)) >= 16)
    }

    @Test func similarityIsNormalisedHamming() {
        let zero = ImageHash(bits: 0)
        #expect(zero.similarity(to: zero) == 1)
        #expect(zero.similarity(to: ImageHash(bits: .max)) == 0)
        #expect(zero.distance(to: ImageHash(bits: 0b1011)) == 3)
    }

    @Test func featurePrintIsUnitLengthAndRoundTrips() throws {
        let print = FeaturePrint(elements: [3, 4])
        #expect(abs(print.elements[0] - 0.6) < 1e-6 && abs(print.elements[1] - 0.8) < 1e-6)
        #expect(abs(print.similarity(to: print) - 1) < 1e-6)
        #expect(print.similarity(to: FeaturePrint(elements: [-3, -4])) == 0, "negative cosine clamps to zero")
        let decoded = try JSONDecoder().decode(FeaturePrint.self, from: try JSONEncoder().encode(print))
        #expect(decoded == print)
    }
}
