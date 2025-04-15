import Foundation
import SQLite3

public protocol Property {
    static var sqlType: String { get }
    
    init(from statement: OpaquePointer?, with columnId: Int32)
    func encode(to statement: OpaquePointer?, with columnId: Int32)
}

public protocol PrimitiveProperty: Property {
    static var defaultValue: Self { get }
}

public protocol EmbeddedProperty: Property {
    static var defaultValue: Self { get }
    
    init(from statement: OpaquePointer?, with columnId: Int32)
    func encode(to statement: OpaquePointer?, with columnId: Int32)
}

extension RawRepresentable where Self.RawValue: PrimitiveProperty {
    public static var defaultValue: Self { .init(rawValue: RawValue.defaultValue)! }
    public static var sqlType: String { RawValue.sqlType }
    
    public init(from statement: OpaquePointer?, with columnId: Int32) {
        self.init(rawValue: RawValue(from: statement, with: columnId))!
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
        self.rawValue.encode(to: statement, with: columnId)
    }
}

public protocol LatticeEnum: RawRepresentable, PrimitiveProperty {
}

extension String: PrimitiveProperty {
    public static var defaultValue: String { .init() }
    public static var sqlType: String { "TEXT" }
    
    public init(from statement: OpaquePointer?, with columnId: Int32) {
        guard let queryResultCol1 = sqlite3_column_text(statement, columnId) else {
            sqlite3_finalize(statement)
            fatalError()
        }
        self = String(cString: queryResultCol1)
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
        sqlite3_bind_text(statement, columnId, (self as NSString).utf8String, -1, nil)
    }
}

extension UUID: PrimitiveProperty {
    public static var defaultValue: UUID { .init() }
    public static var sqlType: String { "TEXT" }
    
    public init(from statement: OpaquePointer?, with columnId: Int32) {
        self = UUID(uuidString: String.init(from: statement, with: columnId))!
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
        uuidString.encode(to: statement, with: columnId)
    }
}

extension URL: PrimitiveProperty {
    public static var defaultValue: URL { .init(filePath: "") }
    public static var sqlType: String { "TEXT" }
    
    public init(from statement: OpaquePointer?, with columnId: Int32) {
        self = URL(string: String.init(from: statement, with: columnId))!
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
        absoluteString.encode(to: statement, with: columnId)
    }
}

extension Bool: PrimitiveProperty {
    public static var defaultValue: Bool {
        .init()
    }
    public static var sqlType: String { "INTEGER" }
    
    public init(from statement: OpaquePointer?, with columnId: Int32) {
        self = sqlite3_column_int(statement, columnId) == 1 ? true : false
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
        sqlite3_bind_int(statement, columnId, self ? 1 : 0)
    }
}

extension Int: PrimitiveProperty {
    public static var defaultValue: Int {
        .init()
    }
    public static var sqlType: String { "INTEGER" }
    
    public init(from statement: OpaquePointer?, with columnId: Int32) {
        self = Int(sqlite3_column_int(statement, columnId))
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
        sqlite3_bind_int(statement, columnId, Int32(self))
    }
}

extension Int8: PrimitiveProperty {
    public static var defaultValue: Int8 {
        .init()
    }
    public static var sqlType: String { "SMALLINT" }
    
    public init(from statement: OpaquePointer?, with columnId: Int32) {
        self = Int8(sqlite3_column_int(statement, columnId))
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
        sqlite3_bind_int(statement, columnId, Int32(self))
    }
}

extension Int16: PrimitiveProperty {
    public static var defaultValue: Int16 {
        .init()
    }
    public static var sqlType: String { "INT" }
    
    public init(from statement: OpaquePointer?, with columnId: Int32) {
        self = Int16(sqlite3_column_int(statement, columnId))
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
        sqlite3_bind_int(statement, columnId, Int32(self))
    }
}

extension Int32: PrimitiveProperty {
    public static var defaultValue: Int32 {
        .init()
    }
    public static var sqlType: String { "INTEGER" }
    
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
    
    public init(from statement: OpaquePointer?, with columnId: Int32) {
        self = Int64(sqlite3_column_int64(statement, columnId))
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
        sqlite3_bind_int64(statement, columnId, self)
    }
}

extension Float: PrimitiveProperty {
    public static var defaultValue: Float {
        .init()
    }
    public static var sqlType: String { "FLOAT" }
    
    public init(from statement: OpaquePointer?, with columnId: Int32) {
        self = Float(sqlite3_column_double(statement, columnId))
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
        sqlite3_bind_double(statement, columnId, Double(self))
    }
}

extension Double: PrimitiveProperty {
    public static var defaultValue: Double {
        .init()
    }
    public static var sqlType: String { "DOUBLE" }
    
