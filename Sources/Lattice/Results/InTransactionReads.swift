import Foundation

// MARK: - Explicit-transaction writer-connection reads (§4.1, file-store
// carve-out)
//
// Inside an explicit transaction, collection reads must see the
// transaction's OWN uncommitted writes (read-your-writes) and must not
// touch the generation machinery:
//
//  - Keeper generations are MVCC snapshots held by pooled READ connections;
//    a separate connection can never see the writer connection's open
//    transaction, so a generation-routed read inside the transaction serves
//    the pre-transaction state (the live-reproduced conformance divergence
//    `transactions/own-writes-visible-inside`).
//  - Minting a keeper while this thread holds the transaction is the
//    in-txn deadlock class from the 27-agent review: keeper acquisition
//    is SQL against the store the transaction holds open.
//  - The §4.1 memory family gets read-your-writes for free — the core has
//    no separate read connection for memory databases (`read_db()` falls
//    back to the writer), so its in-txn live reads (the `_gatedLiveRead`
//    skip) already execute on the writer connection. File stores DO have a
//    separate read-only connection, and every generic live read
//    (`objects` / `count` / `object(primaryKey:)`) routes through it — so
//    file stores need an explicit writer-connection route.
//
// The ONLY generic Swift-reachable core read that executes on the WRITER
// connection without opening its own transaction is the zero-constraint
// branch of `combinedNearestQuery` / `combinedNearestQueryCount`: with no
// bounds/vector/geo/text constraints it degrades to
//
//     SELECT *        FROM <table> [WHERE <predicate>] LIMIT <n>
//     SELECT COUNT(*) FROM <table> [WHERE <predicate>] LIMIT <n>
//
// issued on `db()` (LatticeSwiftCppBridge lattice.hpp, the
// `ctes.sql.empty()` branch). `<predicate>` is raw SQL text the SDK already
// authors (it is the same string `objects()` sends), so ORDER BY / GROUP
// BY / pagination are folded into it — producing EXACTLY the statement
// shapes the core's own `build_query_rows_sql` / `build_count_sql` emit,
// executed on the writer instead of the read connection. Row handles come
// back through the same hydration path as `objects()` (live property
// semantics on the writer connection), so hydrated instances read the
// transaction's values too.
//
// These helpers are only ever called when
// `Lattice._threadHoldsExplicitTransaction` is true for this backend — the
// same detector the §4.1 memory-family carve-outs use. They never touch
// the generation coordinator: no keeper is minted, no epoch cache is read
// or published, so a rollback leaves nothing poisoned (the core's rollback
// hook then bumps the epoch and every shape re-captures).
extension Lattice {

    /// Zero-constraint sort sentinel for the writer-connection reads (the
    /// effective ORDER BY travels inside the predicate instead).
    private static let _writerReadNoSort =
        SortDescriptorParam(kind: .none, column: "", ascending: true)

    /// Row read on the WRITER connection. `orderBy` / `groupBy` /
    /// `distinctBy` / `limit` / `offset` mirror `backend.objects`; results
    /// are raw backend rows for the caller to hydrate.
    internal func _writerTransactionRows(table: String,
                                         where whereSQL: String?,
                                         orderBy: String?,
                                         limit: Int64?,
                                         offset: Int64?,
                                         groupBy: String?,
                                         distinctBy: String?) -> [any ObjectBackend] {
        let composed = Self._writerRowsPredicate(table: table, where: whereSQL,
                                                 orderBy: orderBy, limit: limit,
                                                 offset: offset, groupBy: groupBy,
                                                 distinctBy: distinctBy)
        return backend.combinedNearestQuery(table: table,
                                            bounds: [], vectors: [], geos: [], texts: [],
                                            where: composed.predicate,
                                            sort: Self._writerReadNoSort,
                                            limit: composed.limit,
                                            groupBy: nil, distinctBy: nil)
            .map(\.object)
    }

