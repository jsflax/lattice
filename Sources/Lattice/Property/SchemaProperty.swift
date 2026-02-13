import Foundation
import SQLite3
import LatticeSwiftCppBridge
import LatticeSwiftModule

public protocol SchemaProperty {
    static var anyPropertyKind: AnyProperty.Kind { get }
    static var defaultValue: Self { get }
}

public typealias LatticeSchemaProperty = SchemaProperty

public protocol PersistableProperty: SchemaProperty {
}

extension RawRepresentable where Self.RawValue: CxxListManaged, Self.RawValue: PrimitiveProperty {
    public typealias CxxManagedListType = Self.RawValue.CxxManagedListType
    public static var defaultValue: Self { .init(rawValue: RawValue.defaultValue)! }
}

public protocol LatticeEnum: RawRepresentable, PrimitiveProperty, CxxListManaged where RawValue: SchemaProperty, RawValue: CxxListManaged {
}

extension LatticeEnum {
    public typealias CxxManagedListType = RawValue.CxxManagedListType

    public static func getManagedList(from object: lattice.ManagedModel, name: std.string) -> Self.CxxManagedListType {
        fatalError()
    }
    public static var anyPropertyKind: AnyProperty.Kind { RawValue.anyPropertyKind }

    public static func getField(from storage: inout ModelStorage, named name: String) -> Self {
        let rawValue = RawValue.getField(from: &storage, named: name)
        guard let result = Self(rawValue: rawValue) else {
            fatalError("Invalid raw value for \(Self.self): \(rawValue)")
        }
        return result
    }

    public static func setField(on storage: inout ModelStorage, named name: String, _ value: Self) {
        Self.RawValue.setField(on: &storage, named: name, value.rawValue)
    }
}

public protocol CustomPersistableProperty<BaseProperty>: CxxManaged where BaseProperty: CxxManaged {
    associatedtype BaseProperty

    init(_ base: BaseProperty)
    var base: BaseProperty { get }

    static func getField(from storage: inout ModelStorage, named name: String) -> Self
    static func setField(on storage: inout ModelStorage, named name: String, _ value: Self)
}

extension CustomPersistableProperty {

    public static func getField(from storage: inout ModelStorage, named name: String) -> Self {
        Self.init(BaseProperty.getField(from: &storage, named: name))
    }
    public static func setField(on storage: inout ModelStorage, named name: String, _ value: Self) {
        BaseProperty.setField(on: &storage, named: name, value.base)
    }
}

extension URL: CustomPersistableProperty {
    public typealias BaseProperty = String
    public init(_ base: BaseProperty) {
        self.init(string: base)!
    }
    public var base: String {
        self.absoluteString
    }
}
