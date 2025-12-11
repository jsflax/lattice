import Foundation
import SQLite3
import LatticeSwiftCppBridge

public protocol SchemaProperty {
    associatedtype DefaultValue
    
    static var anyPropertyKind: AnyProperty.Kind { get }
    static var defaultValue: Self { get }
}

public protocol PersistableProperty: SchemaProperty {
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

public protocol LatticeEnum: RawRepresentable, PrimitiveProperty, CxxManaged where RawValue: SchemaProperty & CxxManaged {
}
extension LatticeEnum {
    public static var anyPropertyKind: AnyProperty.Kind { RawValue.anyPropertyKind }
    public typealias CxxManagedSpecialization = RawValue.CxxManagedSpecialization

    // Convert from C++ via RawValue's conversion
    public static func fromCxxValue(_ value: RawValue.CxxManagedSpecialization.SwiftType) -> Self {
        let rawValue = RawValue.fromCxxValue(value)
        guard let result = Self(rawValue: rawValue) else {
            fatalError("Invalid raw value for \(Self.self): \(rawValue)")
        }
        return result
    }

    // Convert to C++ via RawValue's conversion
    public func toCxxValue() -> RawValue.CxxManagedSpecialization.SwiftType {
        return rawValue.toCxxValue()
    }

    // Get from unmanaged via RawValue
    public static func getUnmanaged(from object: lattice.swift_dynamic_object, name: std.string) -> Self {
        let rawValue = RawValue.getUnmanaged(from: object, name: name)
        guard let result = Self(rawValue: rawValue) else {
            fatalError("Invalid raw value for \(Self.self): \(rawValue)")
        }
        return result
    }

    // Set to unmanaged via RawValue
    public func setUnmanaged(to object: inout lattice.swift_dynamic_object, name: std.string) {
        rawValue.setUnmanaged(to: &object, name: name)
    }
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