    /// COUNT on the WRITER connection, mirroring `build_count_sql`
    /// semantics: plain COUNT(*), COUNT(DISTINCT distinctBy/groupBy) —
    /// NULL-excluded — and, when both are present, COUNT(DISTINCT groupBy)
    /// over the distinctBy-deduplicated rows.
    internal func _writerTransactionCount(table: String,
                                          where whereSQL: String?,
                                          groupBy: String?,
                                          distinctBy: String?) -> Int {
        let predicate = Self._writerCountPredicate(table: table, where: whereSQL,
                                                   groupBy: groupBy, distinctBy: distinctBy)
        return Int(backend.combinedNearestQueryCount(table: table,
                                                     bounds: [], vectors: [], geos: [], texts: [],
                                                     where: predicate,
                                                     sort: Self._writerReadNoSort,
                                                     limit: Int64.max,
                                                     groupBy: nil, distinctBy: nil))
    }

    /// Composes the predicate for the writer-connection ROW read. The core
    /// appends exactly ` LIMIT <limit>` after the predicate, so:
    ///  - no ordering/grouping/offset → pass the WHERE through and use the
    ///    core's LIMIT slot directly;
    ///  - ordering and/or one grouping column, no offset → append
    ///    `GROUP BY` / `ORDER BY` to the predicate (the core's LIMIT lands
    ///    after them — the exact single-SELECT `build_query_rows_sql`
    ///    shape);
    ///  - offset, or distinct+group nesting → fold the whole shaped query
    ///    into an `id IN (SELECT id …)` membership test (ids are unique per
    ///    delivered row, grouped shapes select their representative row's
    ///    id exactly as the core's bare-column GROUP BY does), then restore
    ///    the delivery order outside.
    internal static func _writerRowsPredicate(table: String,
                                              where whereSQL: String?,
                                              orderBy: String?,
                                              limit: Int64?,
                                              offset: Int64?,
                                              groupBy: String?,
                                              distinctBy: String?) -> (predicate: String?, limit: Int64) {
        let grouping = distinctBy ?? groupBy
        let nested = distinctBy != nil && groupBy != nil

        if orderBy == nil && grouping == nil && offset == nil {
            return (whereSQL, limit ?? Int64.max)
        }

        if offset == nil && !nested {
            var predicate = whereSQL ?? "1=1"
            if let grouping { predicate += " GROUP BY \(grouping)" }
            if let orderBy { predicate += " ORDER BY \(orderBy)" }
            return (predicate, limit ?? Int64.max)
        }

        let whereFragment = whereSQL.map { " WHERE \($0)" } ?? ""
        var inner: String
        if nested {
            // Mirror build_query_rows_sql's distinct+group nesting: dedup by
            // distinctBy first, then group the surviving rows.
            inner = "SELECT id FROM (SELECT * FROM \(table)\(whereFragment)"
                + " GROUP BY \(distinctBy!)) GROUP BY \(groupBy!)"
        } else {
            inner = "SELECT id FROM \(table)\(whereFragment)"
            if let grouping { inner += " GROUP BY \(grouping)" }
        }
        if let orderBy { inner += " ORDER BY \(orderBy)" }
        if limit != nil || offset != nil {
            inner += " LIMIT \(limit ?? -1)"   // -1 = unbounded (SQLite)
            if let offset { inner += " OFFSET \(offset)" }
        }
        var predicate = "id IN (\(inner))"
        if let orderBy { predicate += " ORDER BY \(orderBy)" }
        return (predicate, Int64.max)
    }

    /// Composes the predicate for the writer-connection COUNT.
    /// Grouped/distinct counts enumerate one representative id per group
    /// (`GROUP BY` on a bare `id` projection), excluding NULL group keys —
    /// COUNT(*) over that membership equals the core's
    /// `COUNT(DISTINCT …)`.
    internal static func _writerCountPredicate(table: String,
                                               where whereSQL: String?,
                                               groupBy: String?,
                                               distinctBy: String?) -> String? {
        let nested = distinctBy != nil && groupBy != nil
        guard let grouping = (nested ? groupBy : (distinctBy ?? groupBy)) else {
            return whereSQL
        }
        let whereFragment = whereSQL.map { " WHERE \($0)" } ?? ""
        if nested {
            return "id IN (SELECT id FROM (SELECT * FROM \(table)\(whereFragment)"
                + " GROUP BY \(distinctBy!))"
                + " WHERE \(grouping) IS NOT NULL GROUP BY \(grouping))"
        }
        let base = whereSQL.map { "(\($0)) AND " } ?? ""
        return "id IN (SELECT id FROM \(table) WHERE \(base)\(grouping) IS NOT NULL"
            + " GROUP BY \(grouping))"
    }
}
