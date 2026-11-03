import CoreGraphics
import Vision

/// Vision returned a feature print in a layout this version does not read.
public enum FeaturePrintError: Error {
    case unsupportedElementType
}

/// Wraps Vision's `GenerateImageFeaturePrintRequest`.
public struct VisionFeaturePrintGenerator: FeaturePrintGenerating {
    public init() {}

    public func featurePrint(for image: CGImage) async throws -> FeaturePrint {
        let request = GenerateImageFeaturePrintRequest()
        let observation = try await request.perform(on: image)
        guard observation.elementType == .float else { throw FeaturePrintError.unsupportedElementType }
        return FeaturePrint(float32Data: observation.data)
    }
}
