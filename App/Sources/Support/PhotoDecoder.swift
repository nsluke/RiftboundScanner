import CoreGraphics
import Foundation
import ImageIO
import RiftboundRecognizer

/// Bitmap conversions for the app, all `@concurrent`: ImageIO decoding of a
/// 12 MP capture and JPEG encoding are far too slow for the main actor.
nonisolated enum PhotoDecoder {
    enum Failure: Error, Hashable {
        case undecodable
        case encodingFailed
    }

    /// Decodes an encoded photo, applying its EXIF orientation and downsampling
    /// so the longer side is at most `maxPixelSize`; the recogniser works at 2048.
    @concurrent
    static func decode(_ data: Data, maxPixelSize: Int) async throws(Failure) -> CGImage {
        try decodeNow(data, maxPixelSize: maxPixelSize)
    }

    /// A small upright image of a stored photo, or `nil` if it cannot be read.
    @concurrent
    static func thumbnail(at url: URL, maxPixelSize: Int) async -> CGImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decodeNow(data, maxPixelSize: maxPixelSize)
    }

    @concurrent
    static func encodeJPEG(_ image: CGImage, quality: Double) async throws(Failure) -> Data {
        do {
            return try ImageFile.encode(image, as: .jpeg(quality: quality))
        } catch {
            throw .encodingFailed
        }
    }

    /// The same encoded photo shown turned clockwise by `rotation`. Only the
    /// EXIF orientation changes: ImageIO copies JPEG and HEIC data without
    /// re-encoding, so the photo loses nothing.
    static func reoriented(_ data: Data, by rotation: CameraRotation) throws(Failure) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source) else {
            throw .undecodable
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let stored = (properties?[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, type, 1, nil) else { throw .encodingFailed }
        let options: [CFString: Any] = [kCGImageDestinationOrientation: rotation.applied(to: stored).rawValue]
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil) else { throw .encodingFailed }
        return output as Data
    }

    private static func decodeNow(_ data: Data, maxPixelSize: Int) throws(Failure) -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw .undecodable }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw .undecodable }
        return image
    }
}
