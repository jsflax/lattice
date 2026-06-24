import Foundation

// MARK: - DynamicObject -> JSON serialization
//
// Reconstructs the ORM "data view" as a JSONSerialization-compatible value:
// scalars as native values, to-one links recursed to a depth, to-many lists as
// arrays, embedded JSON inlined, geo as {lat/lon} or bounds, vectors omitted by
// default. Cycle-safe (tracks table:globalId) and depth-bounded. This is what
// the MCP's lattice_query/get tools return.
extension DynamicObject {

    /// Serialize to a `[String: Any]` suitable for `JSONSerialization`.
    /// - maxDepth: how many link hops to follow (0 = links become {globalId}).
    /// - includeVectors: emit vector columns (base64) instead of omitting them.
    public func jsonObject(maxDepth: Int = 5, includeVectors: Bool = false) -> [String: Any] {
        var visited = Set<String>()
        return Self._json(self, depth: maxDepth, includeVectors: includeVectors, visited: &visited)
    }

    private static func _json(_ obj: DynamicObject,
                              depth: Int,
                              includeVectors: Bool,
                              visited: inout Set<String>) -> [String: Any] {
        var out: [String: Any] = [:]
        if let gid = obj.globalId { out["globalId"] = gid }
        if let pk = obj.primaryKey { out["id"] = pk }

        // Cycle guard keyed by identity.
        let key = "\(obj.tableName):\(obj.globalId ?? "")"
        if obj.globalId != nil { visited.insert(key) }

        let b = obj.backend
        for prop in obj.properties {
            let name = prop.name
            switch prop.kind {
            case .primitive:
                if prop.isVector {
                    if includeVectors, b.hasValue(named: name) {
                        out[name] = b.getData(named: name).base64EncodedString()
                    }
                    continue
                }
                if prop.isGeoBounds {
                    if let geo = geoValue(b, name) { out[name] = geo }
                    continue
                }
                guard b.hasValue(named: name) else { continue }
                switch prop.columnType {
                case .integer: out[name] = b.getInt(named: name)
                case .real:    out[name] = b.getDouble(named: name)
                case .blob:    out[name] = b.getData(named: name).base64EncodedString()
                case .text:    out[name] = inlineText(b.getString(named: name))
                }

            case .link, .virtualLink:
                let linked = b.getObject(named: name)
                guard linked.hasLattice else { continue }
                let child = DynamicObject(backend: linked)
                if depth > 0, !(child.globalId.map { visited.contains("\(child.tableName):\($0)") } ?? false) {
                    out[name] = _json(child, depth: depth - 1, includeVectors: includeVectors, visited: &visited)
                } else if let gid = child.globalId {
                    out[name] = ["globalId": gid]
                }

            case .list, .virtualList:
                if prop.isGeoBounds {
                    // Geo-bounds list lives in a sidecar table; expose its count.
                    out[name] = ["geoBoundsCount": b.getLinkList(named: name).size]
                    continue
                }
                let listBackend = b.getLinkList(named: name)
                if depth > 0 {
                    var arr: [[String: Any]] = []
                    for i in 0..<listBackend.size {
                        guard let el = listBackend.object(at: i) else { continue }
                        let child = DynamicObject(backend: el)
                        if let gid = child.globalId, visited.contains("\(child.tableName):\(gid)") {
                            arr.append(["globalId": gid])
                        } else {
                            arr.append(_json(child, depth: depth - 1, includeVectors: includeVectors, visited: &visited))
                        }
                    }
                    out[name] = arr
                } else {
                    out[name] = ["count": listBackend.size]
                }

            case .unionType:
                // Stored as the union row's globalId; rich case decoding is a
                // follow-up. Surface the raw reference for now.
                if b.hasValue(named: name) { out[name] = ["unionRef": b.getString(named: name)] }
            }
        }
        return out
    }

    /// If `text` parses as a JSON array/object, return the parsed value (so
    /// embedded arrays/dicts inline); otherwise return the raw string.
    private static func inlineText(_ text: String) -> Any {
        guard let first = text.first, first == "[" || first == "{",
              let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return text
        }
        return parsed
    }

    /// Read a single geo_bounds value (stored as 4 sub-columns) → {lat,lon} for a
    /// point, or {minLat,maxLat,minLon,maxLon} for a box. nil if absent.
    private static func geoValue(_ b: any ObjectBackend, _ name: String) -> [String: Any]? {
        let minLatC = "\(name)_minLat", maxLatC = "\(name)_maxLat"
        let minLonC = "\(name)_minLon", maxLonC = "\(name)_maxLon"
        guard b.hasValue(named: minLatC) else { return nil }
        let minLat = b.getDouble(named: minLatC), maxLat = b.getDouble(named: maxLatC)
        let minLon = b.getDouble(named: minLonC), maxLon = b.getDouble(named: maxLonC)
        if minLat == maxLat && minLon == maxLon { return ["lat": minLat, "lon": minLon] }
        return ["minLat": minLat, "maxLat": maxLat, "minLon": minLon, "maxLon": maxLon]
    }
}
