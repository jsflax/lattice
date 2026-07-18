import Foundation

// MARK: - DynamicResults
//
// Lazy, query-buildable results over a single table of a dynamically-opened
// lattice. Mirrors `TableResults` but is keyed by a runtime table name and
// yields type-erased `DynamicObject`s. The where/orderBy SQL fragments are
// supplied by the caller (the MCP builds + validates them against the schema
// before calling — see Phase 3).
//
// 1.0 SEMANTICS NOTE — generation-model exemption (item A ledger, G9):
// `DynamicResults` deliberately keeps LIVE `count` + LIMIT/OFFSET `snapshot`
// semantics; it does NOT adopt the typed `Results` family's generation-pinned
// (A2-lite) read model. It is trap-free under concurrent shrink by
// construction: there is no positional `subscript`/`element(at:)` to guard —
// `snapshot(limit:offset:)` is a single SQL query returning whatever matches
// at execution time, `count` is a live COUNT(*), and `first` is
// `snapshot(limit: 1)`. The corollary: a `count` and a subsequent `snapshot`
// are NOT mutually consistent under a concurrent writer — callers needing a
// coherent page (the MCP serializer does) must take ONE `snapshot()` and
// derive counts/slices from the returned array.
public final class DynamicResults: @unchecked Sendable {
    private let backend: any LatticeBackend
    public let tableName: String
    private let whereClause: String?
    private let orderByClause: String?

    init(backend: any LatticeBackend,
         tableName: String,
         whereClause: String? = nil,
         orderByClause: String? = nil) {
        self.backend = backend
        self.tableName = tableName
        self.whereClause = whereClause
        self.orderByClause = orderByClause
    }

    /// AND the given SQL fragment onto the current filter.
    public func `where`(_ sql: String) -> DynamicResults {
        let combined = whereClause.map { "(\($0)) AND (\(sql))" } ?? sql
        return DynamicResults(backend: backend, tableName: tableName,
                              whereClause: combined, orderByClause: orderByClause)
    }

    /// Append an ORDER BY term. Named `sortedBy` to match the typed results
    /// surface (`Results.sortedBy(_:order:)`) — one sort spelling API-wide.
    public func sortedBy(_ column: String, ascending: Bool = true) -> DynamicResults {
        let term = "\(column) \(ascending ? "ASC" : "DESC")"
        let combined = orderByClause.map { "\($0), \(term)" } ?? term
        return DynamicResults(backend: backend, tableName: tableName,
                              whereClause: whereClause, orderByClause: combined)
    }

    public var count: Int {
        Int(backend.count(table: tableName, where: whereClause, groupBy: nil, distinctBy: nil))
    }

    /// Materialize matching rows as `DynamicObject`s. The table schema is fetched
    /// once and injected into each object (avoids a per-object lookup).
    public func snapshot(limit: Int? = nil, offset: Int? = nil) -> [DynamicObject] {
        let schema = (backend as? any DynamicSchemaProviding)?.dynamicProperties(table: tableName)
        let rows = backend.objects(table: tableName,
                                   where: whereClause, orderBy: orderByClause,
                                   limit: limit.map(Int64.init), offset: offset.map(Int64.init),
                                   groupBy: nil, distinctBy: nil)
        return rows.map { DynamicObject(backend: $0, schema: schema) }
    }

    public var first: DynamicObject? { snapshot(limit: 1).first }
}
