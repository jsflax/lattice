import Foundation
import LatticeSwiftCppBridge
import LatticeDebugBridge
import CxxStdlib

/// A sealed backend failure encountered while constructing a debug response.
/// This is distinct from invalid input: callers must not report a defaulted field as valid data.
public enum DynamicDebugReadError: Error, CustomStringConvertible, Sendable {
    case queryFailed(String)
    public var description: String {
        switch self { case .queryFailed(let message): message }
    }
}

extension DynamicObject {
    /// A candidate query key with immediate backend error checking. A live
    /// object's identity is not a substitute for authorizing its returned values.
    public func debugPrimaryKey() throws -> Int64? {
        try Self.debugPrimaryKey(backend)
    }

    /// A bounded data view for interactive debugging. Projection is applied before fetching values
    /// or traversing links. The optional policy is supplied by the embedding host, never by a query.
    /// TEXT stays literal, including JSON-looking strings. Each sealed read is checked immediately,
    /// before another getter can clear the bridge's thread-local error slot.
    public func debugJSON(fields: Set<String>? = nil, maxDepth: Int = 0,
                          permittedFields: [String: Set<String>]? = nil) throws -> [String: Any] {
        var remaining = 100
        var visited = Set<String>()
        return try Self.debugObject(self, fields: fields, depth: maxDepth, policy: permittedFields,
                                    remaining: &remaining, visited: &visited)
    }

    private static func checkedDebugRead<Value>(_ backend: any ObjectBackend,
                                                 _ operation: () -> Value) throws -> Value {
        let value = operation()
        // Keep checking off the generic object hot path. The same thread runs
        // the synchronous getter and reads its error; no actor hop intervenes.
        if let object = backend as? CxxObjectBackend {
            let message = String(object.ref.lastQueryErrorMessage())
            if !message.isEmpty { throw DynamicDebugReadError.queryFailed(message) }
        }
        return value
    }

    private static func debugGlobalID(_ backend: any ObjectBackend) throws -> String? {
        guard try checkedDebugRead(backend, { backend.hasValue(named: "globalId") }) else { return nil }
        return try checkedDebugRead(backend, { backend.getString(named: "globalId") })
    }

    private static func debugPrimaryKey(_ backend: any ObjectBackend) throws -> Int64? {
        guard try checkedDebugRead(backend, { backend.hasValue(named: "id") }) else { return nil }
        return try checkedDebugRead(backend, { backend.getInt(named: "id") })
    }

    private static func debugLinkedObject(_ backend: any ObjectBackend, name: String) throws -> (any ObjectBackend)? {
        guard let object = backend as? CxxObjectBackend else {
            return try checkedDebugRead(backend, { backend.getObject(named: name) })
        }
        let candidate = try checkedDebugRead(backend, { lattice_debug.getObject(object.ref, named: std.string(name)) })
        guard let reference = _optRef(candidate) else { return nil }
        return CxxObjectBackend(reference)
    }

    private static func debugListSize(_ backend: any ObjectBackend, name: String) throws -> Int {
        if let object = backend as? CxxObjectBackend {
            return try checkedDebugRead(backend, { lattice_debug.listCount(object.ref, named: std.string(name)) })
        }
        let list = try checkedDebugRead(backend, { backend.getLinkList(named: name) })
        return try checkedDebugRead(backend, { list.size })
    }

    private static func debugListObject(_ backend: any ObjectBackend, name: String,
                                        index: Int) throws -> (any ObjectBackend)? {
        guard let object = backend as? CxxObjectBackend else {
            let list = try checkedDebugRead(backend, { backend.getLinkList(named: name) })
            return try checkedDebugRead(backend, { list.object(at: index) })
        }
        let candidate = try checkedDebugRead(backend, {
            lattice_debug.listObject(object.ref, named: std.string(name), at: index)
        })
        guard let reference = _optRef(candidate) else { return nil }
        return CxxObjectBackend(reference)
    }

