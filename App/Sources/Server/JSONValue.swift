import Foundation

/// An arbitrary JSON document, for payloads the app forwards verbatim (a scan
/// record, an evaluation run's cases) without this layer knowing their shape.
/// Keys are encoded exactly as written: no key strategy is applied to them.
nonisolated indirect enum JSONValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    /// An integer a `Double` cannot hold exactly (beyond ±2^53), such as a
    /// 64-bit perceptual hash's `bits`. Kept exact, so a record forwarded
    /// through this type decodes back to the same hashes.
    case integer(Int64)
    case unsignedInteger(UInt64)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let integer = try? container.decode(Int64.self), integer.magnitude > Self.largestExactDoubleInteger {
            self = .integer(integer)
        } else if let integer = try? container.decode(UInt64.self), integer > Self.largestExactDoubleInteger {
            self = .unsignedInteger(integer)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let bool): try container.encode(bool)
        case .number(let number): try container.encode(number)
        case .integer(let integer): try container.encode(integer)
        case .unsignedInteger(let integer): try container.encode(integer)
        case .string(let string): try container.encode(string)
        case .array(let array): try container.encode(array)
        case .object(let object): try container.encode(object)
        }
    }

    /// 2^53: every integer up to here is exact as a `Double`.
    private static let largestExactDoubleInteger: UInt64 = 1 << 53

    /// Re-reads already-encoded JSON bytes as a value.
    init(data: Data) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Encodes any `Encodable` into a value, so its keys travel untouched.
    init(encoding value: some Encodable, encoder: JSONEncoder) throws {
        self = try JSONValue(data: try encoder.encode(value))
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    /// The same document with every occurrence of the named keys removed, at
    /// any depth. Used to strip `imageURL` before a record leaves the phone.
    func removingKeys(_ keys: Set<String>) -> JSONValue {
        switch self {
        case .array(let array):
            return .array(array.map { $0.removingKeys(keys) })
        case .object(let object):
            var kept: [String: JSONValue] = [:]
            for (key, value) in object where !keys.contains(key) {
                kept[key] = value.removingKeys(keys)
            }
            return .object(kept)
        default:
            return self
        }
    }

    /// True when any string anywhere in the document contains `needle`.
    func containsString(_ needle: String) -> Bool {
        switch self {
        case .string(let string): string.contains(needle)
        case .array(let array): array.contains { $0.containsString(needle) }
        case .object(let object): object.values.contains { $0.containsString(needle) }
        default: false
        }
    }
}
