import Foundation
import SQLite3

public protocol PrimitiveProperty: PersistableProperty where DefaultValue == Self {
    static var sqlType: String { get }
    static var defaultValue: Self { get }
    
    init(from statement: OpaquePointer?, with columnId: Int32)
    func encode(to statement: OpaquePointer?, with columnId: Int32)
}

extension PrimitiveProperty {
    public static func _get(isolation: isolated (any Actor)? = #isolation,
                            name: String, parent: some Model, lattice: Lattice, primaryKey: Int64) -> Self? {
        let queryStatementString = "SELECT \(name) FROM \(type(of: parent).entityName) WHERE id = ?;"
        var queryStatement: OpaquePointer?
        defer { sqlite3_finalize(queryStatement) }
        if sqlite3_prepare_v2(lattice.db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK {
            // Bind the provided id to the statement.
            sqlite3_bind_int64(queryStatement, 1, primaryKey)
            if sqlite3_step(queryStatement) == SQLITE_ROW {
                // Extract id, name, and age from the row.
                return Self.init(from: queryStatement, with: 0)
            } else {
                lattice.logger.error("SELECT statement could not be prepared: \(lattice.readError() ?? "Unknown error")")
                lattice.logger.error("No field \(name) found on \(type(of: parent).entityName) with id \(primaryKey).")
            }
        } else {
            lattice.logger.error("SELECT statement could not be prepared: \(lattice.readError() ?? "Unknown error")")
        }
        return nil
    }
    
    public static func _set(name: String,
                            parent: some Model,
                            lattice: Lattice,
                            primaryKey: Int64,
                            newValue: Self) {
        let updateStatementString = "UPDATE \(type(of: parent).entityName) SET \(name) = ? WHERE id = ?;"
        var updateStatement: OpaquePointer?
        defer { sqlite3_finalize(updateStatement) }
        if sqlite3_prepare_v2(lattice.db, updateStatementString, -1, &updateStatement, nil) == SQLITE_OK {
            newValue.encode(to: updateStatement, with: 1)
            sqlite3_bind_int64(updateStatement, 2, primaryKey)
            
            if sqlite3_step(updateStatement) == SQLITE_DONE {
                lattice.logger.debug("Successfully updated \(type(of: parent).entityName) with id \(primaryKey) to \(name): \(type(of: newValue)).")
            } else {
                if let error = lattice.readError() {
                    print("Could not update \(type(of: parent).entityName) with id \(primaryKey) on property \(name) with value \(newValue): \(error).")
                } else {
                    print("Could not update \(type(of: parent).entityName) with id \(primaryKey) on property \(name) with value \(newValue).")
                }
            }
        } else {
            print("UPDATE statement could not be prepared.")
        }
    }
}

extension String: PrimitiveProperty {
    public static var defaultValue: String { .init() }
    public static var sqlType: String { "TEXT" }
    public static var anyPropertyKind: AnyProperty.Kind {
        .string
    }
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

// MARK: UUID
extension UUID: PrimitiveProperty {
    public static var defaultValue: UUID { .init() }
    public static var sqlType: String { "TEXT" }
    public static var anyPropertyKind: AnyProperty.Kind {
        .string
    }
    public init(from statement: OpaquePointer?, with columnId: Int32) {
        self = UUID(uuidString: String.init(from: statement, with: columnId))!
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
        uuidString.lowercased().encode(to: statement, with: columnId)
    }
}

extension URL: PrimitiveProperty {
    public static var defaultValue: URL { .init(filePath: "") }
    public static var sqlType: String { "TEXT" }
    public static var anyPropertyKind: AnyProperty.Kind {
        .string
    }
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
    public static var anyPropertyKind: AnyProperty.Kind {
        .int
    }
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
    public static var anyPropertyKind: AnyProperty.Kind {
        .int
    }
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
    public static var anyPropertyKind: AnyProperty.Kind {
        .int
    }
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
    public static var anyPropertyKind: AnyProperty.Kind {
        .int
    }
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
    public init(from statement: OpaquePointer?, with columnId: Int32) {
        self = Int64(sqlite3_column_int64(statement, columnId))
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
        sqlite3_bind_int64(statement, columnId, self)
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
    public static var anyPropertyKind: AnyProperty.Kind {
        .double
    }
    public init(from statement: OpaquePointer?, with columnId: Int32) {
        self = sqlite3_column_double(statement, columnId)
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
        sqlite3_bind_double(statement, columnId, self)
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
    public static var sqlType: String { "TEXT" }
    public static var anyPropertyKind: AnyProperty.Kind {
        .data
    }
    public init(from statement: OpaquePointer?, with columnId: Int32) {
        let blob = sqlite3_column_text(statement, columnId)!
        self = Data(base64Encoded: String(cString: blob))!
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
        base64EncodedString().encode(to: statement, with: columnId)
    }
}

extension Dictionary: PrimitiveProperty, PersistableProperty, Property where Key: PrimitiveProperty & Codable, Value: Property & Codable {
    public static var defaultValue: Dictionary<Key, Value> {
        [:]
    }
    
    public static var sqlType: String {
        "TEXT"
    }
    public static var anyPropertyKind: AnyProperty.Kind {
        .string
    }
    public init(from statement: OpaquePointer?, with columnId: Int32) {
        let blob = String(cString: sqlite3_column_text(statement, columnId)!)
        self = try! JSONDecoder().decode(Self.self, from: blob.data(using: .utf8)!)
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
        let string = String(data: try! JSONEncoder().encode(self), encoding: .utf8)!
        sqlite3_bind_text(statement, columnId, (string as NSString).utf8String, -1, nil)
    }
}

extension Array: PrimitiveProperty, PersistableProperty where Element: Property & Codable {
    public static var defaultValue: Array {
        []
    }
    
    public static var sqlType: String {
        "TEXT"
    }
    public static var anyPropertyKind: AnyProperty.Kind {
        .string
    }
    public init(from statement: OpaquePointer?, with columnId: Int32) {
        let blob = String(cString: sqlite3_column_text(statement, columnId)!)
        self = try! JSONDecoder().decode(Self.self, from: blob.data(using: .utf8)!)
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
        let string = String(data: try! JSONEncoder().encode(self), encoding: .utf8)!
        sqlite3_bind_text(statement, columnId, (string as NSString).utf8String, -1, nil)
    }
}

//extension Optional: Property where Wrapped: Property {
//    public func _set(parent: some Model, lattice: Lattice, primaryKey: Int64) {
//        <#code#>
//    }
//    
//    public func _get(parent: some Model, lattice: Lattice, primaryKey: Int64) {
//        <#code#>
//    }
//    
//    public static var sqlType: String {
//        Wrapped.sqlType
//    }
//}

extension Optional: Property where Wrapped: Property {
    public typealias DefaultValue = Self
    public static var anyPropertyKind: AnyProperty.Kind {
        Wrapped.anyPropertyKind
    }
}

extension Optional: PrimitiveProperty, PersistableProperty where Wrapped: PrimitiveProperty {
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
    
    public init(from statement: OpaquePointer?, with columnId: Int32) {
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
    
    
    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
        switch self {
        case .int(let a0):
            a0.encode(to: statement, with: columnId)
        case .int64(let a0):
            a0.encode(to: statement, with: columnId)
        case .string(let a0):
            a0.encode(to: statement, with: columnId)
        case .date(let a0):
            a0.encode(to: statement, with: columnId)
        case .float(let a0):
            a0.encode(to: statement, with: columnId)
        case .data(let a0):
            a0.encode(to: statement, with: columnId)
        case .double(let a0):
            a0.encode(to: statement, with: columnId)
        case .null:
            Optional<String>.none.encode(to: statement, with: columnId)
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
