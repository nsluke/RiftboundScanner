import CoreGraphics
import Vision

/// Vision returned a feature print in a layout this version does not read.
public enum FeaturePrintError: Error {
    case unsupportedElementType
}

/// Wraps Vision's `GenerateImageFeaturePrintRequest`.
///
/// The request's `Revision` has a single case, so it cannot tell whether two
/// systems embed images the same way; ``FeaturePrintGenerating/calibrationPrint()``
/// (the print of the procedural ``CalibrationCanvas``) and its
/// ``FeaturePrint/digest`` are what fingerprint the model that is actually running.
public struct VisionFeaturePrintGenerator: FeaturePrintGenerating {
    public init() {}

    public func featurePrint(for image: CGImage) async throws -> FeaturePrint {
        let request = GenerateImageFeaturePrintRequest()
        let observation = try await request.perform(on: image)
        guard observation.elementType == .float else { throw FeaturePrintError.unsupportedElementType }
        return FeaturePrint(float32Data: observation.data)
    }
}
