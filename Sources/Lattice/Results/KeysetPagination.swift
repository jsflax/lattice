import Foundation

// MARK: - Keyset pagination (item A §2.4, Commit 2)
//
// Page fills and iteration resume by *keyset*: the effective total order is
// always `(sortColumn userDir, id ASC)` (unsorted queries get `ORDER BY id
// ASC` — `id INTEGER PRIMARY KEY AUTOINCREMENT` exists on every model table),
// and a fill after anchor `(v, k)` ANDs a NULL-aware resume predicate into
// the shape's WHERE clause instead of paying `OFFSET` per page. The resume
// predicate is *position-free* (pure content comparison), which is what makes
// anchors safe to keep across epoch bumps: a stale anchor is rank-approximate
// but content-exact, so a refill starts at the same content position
// (content-anchored, §2.4) and never traps.
//
// Grouped/distinct/bbox shapes have no sound keyset anchor (grouped rows lack
// stable `(col, id)` identity; bbox routes through an R*Tree join) — they
// keep OFFSET page fills (§2.4/§4.5 carve-out; MVCC-consistent within a
// generation once keepers land, Commit 5).

// MARK: KeysetAnchor

/// One page-boundary anchor: the `(sortValue, id)` of the LAST row of a
/// filled page (~24 B). Recorded on every full-page fill; persistent —
/// surviving page-LRU eviction AND epoch bumps (§2.4) — for the life of the
/// query shape.
struct KeysetAnchor {
    enum Value {
        /// Shape has no user sort column: the walk is `ORDER BY id ASC` and
        /// the anchor is id-only.
        case unsorted
        /// The sort value at the boundary IS NULL (SQLite: NULLs sort first
        /// ASC, last DESC).
        case null
        case int(Int64)        // INTEGER-affinity sort columns (incl. Bool/enum raw)
        case double(Double)    // REAL (Double/Float/Date)
        case string(String)    // TEXT (String/UUID/URL/string enums/JSON columns)
        case blob(Data)        // BLOB (Data)
    }
    let value: Value
    let id: Int64
}

// MARK: KeysetSortSpec

/// The resolved sort identity a keyset walk needs: column, direction, and the
/// column's schema kind (which typed getter extracts the anchor value and how
/// it is rendered as a SQL literal). `column == nil` means "no user sort" —
/// the deterministic `ORDER BY id ASC` walk.
struct KeysetSortSpec {
    let column: String?
    let ascending: Bool
    let kind: AnyProperty.Kind

    /// Resolve a facade's sort column against the Element schema. Returns nil
    /// when the shape cannot be keyset-paged (sort column is not a stored
    /// primitive — links, unions, geo, virtual members — so no total order
    /// over `(col, id)` can be anchored; those shapes take the OFFSET
    /// carve-out).
    static func resolve<M: Model>(for elementType: M.Type,
                                  sortColumn: (name: String, order: SortOrder)?) -> KeysetSortSpec? {
        guard let sortColumn else {
            return KeysetSortSpec(column: nil, ascending: true, kind: .int64)
        }
        let ascending = sortColumn.order == .forward
        // `id` is macro-managed (not in `properties`) and never NULL.
        if sortColumn.name == "id" {
            return KeysetSortSpec(column: "id", ascending: ascending, kind: .int64)
        }
        guard let property = elementType.properties.first(where: { $0.0 == sortColumn.name })?.1,
              let primitive = property as? any PrimitiveProperty.Type else {
            return nil
        }
        let kind = primitive.anyPropertyKind
        guard kind != .null else { return nil }
        return KeysetSortSpec(column: sortColumn.name, ascending: ascending, kind: kind)
    }
}

// MARK: KeysetSQL

enum KeysetSQL {
    /// Render an anchor value as a SQL literal, matching the predicate
    /// builder's conventions (`Query.swift` formatValue: strings
    /// single-quote-escaped, dates as `timeIntervalSince1970` REALs).
    /// Returns nil for values with no literal form (NULL is structural).
    static func literal(_ value: KeysetAnchor.Value) -> String? {
        switch value {
        case .unsorted, .null:
            return nil
        case .int(let v):
            return String(v)
        case .double(let v):
            // A NaN bound to a REAL column is stored as NULL by SQLite, so a
            // read-back anchor can never be NaN; guard anyway (structural
            // NULL). SQLite prints/parses infinities as ±9e999.
            if v.isNaN { return nil }
            if v.isInfinite { return v > 0 ? "9e999" : "-9e999" }
            return "\(v)"
        case .string(let v):
            return "'\(v.replacingOccurrences(of: "'", with: "''"))'"
        case .blob(let v):
            return "X'\(v.map { String(format: "%02x", $0) }.joined())'"
        }
    }

