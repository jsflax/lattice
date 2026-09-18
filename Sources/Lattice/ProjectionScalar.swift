import Foundation

/// A value that can decode one SQL cell without constructing a managed model.
///
/// Built-in conformances validate the storage class and value instead of
/// substituting a property's default. Signed integers require INTEGER storage;
/// floating-point values accept finite REAL or exactly representable INTEGER
/// values. Float also requires an exactly representable REAL value. Only
/// Optional accepts NULL. String and Data preserve their complete contents,
/// including embedded zero bytes.
///
/// Custom scalar types opt in by implementing this protocol. A decoder should
/// throw when the cell cannot represent its value, never return a default for
/// an unsupported cell. This protocol does not by itself make a type persistable.
public protocol ProjectionScalar: Sendable {
    static func decodeProjectionValue(_ value: ColumnValue) throws -> Self
}

// Like Lattice.Model, this alias lets generated code qualify the protocol
// even inside this module, where the Lattice struct shadows the module name.
public typealias LatticeProjectionScalar = ProjectionScalar
extension Lattice {
    public typealias ProjectionScalar = LatticeProjectionScalar
}

/// A cell failed strict projection decoding. Errors describe types rather than
/// including potentially sensitive cell contents.
public enum ProjectionDecodingError: Error, Equatable, Sendable {
    case unexpectedNull(expected: String)
    case typeMismatch(expected: String, actual: String)
    case outOfRange(expected: String)
    case nonFinite(expected: String)
    case invalidValue(expected: String)
}

private func projectionTypeMismatch(_ value: ColumnValue, expected: String) -> ProjectionDecodingError {
    let actual: String
    switch value {
    case .null: return .unexpectedNull(expected: expected)
    case .int64: actual = "INTEGER"
    case .real: actual = "REAL"
    case .text: actual = "TEXT"
    case .blob: actual = "BLOB"
    }
    return .typeMismatch(expected: expected, actual: actual)
}

private func projectionInteger<T: FixedWidthInteger>(_ value: ColumnValue, as type: T.Type) throws -> T {
    let expected = String(describing: type)
    guard case .int64(let integer) = value else {
        throw projectionTypeMismatch(value, expected: expected)
    }
    guard let decoded = T(exactly: integer) else {
        throw ProjectionDecodingError.outOfRange(expected: expected)
    }
    return decoded
}

private func projectionDouble(_ value: ColumnValue, expected: String) throws -> Double {
    switch value {
    case .real(let real):
        guard real.isFinite else { throw ProjectionDecodingError.nonFinite(expected: expected) }
        return real
    case .int64(let integer):
        guard let decoded = Double(exactly: integer) else {
            throw ProjectionDecodingError.outOfRange(expected: expected)
        }
        return decoded
    default:
        throw projectionTypeMismatch(value, expected: expected)
    }
}

private func projectionText(_ value: ColumnValue, expected: String) throws -> String {
    guard case .text(let text) = value else {
        throw projectionTypeMismatch(value, expected: expected)
    }
    return text
}

extension String: ProjectionScalar {
    public static func decodeProjectionValue(_ value: ColumnValue) throws -> String {
        try projectionText(value, expected: "String")
    }
}

extension Bool: ProjectionScalar {
    public static func decodeProjectionValue(_ value: ColumnValue) throws -> Bool {
        guard case .int64(let integer) = value else {
            throw projectionTypeMismatch(value, expected: "Bool")
        }
        switch integer {
        case 0: return false
        case 1: return true
        default: throw ProjectionDecodingError.invalidValue(expected: "Bool")
        }
    }
}

extension Int: ProjectionScalar {
    public static func decodeProjectionValue(_ value: ColumnValue) throws -> Int {
        try projectionInteger(value, as: Self.self)
    }
}

extension Int64: ProjectionScalar {
    public static func decodeProjectionValue(_ value: ColumnValue) throws -> Int64 {
        try projectionInteger(value, as: Self.self)
    }
}

extension Int32: ProjectionScalar {
    public static func decodeProjectionValue(_ value: ColumnValue) throws -> Int32 {
        try projectionInteger(value, as: Self.self)
    }
}

extension Int16: ProjectionScalar {
    public static func decodeProjectionValue(_ value: ColumnValue) throws -> Int16 {
        try projectionInteger(value, as: Self.self)
    }
}

extension Int8: ProjectionScalar {
    public static func decodeProjectionValue(_ value: ColumnValue) throws -> Int8 {
        try projectionInteger(value, as: Self.self)
    }
}

extension Double: ProjectionScalar {
    public static func decodeProjectionValue(_ value: ColumnValue) throws -> Double {
        try projectionDouble(value, expected: "Double")
    }
}

extension Float: ProjectionScalar {
    public static func decodeProjectionValue(_ value: ColumnValue) throws -> Float {
        let decoded: Float?
        switch value {
        case .real(let real):
            guard real.isFinite else { throw ProjectionDecodingError.nonFinite(expected: "Float") }
            decoded = Float(exactly: real)
        case .int64(let integer):
            decoded = Float(exactly: integer)
        default:
            throw projectionTypeMismatch(value, expected: "Float")
        }
        guard let decoded else { throw ProjectionDecodingError.outOfRange(expected: "Float") }
        return decoded
    }
}

extension Date: ProjectionScalar {
    /// Dates use finite Unix seconds, matching Lattice's Date storage.
    public static func decodeProjectionValue(_ value: ColumnValue) throws -> Date {
        let seconds = try projectionDouble(value, expected: "Date")
        let date = Date(timeIntervalSince1970: seconds)
        guard date.timeIntervalSince1970.isFinite else {
            throw ProjectionDecodingError.outOfRange(expected: "Date")
        }
        return date
    }
}

extension UUID: ProjectionScalar {
    public static func decodeProjectionValue(_ value: ColumnValue) throws -> UUID {
        let text = try projectionText(value, expected: "UUID")
        guard text.utf8.count == 36, let uuid = UUID(uuidString: text),
              text.lowercased() == uuid.uuidString.lowercased() else {
            throw ProjectionDecodingError.invalidValue(expected: "UUID")
        }
        return uuid
    }
}

extension URL: ProjectionScalar {
    /// Decode the serialized `absoluteString` used by Lattice. Relative URLs
    /// are supported; text requiring automatic repair or escaping is rejected.
    public static func decodeProjectionValue(_ value: ColumnValue) throws -> URL {
        let text = try projectionText(value, expected: "URL")
        guard let url = URL(string: text), url.absoluteString == text else {
            throw ProjectionDecodingError.invalidValue(expected: "URL")
        }
        return url
    }
}

extension Data: ProjectionScalar {
    public static func decodeProjectionValue(_ value: ColumnValue) throws -> Data {
        guard case .blob(let data) = value else {
            throw projectionTypeMismatch(value, expected: "Data")
        }
        return data
    }
}

extension Optional: ProjectionScalar where Wrapped: ProjectionScalar {
    public static func decodeProjectionValue(_ value: ColumnValue) throws -> Self {
        if case .null = value { return nil }
        return .some(try Wrapped.decodeProjectionValue(value))
    }
}