    public init(from statement: OpaquePointer?, with columnId: Int32) {
        self = sqlite3_column_double(statement, columnId)
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
        sqlite3_bind_double(statement, columnId, self)
    }
}

extension Date: PrimitiveProperty {
    public static var defaultValue: Date {
        .init()
    }
    public static var sqlType: String { "REAL" }
    
    public init(from statement: OpaquePointer?, with columnId: Int32) {
        self = Date(timeIntervalSince1970: sqlite3_column_double(statement, columnId))
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
        sqlite3_bind_double(statement, columnId, self.timeIntervalSince1970)
    }
}

extension Data: PrimitiveProperty {
    public static var defaultValue: Data {
        .init()
    }
    public static var sqlType: String { "BLOB" }
    
    public init(from statement: OpaquePointer?, with columnId: Int32) {
        let blob = sqlite3_column_blob(statement, columnId)!
        let blobLength = sqlite3_column_bytes(statement, columnId)
        self = Data(bytes: blob, count: Int(blobLength))
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
        sqlite3_bind_blob(statement, columnId, (self as NSData).bytes, Int32(self.count), nil)
    }
}

extension Dictionary: PrimitiveProperty, Property where Key: PrimitiveProperty & Codable, Value: Property & Codable {
    public static var defaultValue: Dictionary<Key, Value> {
        [:]
    }
    
    public static var sqlType: String {
        "TEXT"
    }
    
    public init(from statement: OpaquePointer?, with columnId: Int32) {
        self = try! JSONDecoder().decode(Self.self, from: String(cString: sqlite3_column_text(statement, columnId)!).data(using: .utf8)!)
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
        let string = String(data: try! JSONEncoder().encode(self), encoding: .utf8)!
        sqlite3_bind_text(statement, columnId, (string as NSString).utf8String, -1, nil)
    }
}

public protocol OptionalProtocol: ExpressibleByNilLiteral {
    associatedtype Wrapped
}

extension Optional: OptionalProtocol, Property where Wrapped: Property {
    public init(from statement: OpaquePointer?, with columnId: Int32) {
        self = Wrapped.init(from: statement, with: columnId)
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
        if let self {
            self.encode(to: statement, with: columnId)
        } else {
            sqlite3_bind_null(statement, columnId)
        }
    }
    
    public static var sqlType: String { Wrapped.sqlType }
}

extension Optional: PrimitiveProperty where Wrapped: PrimitiveProperty {
    public static var defaultValue: Optional<Wrapped> {
        nil
    }
    
    public static var sqlType: String {
        Wrapped.sqlType
    }
    
    public init(from statement: OpaquePointer?, with columnId: Int32) {
        if sqlite3_column_type(statement, columnId) == SQLITE_NULL {
            self = nil
        } else {
            self = Wrapped.init(from: statement, with: columnId)
        }
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
        if let self {
            self.encode(to: statement, with: columnId)
        } else {
            sqlite3_bind_null(statement, columnId)
        }
    }
}

enum AnyProperty: PrimitiveProperty, Codable {
    static var defaultValue: AnyProperty {
        .int(0)
    }
    
    static var sqlType: String {
        fatalError()
    }
    
    init(from statement: OpaquePointer?, with columnId: Int32) {
        fatalError()
    }
    
    func encode(to statement: OpaquePointer?, with columnId: Int32) {
        fatalError()
    }
    
    case int(Int)
    case string(String)
    case date(Date)
    case null
    
    enum CodingKeys: String, CodingKey {
        case kind, value
    }
    
    enum Kind: Int, Codable {
        case int, string, date, null
    }
    
    var kind: Kind {
        switch self {
        case .int(_): return .int
        case .string(_): return .string
        case .date(_): return .date
        case .null: return .null
        }
    }
    
    
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.kind, forKey: .kind)
        switch self {
        case .int(let a0):
            try container.encode(a0, forKey: .value)
        case .string(let a0):
            try container.encode(a0, forKey: .value)
        case .date(let a0):
            try container.encode(a0, forKey: .value)
        case .null:
            try container.encodeNil(forKey: .value)
        }
    }
    
    init(from decoder: any Decoder) throws {
        do {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try container.decode(Kind.self, forKey: .kind)
            switch kind {
            case .int: self = .int(try container.decode(Int.self, forKey: .value))
            case .string: self = .string(try container.decode(String.self, forKey: .value))
            case .date: self = .date(try container.decode(Date.self, forKey: .value))
            case .null: self = .null
            }
        } catch {
            do {
                let container = try decoder.singleValueContainer()
                if let intValue = try? container.decode(Int.self) {
                    self = .int(intValue)
                } else if let stringValue = try? container.decode(String.self) {
                    self = .string(stringValue)
                } else if let dateValue = try? container.decode(Date.self) {
                    self = .date(dateValue)
                } else {
                    self = .null
                }
            } catch {
                self = .null
            }
        }
    }
}
