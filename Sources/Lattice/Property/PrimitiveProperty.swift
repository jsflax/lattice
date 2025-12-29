import Foundation
import SQLite3

public protocol PrimitiveProperty: PersistableProperty {
}

extension PrimitiveProperty {
}

extension String: PrimitiveProperty {
    public static var defaultValue: String { .init() }
    public static var sqlType: String { "TEXT" }
    public static var anyPropertyKind: AnyProperty.Kind {
        .string
    }
}

// MARK: UUID
extension UUID: PrimitiveProperty {
    public static var defaultValue: UUID { .init() }
    public static var sqlType: String { "TEXT" }
    public static var anyPropertyKind: AnyProperty.Kind {
        .string
    }
}

extension URL: PrimitiveProperty {
    public static var defaultValue: URL { .init(filePath: "") }
    public static var sqlType: String { "TEXT" }
    public static var anyPropertyKind: AnyProperty.Kind {
        .string
    }
}

extension Bool: PrimitiveProperty {
    public static var defaultValue: Bool {
        .init()
    }
    public static var sqlType: String { "INTEGER" }
    public static var anyPropertyKind: AnyProperty.Kind {
        .int
    }
}

extension Int: PrimitiveProperty {
    public static var defaultValue: Int {
        .init()
    }
    public static var sqlType: String { "INTEGER" }
    public static var anyPropertyKind: AnyProperty.Kind {
        .int
    }
}

extension Int8: PrimitiveProperty {
    public static var defaultValue: Int8 {
        .init()
    }
    public static var sqlType: String { "SMALLINT" }
    public static var anyPropertyKind: AnyProperty.Kind {
        .int
    }
}

extension Int16: PrimitiveProperty {
    public static var defaultValue: Int16 {
        .init()
    }
    public static var sqlType: String { "INT" }
    public static var anyPropertyKind: AnyProperty.Kind {
        .int
    }
}

extension Int32: PrimitiveProperty {
    public static var defaultValue: Int32 {
        .init()
    }
    public static var sqlType: String { "INTEGER" }
    public static var anyPropertyKind: AnyProperty.Kind {
        .int
    }
    public init(from statement: OpaquePointer?, with columnId: Int32) {
        self = Int32(sqlite3_column_int(statement, columnId))
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
        sqlite3_bind_int(statement, columnId, Int32(self))
    }
}

extension Int64: PrimitiveProperty {
    public static var defaultValue: Int64 {
        .init()
    }
    public static var sqlType: String { "BIGINT" }
    public static var anyPropertyKind: AnyProperty.Kind {
        .int64
    }
}

// MARK: Float
extension Float: PrimitiveProperty {
    public static var defaultValue: Float {
        .init()
    }
    public static var sqlType: String { "REAL" }
    public static var anyPropertyKind: AnyProperty.Kind {
        .float
    }
}

extension Double: PrimitiveProperty {
    public static var defaultValue: Double {
        .init()
    }
    public static var sqlType: String { "DOUBLE" }
    public static var anyPropertyKind: AnyProperty.Kind {
        .double
    }
}

// MARK: Date
extension Date: PrimitiveProperty {
    public static var defaultValue: Date {
        .init()
    }
    public static var sqlType: String { "REAL" }
    public static var anyPropertyKind: AnyProperty.Kind {
        .date
    }
}

extension Data: PrimitiveProperty {
    public static var defaultValue: Data {
        .init()
    }
    public static var sqlType: String { "BLOB" }
    public static var anyPropertyKind: AnyProperty.Kind {
        .data
    }
}

extension Dictionary: PrimitiveProperty, PersistableProperty, SchemaProperty where Key: PrimitiveProperty & Codable, Value: SchemaProperty & Codable {
    public static var defaultValue: Dictionary<Key, Value> {
        [:]
    }
    
    public static var sqlType: String {
        "TEXT"
    }
    public static var anyPropertyKind: AnyProperty.Kind {
        .string
    }
}

extension Array: PrimitiveProperty, PersistableProperty where Element: SchemaProperty & Codable {
    public static var defaultValue: Array {
        []
    }

    public static var sqlType: String {
        "TEXT"
    }
    public static var anyPropertyKind: AnyProperty.Kind {
        .string
    }
}

extension Set: PrimitiveProperty, PersistableProperty where Element: SchemaProperty & Codable & Hashable {
    public static var defaultValue: Set {
        []
    }

    public static var sqlType: String {
        "TEXT"
    }
    public static var anyPropertyKind: AnyProperty.Kind {
        .string
    }
}

extension Optional: SchemaProperty where Wrapped: SchemaProperty {
    public typealias DefaultValue = Self
    public static var defaultValue: Optional<Wrapped> { nil }
    public static var anyPropertyKind: AnyProperty.Kind {
        Wrapped.anyPropertyKind
    }
}

extension Optional: PrimitiveProperty, PersistableProperty where Wrapped: PrimitiveProperty {
    public static var defaultValue: Optional<Wrapped> {
        nil
    }
}

public enum AnyProperty: PrimitiveProperty, Codable, Sendable {
    public static var defaultValue: AnyProperty {
        .int(0)
    }
    public static var anyPropertyKind: Kind {
        .string
    }
    public static var sqlType: String {
        fatalError()
    }
    
    case int(Int)
    case int64(Int64)
    case float(Float)
    case double(Double)
    case string(String)
    case date(Date)
    case data(Data)
    case null
    
    enum CodingKeys: String, CodingKey {
        case kind, value
    }
    
    public enum Kind: Int, Codable {
        case int, int64, string, date, null, float, data, double
    }
    
    var kind: Kind {
        switch self {
        case .int(_): return .int
        case .int64(_): return .int64
        case .string(_): return .string
        case .date(_): return .date
        case .float(_): return .float
        case .double(_): return .double
        case .data(_): return .data
        case .null: return .null
        }
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .int(let a0):
            try container.encode(a0, forKey: .value)
        case .int64(let a0):
            try container.encode(a0, forKey: .value)
        case .string(let a0):
            try container.encode(a0, forKey: .value)
        case .date(let a0):
            try container.encode(a0, forKey: .value)
        case .float(let a0):
            try container.encode(a0, forKey: .value)
        case .data(let a0):
            try container.encode(a0, forKey: .value)
        case .double(let a0):
            try container.encode(a0, forKey: .value)
        case .null:
            try container.encodeNil(forKey: .value)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        do {
            switch kind {
            case .int: self = .int(try container.decode(Int.self, forKey: .value))
            case .int64: self = .int64(try container.decode(Int64.self, forKey: .value))
            case .string: self = .string(try container.decode(String.self, forKey: .value))
            case .date: self = .date(try container.decode(Date.self, forKey: .value))
            case .data: self = .data(try container.decode(Data.self, forKey: .value))
            case .float: self = .float(try container.decode(Float.self, forKey: .value))
            case .double: self = .double(try container.decode(Double.self, forKey: .value))
            case .null: self = .null
            }
        } catch {
            self = .null
        }
    }
}
