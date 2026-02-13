import Foundation
import SQLite3
import LatticeSwiftCppBridge
import LatticeSwiftModule

public protocol DefaultInitializable {
    init()
}

public typealias CxxManagedStringList = lattice.ManagedStringList
public typealias CxxManagedString = lattice.ManagedString

public protocol EmbeddedModel: Codable, PrimitiveProperty, CxxListManaged, DefaultInitializable where CxxManagedListType == CxxManagedStringList {
}

extension EmbeddedModel {
    public static func getManagedList(from object: lattice.ManagedModel, name: std.string) -> CxxManagedStringList {
        fatalError()
    }
    
    public static func getField(from storage: inout ModelStorage, named name: String) -> Self {
        let jsonStr = String(storage._ref.getString(named: std.string(name)))
        if jsonStr.isEmpty {
            fatalError()
        }
        return try! JSONDecoder().decode(Self.self, from: jsonStr.data(using: .utf8)!)
    }

    public static func setField(on storage: inout ModelStorage, named name: String, _ value: Self) {
        let jsonStr = String(data: try! JSONEncoder().encode(value), encoding: .utf8)!
        storage._ref.setString(named: std.string(name), std.string(jsonStr))
    }

    public static var defaultValue: Self {
        .init()
    }

    public static var anyPropertyKind: AnyProperty.Kind { .string }
}

#if DEBUG
private struct TestEmbedded: EmbeddedModel {
    var foo = ""
}
#endif