    private static func debugObject(_ object: DynamicObject, fields: Set<String>?, depth: Int,
                                    policy: [String: Set<String>]?, remaining: inout Int,
                                    visited: inout Set<String>) throws -> [String: Any] {
        let backend = object.backend
        let table = try checkedDebugRead(backend, { backend.tableName })
        guard policy == nil || policy?[table] != nil else { return [:] }
        let globalID = try debugGlobalID(backend)
        let primaryKey = try debugPrimaryKey(backend)
        var result: [String: Any] = [:]
        if let globalID { result["globalId"] = globalID }
        if let primaryKey { result["id"] = primaryKey }
        let identity = "\(table):\(globalID ?? String(primaryKey ?? -1))"
        guard remaining > 0, visited.insert(identity).inserted else { return result }
        remaining -= 1
        var omissions: [String: String] = [:]
        let properties = try checkedDebugRead(backend, { object.properties })
        for property in properties {
            let name = property.name
            guard fields == nil || fields!.contains(name),
                  policy == nil || policy?[table]?.contains(name) == true else { continue }
            switch property.kind {
            case .primitive:
                if property.isVector || property.columnType == .blob {
                    omissions[name] = property.isVector ? "vector" : "blob"
                    continue
                }
                if property.isGeoBounds {
                    if try checkedDebugRead(backend, { backend.hasValue(named: "\(name)_minLat") }) {
                        var bounds: [String: Double] = [:]
                        for component in ["minLat", "maxLat", "minLon", "maxLon"] {
                            let value = try checkedDebugRead(backend, { backend.getDouble(named: "\(name)_\(component)") })
                            if value.isFinite { bounds[component] = value }
                        }
                        if bounds.count == 4 { result[name] = bounds }
                        else { result[name] = NSNull(); omissions[name] = "non_finite_number" }
                    }
                    continue
                }
                guard try checkedDebugRead(backend, { backend.hasValue(named: name) }) else {
                    result[name] = NSNull(); continue
                }
                switch property.columnType {
                case .integer:
                    result[name] = try checkedDebugRead(backend, { backend.getInt(named: name) })
                case .real:
                    let number = try checkedDebugRead(backend, { backend.getDouble(named: name) })
                    if number.isFinite { result[name] = number }
                    else { result[name] = NSNull(); omissions[name] = "non_finite_number" }
                case .text:
                    let value = try checkedDebugRead(backend, { backend.getString(named: name) })
                    if value.utf8.count > 2_048 {
                        // Drop an incomplete trailing UTF-8 code point rather than replacing it.
                        var prefix = Array(value.utf8.prefix(2_048))
                        while String(bytes: prefix, encoding: .utf8) == nil { prefix.removeLast() }
                        result[name] = String(decoding: prefix, as: UTF8.self)
                        omissions[name] = "text_excerpt; originalBytes=\(value.utf8.count)"
                    } else { result[name] = value }
                case .blob: break
                }
            case .link, .virtualLink:
                guard policy == nil || property.linkTarget.map({ policy?[$0] != nil }) == true else { continue }
                guard let linked = try debugLinkedObject(backend, name: name) else { result[name] = NSNull(); continue }
                guard try checkedDebugRead(linked, { linked.hasLattice }) else { result[name] = NSNull(); continue }
                let child = DynamicObject(backend: linked)
                if depth > 0 {
                    result[name] = try debugObject(child, fields: nil, depth: depth - 1, policy: policy,
                                                   remaining: &remaining, visited: &visited)
                } else if let id = try debugGlobalID(linked) { result[name] = ["globalId": id] }
            case .list, .virtualList:
                guard policy == nil || property.linkTarget.map({ policy?[$0] != nil }) == true else { continue }
                let total = try debugListSize(backend, name: name)
                if depth == 0 || property.isGeoBounds { result[name] = ["count": total]; continue }
                var rows: [[String: Any]] = []
                for index in 0..<min(total, 20) {
                    guard remaining > 0 else { break }
                    guard let linked = try debugListObject(backend, name: name, index: index) else { break }
                    rows.append(try debugObject(DynamicObject(backend: linked), fields: nil, depth: depth - 1,
                                                policy: policy, remaining: &remaining, visited: &visited))
                }
                result[name] = rows
                if rows.count < total { omissions[name] = "relationship_excerpt; total=\(total)" }
            case .unionType:
                if try checkedDebugRead(backend, { backend.hasValue(named: name) }) {
                    result[name] = ["unionRef": try checkedDebugRead(backend, { backend.getString(named: name) })]
                }
            }
        }
        if !omissions.isEmpty { result["_latticeDebugOmissions"] = omissions }
        return result
    }
}
