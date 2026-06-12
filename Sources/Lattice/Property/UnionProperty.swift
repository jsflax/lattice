import Foundation
import LatticeSwiftCppBridge
import LatticeSwiftModule

// MARK: - UnionProperty (base) — any type that can appear as a union case value

public protocol UnionProperty {
    static func getField(from uv: lattice.union_value, named name: String) -> Self
    static func setField(on uv: inout lattice.union_value, named name: String, _ value: Self)
}

// MARK: - UnionPrimitiveProperty — primitives stored directly in union_value

public protocol UnionPrimitiveProperty: UnionProperty {}

extension String: UnionPrimitiveProperty {
    public static func getField(from uv: lattice.union_value, named name: String) -> String {
        String(uv.getString(std.string(name)))
    }
    public static func setField(on uv: inout lattice.union_value, named name: String, _ value: String) {
        uv.setString(std.string(name), std.string(value))
    }
}

extension Int: UnionPrimitiveProperty {
    public static func getField(from uv: lattice.union_value, named name: String) -> Int {
        Int(uv.getInt(std.string(name)))
    }
    public static func setField(on uv: inout lattice.union_value, named name: String, _ value: Int) {
        uv.setInt(std.string(name), Int64(value))
    }
}

extension Int64: UnionPrimitiveProperty {
    public static func getField(from uv: lattice.union_value, named name: String) -> Int64 {
        uv.getInt(std.string(name))
    }
    public static func setField(on uv: inout lattice.union_value, named name: String, _ value: Int64) {
        uv.setInt(std.string(name), value)
    }
}

extension Double: UnionPrimitiveProperty {
    public static func getField(from uv: lattice.union_value, named name: String) -> Double {
        uv.getDouble(std.string(name))
    }
    public static func setField(on uv: inout lattice.union_value, named name: String, _ value: Double) {
        uv.setDouble(std.string(name), value)
    }
}

extension Float: UnionPrimitiveProperty {
    public static func getField(from uv: lattice.union_value, named name: String) -> Float {
        Float(uv.getDouble(std.string(name)))
    }
    public static func setField(on uv: inout lattice.union_value, named name: String, _ value: Float) {
        uv.setDouble(std.string(name), Double(value))
    }
}

extension Bool: UnionPrimitiveProperty {
    public static func getField(from uv: lattice.union_value, named name: String) -> Bool {
        uv.getInt(std.string(name)) != 0
    }
    public static func setField(on uv: inout lattice.union_value, named name: String, _ value: Bool) {
        uv.setInt(std.string(name), value ? 1 : 0)
    }
}

extension Date: UnionPrimitiveProperty {
    public static func getField(from uv: lattice.union_value, named name: String) -> Date {
        Date(timeIntervalSinceReferenceDate: uv.getDouble(std.string(name)))
    }
    public static func setField(on uv: inout lattice.union_value, named name: String, _ value: Date) {
        uv.setDouble(std.string(name), value.timeIntervalSinceReferenceDate)
    }
}

extension UUID: UnionPrimitiveProperty {
    public static func getField(from uv: lattice.union_value, named name: String) -> UUID {
        UUID(uuidString: String(uv.getString(std.string(name)))) ?? UUID()
    }
    public static func setField(on uv: inout lattice.union_value, named name: String, _ value: UUID) {
        uv.setString(std.string(name), std.string(value.uuidString.lowercased()))
    }
}

extension URL: UnionPrimitiveProperty {
    public static func getField(from uv: lattice.union_value, named name: String) -> URL {
        URL(string: String(uv.getString(std.string(name)))) ?? URL(fileURLWithPath: "")
    }
    public static func setField(on uv: inout lattice.union_value, named name: String, _ value: URL) {
        uv.setString(std.string(name), std.string(value.absoluteString))
    }
}

extension Data: UnionPrimitiveProperty {
    public static func getField(from uv: lattice.union_value, named name: String) -> Data {
        Data(uv.getBlob(std.string(name)))
    }
    public static func setField(on uv: inout lattice.union_value, named name: String, _ value: Data) {
        var blob = lattice.ByteVector()
        value.forEach { blob.push_back($0) }
        uv.setBlob(std.string(name), blob)
    }
}

// MARK: - Optional conformance — same pattern as Optional: SchemaProperty

extension Optional: UnionProperty where Wrapped: UnionProperty {
    public static func getField(from uv: lattice.union_value, named name: String) -> Self {
        guard uv.hasField(std.string(name)) else {
            return nil
        }
        return Wrapped.getField(from: uv, named: name)
    }

    public static func setField(on uv: inout lattice.union_value, named name: String, _ value: Self) {
        guard let value else {
            return
        }
        Wrapped.setField(on: &uv, named: name, value)
    }
}

// MARK: - UnionLinkProperty — marker for model links, same pattern as LinkProperty

public protocol UnionLinkProperty: UnionProperty {}

extension Optional: UnionLinkProperty where Wrapped: Model {}

// MARK: - LatticeUnion — the union enum type itself

public struct UnionCaseDescriptor {
    public let name: String
    public let fields: [(label: String, type: any UnionProperty.Type)]

    public init(name: String, fields: [(label: String, type: any UnionProperty.Type)]) {
        self.name = name
        self.fields = fields
    }
}

/// Protocol for union enum types. Conformance is generated by the @Union macro.
/// Union values are stored in a separate internal table. The parent model stores
/// the union row's globalId as a TEXT column.
public protocol LatticeUnion: SchemaProperty, CxxManaged {
    /// The internal table name for this union type (e.g., "_FeedItem").
    static var unionTableName: String { get }

    /// Metadata about each case and its associated values.
    static var unionCases: [UnionCaseDescriptor] { get }

    /// Macro-generated query enum for switch-based query syntax.
    associatedtype QueryEnum: _LatticeUnionQueryEnum

    /// Returns one variant per case with Query<T> values for each field.
    static func _makeQueryVariants(parentKeyPath: [String]) -> [(caseName: String, variant: QueryEnum)]

    /// Encode this value into a C++ union_value for storage.
    func _toCxxUnionValue() -> lattice.union_value

    /// Decode a C++ union_value, resolving links via the Lattice instance.
    static func _fromCxxUnionValue(_ value: lattice.union_value) -> Self
}

/// Marker protocol for macro-generated query enums. Requires a default init (returns ._empty).
public protocol _LatticeUnionQueryEnum {
    init()
}

extension LatticeUnion {
    public static var anyPropertyKind: AnyProperty.Kind { .string }

    // Union field access marshals through the C++ union_value handle surface,
    // which works on every OS (value-converted below the FRT floor).
    public static func getField(from storage: borrowing ModelStorage, named name: String) -> Self {
        let uv = storage._ref.asCxxObjectRef!.getUnion(named: std.string(name))
        if String(uv.case_name).isEmpty {
            return Self.defaultValue
        }
        return Self._fromCxxUnionValue(uv)
    }

    public static func setField(on storage: inout ModelStorage, named name: String, _ value: Self) {
        let uv = value._toCxxUnionValue()
        storage._ref.asCxxObjectRef!.setUnion(named: std.string(name), uv)
    }
}
