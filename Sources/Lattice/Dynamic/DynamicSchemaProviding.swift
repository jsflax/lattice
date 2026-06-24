import Foundation
import LatticeSwiftCppBridge
import CxxStdlib

// MARK: - DynamicSchemaProviding
//
// A backend capable of describing a dynamically-opened database's schema —
// the model tables and their property descriptors, reconstructed from the file
// (see LatticeCore's swift_lattice::reconstruct_swift_schema_from_db). Adopted
// by `CxxBackend`; consumed by `Lattice.dynamicSchema`, `DynamicObject`, and
// `DynamicResults`. Kept off the hot-path `LatticeBackend` protocol so that
// stays lean — this is a side capability of the same backend, not a new one.

public protocol DynamicSchemaProviding {
    func dynamicTableNames() -> [String]
    func dynamicProperties(table: String) -> [PropertyInfo]
}

extension CxxBackend: DynamicSchemaProviding {
    func dynamicTableNames() -> [String] {
        let names = ref.dynamicTableNames()
        var out: [String] = []
        out.reserveCapacity(names.size())
        for i in 0..<names.size() { out.append(String(names[i])) }
        return out
    }

    func dynamicProperties(table: String) -> [PropertyInfo] {
        let descs = ref.dynamicPropertiesFor(std.string(table))
        var out: [PropertyInfo] = []
        out.reserveCapacity(descs.size())
        for i in 0..<descs.size() { out.append(Self.map(descs[i])) }
        return out
    }

    /// Map a C++ `property_descriptor` to a Sendable Swift `PropertyInfo`.
    private static func map(_ d: lattice.property_descriptor) -> PropertyInfo {
        let target = String(d.target_table)
        var unionCases: [UnionCase] = []
        if d.is_union {
            let cs = d.union_desc.cases
            for i in 0..<cs.size() {
                let c = cs[i]
                let vs = c.values
                var vals: [UnionCaseValue] = []
                for j in 0..<vs.size() {
                    let v = vs[j]
                    let lt = String(v.link_target)
                    vals.append(UnionCaseValue(paramName: String(v.param_name),
                                               columnType: mapColumn(v.type),
                                               isLink: v.is_link,
                                               linkTarget: lt.isEmpty ? nil : lt))
                }
                unionCases.append(UnionCase(name: String(c.case_name), values: vals))
            }
        }
        return PropertyInfo(
            name: String(d.name),
            kind: mapKind(d.kind),
            columnType: mapColumn(d.type),
            isOptional: d.nullable,
            isIndexed: d.is_indexed,
            isUnique: d.is_unique,
            isFullText: d.is_full_text,
            isVector: d.is_vector,
            isGeoBounds: d.is_geo_bounds,
            linkTarget: target.isEmpty ? nil : target,
            unionCases: unionCases)
    }

    private static func mapColumn(_ t: lattice.column_type) -> ColumnType {
        switch t {
        case .integer: return .integer
        case .real:    return .real
        case .blob:    return .blob
        default:       return .text   // catch-all = text
        }
    }

    private static func mapKind(_ k: lattice.property_kind) -> PropertyKind {
        switch k {
        case .link:         return .link
        case .list:         return .list
        case .virtual_list: return .virtualList
        case .virtual_link: return .virtualLink
        case .union_type:   return .unionType
        default:            return .primitive   // catch-all = primitive
        }
    }
}
