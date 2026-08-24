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
    /// The raw ZERO value ("" / 0) is what a fresh row's column holds before
    /// any write, and what a skewed reader sees for a case it predates — so
    /// an enum without a zero case used to TRAP here on read. The
    /// `@LatticeEnum` macro is immune (it synthesizes `defaultValue` = the
    /// first case, which wins over this witness); MANUAL conformances get
    /// the `CaseIterable` overload below, or this actionable message.
    public static var defaultValue: Self {
        guard let value = Self(rawValue: RawValue.defaultValue) else {
            fatalError("""
                \(Self.self) has no case for the raw zero value \
                '\(RawValue.defaultValue)', which is what an unwritten or \
                newer-writer column reads as. Define `static var defaultValue` \
                (the @LatticeEnum macro synthesizes the first case), add a \
                zero-raw-value case, or conform to CaseIterable to default \
                to the first case.
                """)
        }
        return value
    }
}

extension RawRepresentable where Self.RawValue: CxxListManaged, Self.RawValue: PrimitiveProperty, Self: CaseIterable {
    /// A manual conformance without a zero-raw case must NOT trap on a fresh
    /// or skewed row: fall back to the first case — the same reading the
    /// `@LatticeEnum` macro synthesizes, so manual and macro conformances
    /// agree on what an unknown column value means.
    public static var defaultValue: Self {
        Self(rawValue: RawValue.defaultValue) ?? Self.allCases.first!
    }
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
