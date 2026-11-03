import CoreGraphics

/// Everything the index stores about one card image. Every part is computed on
/// the canonical ``CanvasSpecification`` so photos and references are comparable.
public struct CardDescriptor: Hashable, Sendable, Codable {
    public let wholeDifferenceHash: ImageHash
    public let wholePerceptualHash: ImageHash
    public let artDifferenceHash: ImageHash
    public let featurePrint: FeaturePrint

    public init(wholeDifferenceHash: ImageHash, wholePerceptualHash: ImageHash, artDifferenceHash: ImageHash, featurePrint: FeaturePrint) {
        self.wholeDifferenceHash = wholeDifferenceHash
        self.wholePerceptualHash = wholePerceptualHash
        self.artDifferenceHash = artDifferenceHash
        self.featurePrint = featurePrint
    }
}

/// The canvas could not be described.
public enum DescriptorError: Error {
    case artRegionUnavailable
}

/// Computes a ``CardDescriptor`` for an image that is already on the canonical canvas.
public struct CardDescriptorExtractor: Sendable {
    private let featurePrinter: any FeaturePrintGenerating
    private let canvas: CanvasSpecification

    public init(featurePrinter: any FeaturePrintGenerating, canvas: CanvasSpecification) {
        self.featurePrinter = featurePrinter
        self.canvas = canvas
    }

    public func descriptor(for canvasImage: CGImage) async throws -> CardDescriptor {
        let whole = try PerceptualHashing.workingBitmap(for: canvasImage)
        let artRect = canvas.artRegion.pixelRect(in: PixelSize(width: canvasImage.width, height: canvasImage.height))
        guard let art = canvasImage.cropping(to: artRect) else { throw DescriptorError.artRegionUnavailable }
        let artBitmap = try PerceptualHashing.workingBitmap(for: art)
        let featurePrint = try await featurePrinter.featurePrint(for: canvasImage)
        return CardDescriptor(
            wholeDifferenceHash: PerceptualHashing.differenceHash(of: whole),
            wholePerceptualHash: PerceptualHashing.perceptualHash(of: whole),
            artDifferenceHash: PerceptualHashing.differenceHash(of: artBitmap),
            featurePrint: featurePrint
        )
    }
}
