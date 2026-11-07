import Foundation

/// The phone's on-disk form of an ``ExemplarIndex``: a small header, the
/// calibration print and every exemplar print packed as little-endian Float32,
/// then an id table. About 3 KB per exemplar at 768 elements, read without
/// base64 or JSON parsing, and patched in place by deltas.
///
/// Layout, all little-endian:
/// ```
/// "RBEX"  magic (4 bytes)
/// u32     layout version (1)
/// u32     formatVersion of the ExemplarIndex (2)
/// i64     overlay version
/// u32     dimension (0 when there is no print at all)
/// u32     exemplar count
/// u8      1 when a calibration print follows, else 0
/// f32[d]  calibration print (when flagged)
/// f32[d]  per exemplar, in table order
/// per exemplar: u16 art-group byte count, UTF-8 bytes, 16-byte scan UUID,
///               16-byte batch UUID, f64 admittedAt (seconds since 1970)
/// ```
public enum BinaryExemplarStore {
    static let magic: [UInt8] = Array("RBEX".utf8)
    static let layoutVersion: UInt32 = 1

    public static func write(_ index: ExemplarIndex, to url: URL) throws {
        try encode(index).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> ExemplarIndex {
        try decode(try Data(contentsOf: url))
    }

    /// Reads the file, applies the delta and writes the result back atomically.
    /// A missing file counts as ``ExemplarIndex/empty`` when the delta has no
    /// base version or a base version of 0.
    @discardableResult
    public static func patch(fileAt url: URL, with delta: ExemplarDelta) throws -> ExemplarIndex {
        let current = FileManager.default.fileExists(atPath: url.path) ? try read(from: url) : ExemplarIndex.empty
        let patched = try current.applying(delta)
        try write(patched, to: url)
        return patched
    }

    public static func encode(_ index: ExemplarIndex) throws -> Data {
        let dimension = index.dimension ?? 0
        if let print = index.calibrationPrint, print.elements.count != dimension {
            throw BinaryExemplarStoreError.inconsistentDimension(expected: dimension, found: print.elements.count)
        }
        for exemplar in index.exemplars where exemplar.featurePrint.elements.count != dimension {
            throw BinaryExemplarStoreError.inconsistentDimension(expected: dimension, found: exemplar.featurePrint.elements.count)
        }
        var writer = ByteWriter()
        writer.append(magic)
        writer.append(layoutVersion)
        writer.append(UInt32(index.formatVersion))
        writer.append(Int64(index.version))
        writer.append(UInt32(dimension))
        writer.append(UInt32(index.exemplars.count))
        writer.append(UInt8(index.calibrationPrint == nil ? 0 : 1))
        if let print = index.calibrationPrint {
            writer.append(print.float32Data)
        }
        for exemplar in index.exemplars {
            writer.append(exemplar.featurePrint.float32Data)
        }
        for exemplar in index.exemplars {
            let name = Array(exemplar.artGroup.rawValue.utf8)
            guard name.count <= Int(UInt16.max) else { throw BinaryExemplarStoreError.corrupt("art group name too long") }
            writer.append(UInt16(name.count))
            writer.append(name)
            writer.append(exemplar.scanID)
            writer.append(exemplar.batchID)
            writer.append(exemplar.admittedAt.timeIntervalSince1970)
        }
        return writer.data
    }

    public static func decode(_ data: Data) throws -> ExemplarIndex {
        var reader = ByteReader(data)
        guard try reader.bytes(4) == magic else { throw BinaryExemplarStoreError.corrupt("not an exemplar store") }
        let layout: UInt32 = try reader.read()
        guard layout == layoutVersion else { throw BinaryExemplarStoreError.unsupportedLayout(found: Int(layout), expected: Int(layoutVersion)) }
        let formatVersion: UInt32 = try reader.read()
        guard formatVersion == ExemplarIndex.currentFormatVersion else {
            throw ExemplarIndexError.unsupportedFormat(found: Int(formatVersion), expected: ExemplarIndex.currentFormatVersion)
        }
        let version: Int64 = try reader.read()
        let dimension = Int(try reader.read() as UInt32)
        let count = Int(try reader.read() as UInt32)
        let hasCalibration: UInt8 = try reader.read()
        guard dimension <= 1 << 16, count <= 1 << 24 else { throw BinaryExemplarStoreError.corrupt("implausible header") }
        let calibrationPrint = hasCalibration == 1 ? FeaturePrint(normalizedFloat32Data: try reader.data(dimension * 4)) : nil
        var prints: [FeaturePrint] = []
        prints.reserveCapacity(count)
        for _ in 0..<count {
            prints.append(FeaturePrint(normalizedFloat32Data: try reader.data(dimension * 4)))
        }
        var exemplars: [ExemplarIndex.Exemplar] = []
        exemplars.reserveCapacity(count)
        for print in prints {
            let nameLength = Int(try reader.read() as UInt16)
            guard let name = String(bytes: try reader.bytes(nameLength), encoding: .utf8) else {
                throw BinaryExemplarStoreError.corrupt("art group name is not UTF-8")
            }
            let scanID = try reader.uuid()
            let batchID = try reader.uuid()
            let admittedAt: Double = try reader.read()
            exemplars.append(ExemplarIndex.Exemplar(
                artGroup: ArtGroup(rawValue: name),
                featurePrint: print,
                scanID: scanID,
                batchID: batchID,
                admittedAt: Date(timeIntervalSince1970: admittedAt)
            ))
        }
        guard reader.isAtEnd else { throw BinaryExemplarStoreError.corrupt("trailing bytes") }
        return ExemplarIndex(version: Int(version), calibrationPrint: calibrationPrint, exemplars: exemplars)
    }
}

public enum BinaryExemplarStoreError: Error, Hashable, Sendable {
    case unsupportedLayout(found: Int, expected: Int)
    case inconsistentDimension(expected: Int, found: Int)
    case truncated
    case corrupt(String)
}

// MARK: - Byte helpers

private struct ByteWriter {
    private(set) var data = Data()

    mutating func append(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }
    mutating func append(_ other: Data) { data.append(other) }

    mutating func append<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    mutating func append(_ value: Double) {
        append(value.bitPattern)
    }

    mutating func append(_ uuid: UUID) {
        withUnsafeBytes(of: uuid.uuid) { data.append(contentsOf: $0) }
    }
}

private struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var isAtEnd: Bool { offset == data.endIndex }

    mutating func data(_ count: Int) throws -> Data {
        guard count >= 0, data.endIndex - offset >= count else { throw BinaryExemplarStoreError.truncated }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func bytes(_ count: Int) throws -> [UInt8] {
        Array(try data(count))
    }

    mutating func read<T: FixedWidthInteger>() throws -> T {
        let raw = try data(MemoryLayout<T>.size)
        return T(littleEndian: raw.withUnsafeBytes { $0.loadUnaligned(as: T.self) })
    }

    mutating func read() throws -> Double {
        Double(bitPattern: try read() as UInt64)
    }

    mutating func uuid() throws -> UUID {
        let raw = try bytes(16)
        return UUID(uuid: (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7], raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]))
    }
}
