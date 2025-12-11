import Foundation
import SQLite3
import LatticeSwiftCppBridge

public protocol DefaultInitializable {
    init()
}

public protocol EmbeddedModel: Codable, PrimitiveProperty, CxxManaged, DefaultInitializable {
}

extension EmbeddedModel {
    public typealias CxxManagedSpecialization = lattice.ManagedString

    public static func fromCxxValue(_ value: String) -> Self {
        return try! JSONDecoder().decode(Self.self, from: value.data(using: .utf8)!)
    }

    public func toCxxValue() -> String {
        return String(data: try! JSONEncoder().encode(self), encoding: .utf8)!
    }

    public static func getUnmanaged(from object: lattice.swift_dynamic_object, name: std.string) -> Self {
        let jsonStr = String(object.get_string(name))
        if jsonStr.isEmpty {
            return Self.init()
        }
        return try! JSONDecoder().decode(Self.self, from: jsonStr.data(using: .utf8)!)
    }

    public func setUnmanaged(to object: inout lattice.swift_dynamic_object, name: std.string) {
        let jsonStr = String(data: try! JSONEncoder().encode(self), encoding: .utf8)!
        object.set_string(name, std.string(jsonStr))
    }

    public static var defaultValue: Self {
        Self.init()
    }

    public static var sqlType: String {
        "TEXT"
    }

    public static var anyPropertyKind: AnyProperty.Kind { .string }
    public init(from statement: OpaquePointer?, with columnId: Int32) {
        self = try! JSONDecoder().decode(Self.self, from: String(from: statement, with: columnId).data(using: .utf8)!)
    }

    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
        let text = String(data: try! JSONEncoder().encode(self), encoding: .utf8)!
        sqlite3_bind_text(statement, columnId, (text as NSString).utf8String, -1, nil)
    }
}

