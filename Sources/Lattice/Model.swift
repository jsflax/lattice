import Foundation
import SQLite3

public protocol Model: AnyObject, Observable, ObservableObject, Hashable, Identifiable, Property {
    init(isolation: isolated (any Actor)?)
    var lattice: Lattice? { get set }
    static var entityName: String { get }
    static var properties: [(String, any Property.Type)] { get }
    var primaryKey: Int64? { get set }
    func _assign(lattice: Lattice?)
    func _encode(statement: OpaquePointer?)
    func _didEncode()
    
    var _$observationRegistrar: Observation.ObservationRegistrar { get }
    func _objectWillChange_send()
    func _triggerObservers_send(keyPath: String)
    var _lastKeyPathUsed: String? { get set }
    static func _nameForKeyPath(_ keyPath: AnyKeyPath) -> String
    static var constraints: [Constraint] { get }
}

extension Model {
    public static var sqlType: String { "BIGINT" }

//    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
//        _encode(statement: statement)
//    }
//    
//    public init(from statement: OpaquePointer?, with columnId: Int32) {
//        fatalError()
//    }
    
    public var id: ObjectIdentifier {
        ObjectIdentifier(self)
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(primaryKey)
        hasher.combine(ObjectIdentifier(self))
    }
    
    public static func ==(lhs: Self, rhs: Self) -> Bool {
        if lhs.primaryKey != nil {
            lhs.primaryKey == rhs.primaryKey
        } else {
            lhs === rhs
        }
    }
    
//    public var __globalId: UUID {
//        _lastKeyPathUsed = "globalId"
//        guard let lattice, let primaryKey else {
//            return UUID()
//        }
//        let queryStatementString = "SELECT globalId FROM \(Self.entityName) WHERE id = ?;"
//        var queryStatement: OpaquePointer?
//        defer { sqlite3_finalize(queryStatement) }
//        if sqlite3_prepare_v2(lattice.db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK {
//            // Bind the provided id to the statement.
//            sqlite3_bind_int64(queryStatement, 1, primaryKey)
//            
//            if sqlite3_step(queryStatement) == SQLITE_ROW {
//                // Extract id, name, and age from the row.
//                let t = UUID(from: queryStatement, with: 0)
//                return t
//            } else {
//                print("SELECT statement could not be prepared:", lattice.readError() ?? "Unknown error")
//                print("No field globalId found on \(Self.entityName) with id \(primaryKey).")
//            }
//        } else {
//            print("SELECT statement could not be prepared:", lattice.readError() ?? "Unknown error")
//        }
//        fatalError()
//    }
}

func _name<T>(for keyPath: PartialKeyPath<T>) -> String where T: Model {
    let t = T(isolation: #isolation)
    _ = t[keyPath: keyPath]
    return t._lastKeyPathUsed ?? "id"
}

@attached(member, names: arbitrary)
@attached(extension, conformances: Model, names: arbitrary)
@attached(memberAttribute)
public macro Model() = #externalMacro(module: "LatticeMacros",
                                      type: "ModelMacro")

@attached(member, names: arbitrary)
@attached(extension, conformances: Codable, names: arbitrary)
public macro Codable() = #externalMacro(module: "LatticeMacros",
                                        type: "CodableMacro")

@attached(peer)
public macro Transient() = #externalMacro(module: "LatticeMacros",
                                      type: "TransientMacro")


@attached(accessor, names: arbitrary)
public macro Property(name mappedTo: String? = nil) = #externalMacro(module: "LatticeMacros",
                                                                     type: "PropertyMacro")


@attached(peer)
public macro Unique<T>(compoundedWith: PartialKeyPath<T>...,
                       allowsUpsert: Bool = false) = #externalMacro(module: "LatticeMacros",
                                                           type: "UniqueMacro")

@attached(peer)
public macro Unique() = #externalMacro(module: "LatticeMacros",
                                       type: "UniqueMacro")

// MARK: Constraints
public struct Constraint {
    public var columns: [String]
    public var allowsUpsert: Bool
    public init(columns: [String], allowsUpsert: Bool = false) {
        self.columns = columns
        self.allowsUpsert = allowsUpsert
    }
}
