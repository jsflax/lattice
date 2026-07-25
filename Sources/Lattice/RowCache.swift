import Foundation
#if canImport(LatticeSwiftCppBridge)
import LatticeSwiftCppBridge
#endif

// MARK: - Materialized reads (row cache)
//
// A Lattice model is a live handle: every property read is its own
// `SELECT col WHERE id = ?`. That is the right default for observation, and
// catastrophic for read-heavy formatting code — Engram's recall issued ~300
// statements per call, each paying an O(WAL-frames) page lookup while a sync
// daemon churned the WAL (228s observed for one recall).
//
// `materialize()` flips the object's backend into materialized-read mode:
// reads are served from the row snapshot the originating query ALREADY
// hydrated (zero further SQL), falling through to the live path on any miss
// or type mismatch — slower, never wrong. Writes remain write-through and
// update the snapshot, so read-your-writes holds. The snapshot does NOT see
// concurrent writers until `refreshMaterialized()` — that staleness is the
// point: a consistent row image for formatting/serialization.
//
// ROW-CACHE v1 CONTRACT — links / lists / unions FALL THROUGH (pinned by
// RowCacheContractTests; deliberate v1 scope, NOT a bug):
// - SCALARS (Int/Double/Bool/String/Data/Date/UUID/enum raw values) are the
//   snapshot: stale under a concurrent writer until `refreshMaterialized()`.
// - LINKS are fully live: traversal never consults the snapshot (the bridge's
//   `get_object` re-resolves the link column by parent id and hydrates the
//   target through the live path), so BOTH a concurrent relink of the parent's
//   link column AND writes to the target's fields are visible through a
//   materialized parent — and traversal issues SQL.
// - LISTS (`List`/`VirtualList`) read through their link-list backend on
//   every access: membership, order, and element fields are always live.
// - UNIONS marshal through the C++ union_value handle per read: case and
//   payload are always live (payload links hydrate live, as above).
// v1 materializes exactly ONE row image; it does not pin a graph. Code that
// needs a coherent snapshot of a graph should use `detached()` (depth-aware)
// instead. A future version may extend materialization across links — that
// would be a behavior CHANGE for the traversal cases above, gated by the
// contract tests.

public extension Model {
    /// Serve this object's property reads from its hydrated row snapshot.
    /// Zero additional SQL for objects that came from a query. Opt-in and
    /// reversible; unmanaged objects are already value snapshots (no-op).
    @discardableResult
    func materialize() -> Self {
        _dynamicObject._ref.enableRowCache()
        return self
    }

    /// Back to live (per-column) reads.
    func dematerialize() {
        _dynamicObject._ref.disableRowCache()
    }

    var isMaterialized: Bool {
        _dynamicObject._ref.isRowCacheEnabled
    }

    /// Re-fetch the row in ONE statement — the staleness escape hatch for a
    /// materialized object that must observe another writer's changes.
    func refreshMaterialized() {
        _dynamicObject._ref.refreshRowCache()
    }

    /// Run `body` with materialized reads, restoring the prior mode after.
    /// Use for read-heavy scopes over live objects (formatting, export)
    /// without changing the object's long-term semantics.
    func withMaterializedReads<T>(_ body: () throws -> T) rethrows -> T {
        let wasMaterialized = isMaterialized
        if !wasMaterialized { _dynamicObject._ref.enableRowCache() }
        defer { if !wasMaterialized { _dynamicObject._ref.disableRowCache() } }
        return try body()
    }

    /// Snapshot scope for `detached()`: an already-materialized object
    /// detaches from its existing snapshot (0 SQL); a live object refreshes
    /// ONCE (1 statement — still strictly better than one statement per
    /// field) so `detached()` keeps its read-time-freshness contract for
    /// existing callers, then restores live reads.
    func withDetachSnapshot<T>(_ body: () throws -> T) rethrows -> T {
        guard isManaged else { return try body() }
        let wasMaterialized = isMaterialized
        if !wasMaterialized {
            _dynamicObject._ref.refreshRowCache()
            _dynamicObject._ref.enableRowCache()
        }
        defer { if !wasMaterialized { _dynamicObject._ref.disableRowCache() } }
        return try body()
    }

    /// SQL-side atomic increment: `SET field = field + delta` under the
    /// write lock. No read-modify-write race — two concurrent bumps both
    /// land — and half the statements of `x += 1`. `field` must be a stored
    /// integer column name (pass the same name the accessor uses).
    func increment(_ field: String, by delta: Int64 = 1) {
        _dynamicObject._ref.incrementInt(named: field, by: delta)
    }
}

public extension TableResults {
    /// `snapshot()` with every element flipped to materialized reads — the
    /// query already hydrated each row, so subsequent property access on the
    /// returned objects issues no SQL.
    func materializedSnapshot(limit: Int64? = nil, offset: Int64? = nil) -> [Element] {
        snapshot(limit: limit, offset: offset).map { $0.materialize() }
    }
}

#if canImport(LatticeSwiftCppBridge)
public extension Lattice {
    /// Process-global count of SQL statements issued through the database
    /// layer, across ALL connections and lattices. A test/benchmark
    /// primitive for statement-budget assertions (e.g. "recall is O(K+C+F)
    /// statements, not O(fields × K)"). Global by design — object reads span
    /// read/write/xproc connections over multiple lattice instances, so
    /// per-connection counters undercount. Serialize tests that assert on
    /// deltas.
    /// - Note: iOS 16.4+ — the `swift_lattice` C++ interop module carries a
    ///   16.4 floor (the foreign-reference-type boundary), so this accessor
    ///   inherits it. macOS/Linux (where the tests run) are unaffected.
    @available(iOS 16.4, macOS 13.3, tvOS 16.4, watchOS 9.4, *)
    static var totalSQLStatementCount: UInt64 {
        lattice.swift_lattice.totalSQLStatementCount()
    }

    /// Thread-local twin of `totalSQLStatementCount`: counts only statements
    /// issued from the calling thread. Use for EXACT budgets on synchronous
    /// read paths — immune to parallel test suites in the same process.
    /// - Note: iOS 16.4+ — see `totalSQLStatementCount`.
    @available(iOS 16.4, macOS 13.3, tvOS 16.4, watchOS 9.4, *)
    static var threadSQLStatementCount: UInt64 {
        lattice.swift_lattice.threadSQLStatementCount()
    }
}
#endif
