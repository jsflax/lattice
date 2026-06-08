import Foundation
import LatticeSwiftCppBridge
import LatticeSwiftModule

public protocol DefaultInitializable {
    init()
}

public typealias CxxManagedStringList = lattice.ManagedStringList
public typealias CxxManagedString = lattice.ManagedString

public protocol EmbeddedModel: Codable, PrimitiveProperty, CxxListManaged, DefaultInitializable, UnionProperty where CxxManagedListType == CxxManagedStringList {
}

extension EmbeddedModel {
    public static func getManagedList(from object: lattice.ManagedModel, name: std.string) -> CxxManagedStringList {
        fatalError()
    }
    
    public static func getField(from storage: borrowing ModelStorage, named name: String) -> Self {
        let jsonStr = storage._ref.getString(named: name)
        if jsonStr.isEmpty {
            fatalError()
        }
        return try! JSONDecoder().decode(Self.self, from: jsonStr.data(using: .utf8)!)
    }

    public static func setField(on storage: inout ModelStorage, named name: String, _ value: Self) {
        let jsonStr = String(data: try! JSONEncoder().encode(value), encoding: .utf8)!
        storage._ref.setString(named: name, jsonStr)
    }

    public static var defaultValue: Self {
        .init()
    }

    public static var anyPropertyKind: AnyProperty.Kind { .string }
}

// MARK: - UnionProperty conformance for EmbeddedModel (stored as JSON TEXT)

extension EmbeddedModel where Self: UnionProperty {
    public static func getField(from uv: lattice.union_value, named name: String) -> Self {
        let json = String(uv.getString(std.string(name)))
        if !json.isEmpty, let data = json.data(using: .utf8) {
            return try! JSONDecoder().decode(Self.self, from: data)
        }
        return Self.init()
    }

    public static func setField(on uv: inout lattice.union_value, named name: String, _ value: Self) {
        let json = String(data: try! JSONEncoder().encode(value), encoding: .utf8)!
        uv.setString(std.string(name), std.string(json))
    }
}

#if DEBUG
private struct TestEmbedded: EmbeddedModel {
    var foo = ""
}
#endif