    /// The NULL-aware resume predicate for a fill after `anchor` (§2.4 /
    /// design A3 §3.1). The effective ORDER BY is `(col userDir, id ASC)`;
    /// SQLite sorts NULLs first ASC and last DESC, so:
    ///
    ///     ASC,  anchor NULL:     (col IS NULL AND id > :k) OR col IS NOT NULL
    ///     ASC,  anchor non-NULL: (col > :v) OR (col = :v AND id > :k)
    ///     DESC, anchor non-NULL: (col < :v) OR (col = :v AND id > :k) OR col IS NULL
    ///     DESC, anchor NULL:     (col IS NULL AND id > :k)
    ///
    /// COLLATION: the sort column is always the LEFT operand of every
    /// comparison, so SQLite applies the column's declared collation (e.g.
    /// `globalId TEXT COLLATE NOCASE`) — the same collation a bare-column
    /// ORDER BY uses. Anchor comparisons and the walk order therefore agree
    /// for any column-declared collation by construction.
    static func resumePredicate(spec: KeysetSortSpec, anchor: KeysetAnchor) -> String {
        guard let column = spec.column else {
            return "id > \(anchor.id)"
        }
        guard let literal = literal(anchor.value) else {
            // NULL (or NaN-stored-as-NULL) boundary.
            if case .unsorted = anchor.value {
                return "id > \(anchor.id)"
            }
            return spec.ascending
                ? "((\(column) IS NULL AND id > \(anchor.id)) OR \(column) IS NOT NULL)"
                : "(\(column) IS NULL AND id > \(anchor.id))"
        }
        return spec.ascending
            ? "((\(column) > \(literal)) OR (\(column) = \(literal) AND id > \(anchor.id)))"
            : "((\(column) < \(literal)) OR (\(column) = \(literal) AND id > \(anchor.id)) OR \(column) IS NULL)"
    }

    /// Extract position from the actual collection SELECT before model reuse.
    /// This is independent of live getters and explicit materialized images:
    /// later edits/deletes must not move an already-selected batch boundary.
    /// Missing metadata is different from a stored NULL; never fabricate it.
    static func extractAnchor(from backend: any ObjectBackend, spec: KeysetSortSpec) -> KeysetAnchor? {
        guard case .int64(let id)? = backend._queryRowValue(named: "id"), id != 0,
              case .text(let globalID)? = backend._queryRowValue(named: "globalId"),
              !globalID.isEmpty else { return nil }
        guard let column = spec.column else {
            return KeysetAnchor(value: .unsorted, id: id)
        }
        if column == "id" {
            return KeysetAnchor(value: .int(id), id: id)
        }
        guard let stored = backend._queryRowValue(named: column) else { return nil }
        let value: KeysetAnchor.Value
        // Preserve SQLite storage classes, including an INTEGER stored in a
        // REAL-affinity column. Coercing via a model getter can change order.
        switch stored {
        case .null:
            value = .null
        case .int64(let number):
            value = .int(number)
        case .real(let number):
            guard !number.isNaN else { return nil }
            value = .double(number)
        case .text(let text):
            value = .string(text)
        case .blob(let data):
            value = .blob(data)
        }
        return KeysetAnchor(value: value, id: id)
    }

    /// AND a resume predicate into a shape's WHERE clause (both sides
    /// parenthesized — `query_rows` splices the fragment raw after `WHERE`).
    static func conjoin(where whereSQL: String?, resume: String?) -> String? {
        switch (whereSQL, resume) {
        case (nil, nil): return nil
        case (let w?, nil): return w
        case (nil, let r?): return r
        case (let w?, let r?): return "(\(w)) AND (\(r))"
        }
    }
}

// MARK: - KeysetCursor (public iterator, replaces `Cursor`)

/// The iterator behind `for x in results` (item A §1.4): walks the query in
/// keyset batches — `WHERE (predicate) AND (resume) ORDER BY sort dir, id ASC
/// LIMIT batch` — visiting each key at most once in total order, O(n) for a
/// full walk (the old `Cursor` advanced a raw `OFFSET`, O(n²/100), and —
/// because OFFSET is positional — silently *skipped* rows when a concurrent
/// deleter shifted ranks under the cursor). A shrinking table ends the walk
/// early; iteration never traps. Rows inserted behind the resume anchor
/// mid-walk are missed, ahead are seen; no row is ever delivered twice.
///
/// Shapes with no sound keyset anchor (grouped/distinct/bbox/union — §2.4
/// carve-out) and conformers without a keyset walk batch by OFFSET through
/// `snapshot(limit:offset:)`, exactly as the old `Cursor` did.
///
/// Single-owner iterator (`IteratorProtocol`): not thread-safe, not Sendable.
public final class KeysetCursor<Element>: IteratorProtocol {
    /// Produces the next batch, or nil when the walk is exhausted. The
    /// closure owns all resume state (anchor / offset).
    private let _nextBatch: () -> [Element]?
    private var batch: [Element] = []
    private var indexInBatch = 0
    private var exhausted = false

    package init(nextBatch: @escaping () -> [Element]?) {
        self._nextBatch = nextBatch
    }

    /// OFFSET-batched fallback walk — the old `Cursor` mechanics, kept for
    /// shapes without a keyset total order. Captures the concrete results'
    /// snapshot rather than storing `any Results<Element>` (a parameterized
    /// existential — an iOS-16 runtime floor).
    package convenience init(_ results: some Results<Element>) {
        let batchSize: Int64 = 100
        var offset: Int64 = 0
        var finished = false
        self.init(nextBatch: {
            if finished { return nil }
            let rows = results.snapshot(limit: batchSize, offset: offset)
            offset += Int64(rows.count)
            if rows.count < Int(batchSize) { finished = true }
            return rows.isEmpty ? nil : rows
        })
    }

    public func next() -> Element? {
        if indexInBatch >= batch.count {
            guard !exhausted, let next = _nextBatch(), !next.isEmpty else {
                exhausted = true
                batch = []
                return nil
            }
            batch = next
            indexInBatch = 0
        }
        defer { indexInBatch += 1 }
        return batch[indexInBatch]
    }
}
