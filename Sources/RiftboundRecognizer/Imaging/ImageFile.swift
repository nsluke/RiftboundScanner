import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// ImageIO could not read or write an image.
public enum ImageFileError: Error {
    case unreadable(URL)
    case undecodable(URL)
    case undecodableData
    case encodingFailed
    case unwritable(URL)
}

/// Reads and writes bitmaps with ImageIO, which exists on every Apple platform.
public enum ImageFile {
    public enum Format: Hashable, Sendable {
        case png
        case jpeg(quality: Double)

        var typeIdentifier: String {
            switch self {
            case .png: UTType.png.identifier
            case .jpeg: UTType.jpeg.identifier
            }
        }

        var properties: [CFString: Any] {
            switch self {
            case .png: [:]
            case .jpeg(let quality): [kCGImageDestinationLossyCompressionQuality: quality]
            }
        }
    }

    /// Loads an image, applying its EXIF orientation and, when `maxPixelSize` is
    /// given, downsampling so the longer side is at most that many pixels. A
    /// 12 MP phone photo decodes to about 48 MB otherwise, and the card locator
    /// does not need that resolution.
    public static func load(_ url: URL, maxPixelSize: Int? = 2048) throws(ImageFileError) -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw .unreadable(url) }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let maxPixelSize {
            options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw .undecodable(url)
        }
        return image
    }

    public static func decode(_ data: Data) throws(ImageFileError) -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw .undecodableData }
        return image
    }

    public static func encode(_ image: CGImage, as format: Format) throws(ImageFileError) -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.typeIdentifier as CFString, 1, nil) else {
            throw .encodingFailed
        }
        CGImageDestinationAddImage(destination, image, format.properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw .encodingFailed }
        return data as Data
    }

    public static func write(_ image: CGImage, to url: URL, as format: Format) throws(ImageFileError) {
        let data = try encode(image, as: format)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw .unwritable(url)
        }
    }
}

/// Where `Scripts/fetch-images.py` puts reference images: one PNG per printing,
/// named by catalog id with `*` spelled `_star` (so signature ids are valid file names).
public enum ReferenceImageCache {
    public static func fileName(for id: Card.ID) -> String {
        id.rawValue.replacingOccurrences(of: "*", with: "_star") + ".png"
    }

    public static func url(for id: Card.ID, in directory: URL) -> URL {
        directory.appendingPathComponent(fileName(for: id))
    }
}
