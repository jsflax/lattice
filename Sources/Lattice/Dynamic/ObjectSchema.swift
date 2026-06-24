import Foundation

// MARK: - Dynamic schema value types
//
// These mirror the C++ `property_descriptor` / `property_kind` / `column_type`
// (see LatticeCore schema.hpp) as Sendable Swift values, so a dynamically-opened
// Lattice (no compile-time `@Model` types) can describe what's in a database
// file. Produced by `Lattice.dynamicSchema`; consumed by the MCP's schema tool
// and by the result serializer to dispatch reads by property kind.

/// The on-disk SQL storage class of a scalar column.
public enum ColumnType: String, Sendable, Codable, Hashable {
    case integer, real, text, blob
}

/// What a property *is* in ORM terms — the distinction raw SQL can't recover.
public enum PropertyKind: String, Sendable, Codable, Hashable {
    case primitive          // scalar stored directly in the row
    case link               // to-one reference (junction table)
    case list               // to-many reference (junction table) / geo-bounds list
    case virtualList        // polymorphic to-many (discriminated junction)
    case virtualLink        // polymorphic to-one (discriminated junction)
    case unionType          // owned union table (parent stores the row's globalId)
}

/// One associated value of a `@Union` case.
public struct UnionCaseValue: Sendable, Codable, Hashable {
    public var paramName: String        // label; "" for a single unlabeled value
    public var columnType: ColumnType   // text for links/embedded, native for primitives
    public var isLink: Bool             // true = globalId reference to another model
    public var linkTarget: String?      // target table when isLink

    public init(paramName: String, columnType: ColumnType, isLink: Bool = false, linkTarget: String? = nil) {
        self.paramName = paramName
        self.columnType = columnType
        self.isLink = isLink
        self.linkTarget = linkTarget
    }
}

/// One case of a `@Union`. Bare cases (no payload) have an empty `values`.
public struct UnionCase: Sendable, Codable, Hashable {
    public var name: String
    public var values: [UnionCaseValue]

    public init(name: String, values: [UnionCaseValue] = []) {
        self.name = name
        self.values = values
    }
}

/// Runtime description of one property of a model, recovered from the schema
/// snapshot persisted in the database (or a best-effort fallback).
public struct PropertyInfo: Sendable, Codable, Hashable {
    public var name: String
    public var kind: PropertyKind
    public var columnType: ColumnType
    public var isOptional: Bool
    public var isIndexed: Bool
    public var isUnique: Bool
    public var isFullText: Bool
    public var isVector: Bool
    public var isGeoBounds: Bool
    /// Target table for `link` / `list`, or the union table for `unionType`.
    public var linkTarget: String?
    /// Cases when `kind == .unionType`.
    public var unionCases: [UnionCase]

    public init(name: String,
                kind: PropertyKind,
                columnType: ColumnType,
                isOptional: Bool = false,
                isIndexed: Bool = false,
                isUnique: Bool = false,
                isFullText: Bool = false,
                isVector: Bool = false,
                isGeoBounds: Bool = false,
                linkTarget: String? = nil,
                unionCases: [UnionCase] = []) {
        self.name = name
        self.kind = kind
        self.columnType = columnType
        self.isOptional = isOptional
        self.isIndexed = isIndexed
        self.isUnique = isUnique
        self.isFullText = isFullText
        self.isVector = isVector
        self.isGeoBounds = isGeoBounds
        self.linkTarget = linkTarget
        self.unionCases = unionCases
    }

    /// True for the scalar kinds the result serializer reads via `AnyProperty`
    /// (everything that isn't a relationship/union).
    public var isScalar: Bool { kind == .primitive }
}

/// Runtime description of one model table.
public struct ObjectSchema: Sendable, Codable, Hashable {
    public var name: String
    public var properties: [PropertyInfo]

    public init(name: String, properties: [PropertyInfo]) {
        self.name = name
        self.properties = properties
    }

    public func property(named name: String) -> PropertyInfo? {
        properties.first { $0.name == name }
    }
}
