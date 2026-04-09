import Foundation
import LatticeSwiftCppBridge
import LatticeSwiftModule

// MARK: - UnionProperty (base) — any type that can appear as a union case value

public protocol UnionProperty {
    static func getField(from uv: lattice.union_value, named name: String, lattice: Lattice?) -> Self
    static func setField(on uv: inout lattice.union_value, named name: String, _ value: Self)
}

// MARK: - UnionPrimitiveProperty — primitives stored directly in union_value

public protocol UnionPrimitiveProperty: UnionProperty {}

extension String: UnionPrimitiveProperty {
    public static func getField(from uv: lattice.union_value, named name: String, lattice: Lattice?) -> String {
        String(uv.getString(std.string(name)))
    }
    public static func setField(on uv: inout lattice.union_value, named name: String, _ value: String) {
        uv.setString(std.string(name), std.string(value))
    }
}

extension Int: UnionPrimitiveProperty {
    public static func getField(from uv: lattice.union_value, named name: String, lattice: Lattice?) -> Int {
        Int(uv.getInt(std.string(name)))
    }
    public static func setField(on uv: inout lattice.union_value, named name: String, _ value: Int) {
        uv.setInt(std.string(name), Int64(value))
    }
}

extension Int64: UnionPrimitiveProperty {
    public static func getField(from uv: lattice.union_value, named name: String, lattice: Lattice?) -> Int64 {
        uv.getInt(std.string(name))
    }
    public static func setField(on uv: inout lattice.union_value, named name: String, _ value: Int64) {
        uv.setInt(std.string(name), value)
    }
}

extension Double: UnionPrimitiveProperty {
    public static func getField(from uv: lattice.union_value, named name: String, lattice: Lattice?) -> Double {
        uv.getDouble(std.string(name))
    }
    public static func setField(on uv: inout lattice.union_value, named name: String, _ value: Double) {
        uv.setDouble(std.string(name), value)
    }
}

extension Float: UnionPrimitiveProperty {
    public static func getField(from uv: lattice.union_value, named name: String, lattice: Lattice?) -> Float {
        Float(uv.getDouble(std.string(name)))
    }
    public static func setField(on uv: inout lattice.union_value, named name: String, _ value: Float) {
        uv.setDouble(std.string(name), Double(value))
    }
}

extension Bool: UnionPrimitiveProperty {
    public static func getField(from uv: lattice.union_value, named name: String, lattice: Lattice?) -> Bool {
        uv.getInt(std.string(name)) != 0
    }
    public static func setField(on uv: inout lattice.union_value, named name: String, _ value: Bool) {
        uv.setInt(std.string(name), value ? 1 : 0)
    }
}

extension Date: UnionPrimitiveProperty {
    public static func getField(from uv: lattice.union_value, named name: String, lattice: Lattice?) -> Date {
        Date(timeIntervalSinceReferenceDate: uv.getDouble(std.string(name)))
    }
    public static func setField(on uv: inout lattice.union_value, named name: String, _ value: Date) {
        uv.setDouble(std.string(name), value.timeIntervalSinceReferenceDate)
    }
}

extension UUID: UnionPrimitiveProperty {
    public static func getField(from uv: lattice.union_value, named name: String, lattice: Lattice?) -> UUID {
        UUID(uuidString: String(uv.getString(std.string(name)))) ?? UUID()
    }
    public static func setField(on uv: inout lattice.union_value, named name: String, _ value: UUID) {
        uv.setString(std.string(name), std.string(value.uuidString.lowercased()))
    }
}

extension URL: UnionPrimitiveProperty {
    public static func getField(from uv: lattice.union_value, named name: String, lattice: Lattice?) -> URL {
        URL(string: String(uv.getString(std.string(name)))) ?? URL(filePath: "")
    }
    public static func setField(on uv: inout lattice.union_value, named name: String, _ value: URL) {
        uv.setString(std.string(name), std.string(value.absoluteString))
    }
}

extension Data: UnionPrimitiveProperty {
    public static func getField(from uv: lattice.union_value, named name: String, lattice: Lattice?) -> Data {
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
    public static func getField(from uv: lattice.union_value, named name: String, lattice: Lattice?) -> Self {
        guard uv.hasField(std.string(name)) else {
            return nil
        }
        return Wrapped.getField(from: uv, named: name, lattice: lattice)
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
    static func _fromCxxUnionValue(_ value: lattice.union_value, lattice: Lattice?) -> Self
}

/// Marker protocol for macro-generated query enums. Requires a default init (returns ._empty).
public protocol _LatticeUnionQueryEnum {
    init()
}

extension LatticeUnion {
    public static var anyPropertyKind: AnyProperty.Kind { .string }

    public static func getField(from storage: inout ModelStorage, named name: String) -> Self {
        let uv = storage._ref.getUnion(named: std.string(name))
        if String(uv.case_name).isEmpty {
            return Self.defaultValue
        }
        let latticeInstance = storage._ref.lattice.map { Lattice(ref: $0) }
        return Self._fromCxxUnionValue(uv, lattice: latticeInstance)
    }

    public static func setField(on storage: inout ModelStorage, named name: String, _ value: Self) {
        let uv = value._toCxxUnionValue()
        storage._ref.setUnion(named: std.string(name), uv)
    }
}
