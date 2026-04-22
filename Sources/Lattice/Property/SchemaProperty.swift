import Foundation
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

public protocol LatticeEnum: RawRepresentable, PrimitiveProperty, CxxListManaged, UnionProperty where RawValue: SchemaProperty, RawValue: CxxListManaged {
}

extension LatticeEnum {
    public typealias CxxManagedListType = RawValue.CxxManagedListType

    public static func getManagedList(from object: lattice.ManagedModel, name: std.string) -> Self.CxxManagedListType {
        fatalError()
    }
    public static var anyPropertyKind: AnyProperty.Kind { RawValue.anyPropertyKind }

    public static func getField(from storage: borrowing ModelStorage, named name: String) -> Self {
        let rawValue = RawValue.getField(from: storage, named: name)
        guard let result = Self(rawValue: rawValue) else {
            return Self.defaultValue
        }
        return result
    }

    public static func setField(on storage: inout ModelStorage, named name: String, _ value: Self) {
        Self.RawValue.setField(on: &storage, named: name, value.rawValue)
    }
}

// MARK: - UnionProperty conformance for LatticeEnum (stored as raw value)

extension LatticeEnum where Self: UnionProperty, RawValue: UnionPrimitiveProperty {
    public static func getField(from uv: lattice.union_value, named name: String) -> Self {
        let raw = RawValue.getField(from: uv, named: name)
        return Self(rawValue: raw) ?? Self.defaultValue
    }

    public static func setField(on uv: inout lattice.union_value, named name: String, _ value: Self) {
        RawValue.setField(on: &uv, named: name, value.rawValue)
    }
}

public protocol CustomPersistableProperty<BaseProperty>: CxxManaged where BaseProperty: CxxManaged {
    associatedtype BaseProperty

    init(_ base: BaseProperty)
    var base: BaseProperty { get }

    static func getField(from storage: borrowing ModelStorage, named name: String) -> Self
    static func setField(on storage: inout ModelStorage, named name: String, _ value: Self)
}

extension CustomPersistableProperty {

    public static func getField(from storage: borrowing ModelStorage, named name: String) -> Self {
        Self.init(BaseProperty.getField(from: storage, named: name))
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
