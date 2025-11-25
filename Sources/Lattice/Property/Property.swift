import Foundation
import SQLite3

public protocol Property {
    associatedtype DefaultValue
    
    static var anyPropertyKind: AnyProperty.Kind { get }
}

public protocol PersistableProperty: Property {
    static var sqlType: String { get }
    static func _get(isolation: isolated (any Actor)?,
                     name: String, parent: some Model, lattice: Lattice, primaryKey: Int64) -> Self?
    static func _set(name: String,
                     parent: some Model, lattice: Lattice, primaryKey: Int64, newValue: Self)
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

public protocol LatticeEnum: RawRepresentable, PrimitiveProperty where RawValue: Property {
}
extension LatticeEnum {
    public static var anyPropertyKind: AnyProperty.Kind { RawValue.anyPropertyKind }
}
public protocol OptionalProtocol: ExpressibleByNilLiteral {
    associatedtype Wrapped
}

extension Optional: OptionalProtocol {
}

//extension Optional: OptionalProtocol, Property where Wrapped: Property {
//    public typealias AccessorValue = Self
//
//    
//    public static var sqlType: String { Wrapped.sqlType }
//}

//extension Optional: PrimitiveProperty where Wrapped: PrimitiveProperty {
//    
//    public init(from statement: OpaquePointer?, with columnId: Int32) {
//        if sqlite3_column_type(statement, columnId) == SQLITE_NULL {
//            self = nil
//        } else {
//            self = Wrapped.init(from: statement, with: columnId)
//        }
//    }
//    
//    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
//        if let self {
//            self.encode(to: statement, with: columnId)
//        } else {
//            sqlite3_bind_null(statement, columnId)
//        }
//    }
//}
//
//extension Optional: LinkProperty where Wrapped: Link {
////    public init(from statement: OpaquePointer?, with columnId: Int32) {
////        if sqlite3_column_type(statement, columnId) == SQLITE_NULL {
////            self = nil
////        } else {
////            self = Wrapped.init(from: statement, with: columnId)
////        }
////    }
////    
////    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
////        if let self {
////            self.encode(to: statement, with: columnId)
////        } else {
////            sqlite3_bind_null(statement, columnId)
////        }
////    }
//    
//    public static var sqlType: String { Wrapped.sqlType }
//}
