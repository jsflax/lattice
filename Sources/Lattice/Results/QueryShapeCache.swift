import Foundation

// MARK: - Query-shape registry (item A §2.1/§2.2, Commit-1 slice)
//
// A *query shape* is the identity of a live results query:
// `(lattice identityHash, table, whereSQL, orderBySQL, groupBy, distinctBy)`.
// All facades over the same shape — every `@LatticeQuery` re-fetch, every
// `@Relation` property access, every TSR `resolve(on:)` — share ONE
// `QueryShapeState`, so rebuilt facades land warm (§1.5, §1.4 TSR note).
//
// Spatial (bbox) constraints are folded into the `whereSQL` component of the
// key: the spec's key tuple has no bbox slot, and two shapes differing only
// in their bounding box must not collide.
struct QueryShapeKey: Hashable {
    let identityHash: Int64
    let table: String
    let whereSQL: String?
    let orderBySQL: String?
    let groupBy: String?
    let distinctBy: String?
    /// Digest of the ordered values bound to `whereSQL`'s `?` placeholders,
    /// or nil for an all-literal predicate.
    ///
    /// CORRECTNESS, NOT PERFORMANCE. Before parameterization the rendered SQL
    /// text WAS the query's full identity, because every constant was baked
    /// into it. With placeholders it no longer is: `.in(idsA)` and
    /// `.in(idsB)` render the SAME `id IN (SELECT value FROM json_each(?))`
    /// text, so without this component the two queries collide onto one
    /// `QueryShapeState` and the second facade serves the FIRST one's cached
    /// count, pages and id vector — wrong rows, silently. Pinned by
    /// `disjointInSets_doNotShareShapeState`.
    ///
    /// Threading it through the key also repairs, for free, every other
    /// consumer that keys on shape identity: the coordinator's shape LRU, the
    /// `shapeRelevantWriteEpochs` bookkeeping, and `ShapeColumnExtractor`'s
    /// per-shape dependency.
    var bindDigest: BindDigest? = nil
}

/// A 128-bit digest over an ordered parameter list.
///
/// Wide on purpose: this value stands in for the bound values inside a cache
/// key, so a collision is not a slow path — it is two different queries
/// sharing one cache entry, i.e. wrong rows. 128 bits makes that
/// unreachable in practice, at a fraction of the memory of retaining the
/// values themselves (a 28K-element membership query would otherwise pin
/// ~300 KB per live shape).
///
/// Deterministic FNV-1a with two independent parameterizations, so it does not
/// depend on Swift's per-process `Hasher` seed.
struct BindDigest: Hashable, Sendable {
    let lo: UInt64
    let hi: UInt64

    init?(_ params: [QueryParameter]) {
        guard !params.isEmpty else { return nil }
        var a: UInt64 = 0xcbf2_9ce4_8422_2325
        var b: UInt64 = 0x9e37_79b9_7f4a_7c15
        func mix(_ byte: UInt8) {
            a = (a ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            b = (b ^ UInt64(byte)) &* 0x8864_3f65_e0d1_4d0d
            b ^= b >> 29
        }
        func mix<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
            for byte in bytes { mix(byte) }
        }
        func mix(_ value: UInt64) {
            withUnsafeBytes(of: value.littleEndian) { mix($0) }
        }
        // The per-element TAG is load-bearing: without it the integer 0 and
        // an empty blob would digest identically. The LENGTH prefix likewise
        // stops ["ab","c"] from colliding with ["a","bc"].
        for param in params {
            switch param {
            case .null:
                mix(UInt8(0))
            case .integer(let i):
                mix(UInt8(1)); mix(UInt64(bitPattern: i))
            case .real(let d):
                mix(UInt8(2)); mix(d.bitPattern)
            case .text(let s):
                mix(UInt8(3)); mix(UInt64(s.utf8.count)); mix(s.utf8)
            case .blob(let data):
                mix(UInt8(4)); mix(UInt64(data.count)); mix(data)
            }
        }
        self.lo = a
        self.hi = b
    }
}

/// Shared, epoch-keyed cache state for one query shape: cached `count`, an
/// LRU page cache, `previousPages` (one superseded generation retained —
/// tolerant-ladder rung (b)), the lifeboat element (rung (c)), and — from
/// Commit 2 — the persistent keyset anchor map (§2.4).
///
/// LOCKING (§2.3, pinned by T10): the internal lock is a LEAF lock. Every
/// method is O(cached-state) with no SQL, no backend calls, and no other
/// locks taken while it is held. Fills run SQL with NO lock held and publish
/// through `publish*`, which re-validates the epoch first (two-phase
/// pattern).
final class QueryShapeState: @unchecked Sendable {
    let table: String
    /// Item A Commit 8 (§2.3 v1.1): the columns this shape's membership and
    /// order depend on (predicate ∪ sort ∪ group/distinct ∪ implicit id),
    /// extracted conservatively at registration — never in the hook frame.
    /// Immutable, so the invalidation hook may read it under the
    /// COORDINATOR's leaf lock without touching this shape's own lock.
    let columnDependency: ShapeColumnDependency

    private struct State {
        /// Epoch at which `count`/`pages` were last known valid. 0 = never.
        var validatedEpoch: UInt64 = 0
        var cachedCount: Int?
        /// §4.1 materialized-id generation (memory family): the id vector
        /// captured at `validatedEpoch`. `count == ids.count`; `subscript(i)`
        /// hydrates `ids[i]` by primary key. Rotated out with the pages when
        /// a write invalidates the shape; carried over (retagged) across
        /// epochs that did not touch this table (§2.2).
        var ids: ContiguousArray<Int64>?
        /// The last count any successful count/capture produced — survives
        /// revalidation. Tolerant-ladder standby for a memory-family capture
        /// that exhausted its LOCKED-retry budget (§4.1 mechanism 3:
        /// "previous vector, else empty + stale flag" — count flavor).
        var lastKnownCount: Int?
        /// pageIndex → hydrated elements (stored as AnyObject — every cached
        /// element is a Model class instance; readers downcast and treat a
        /// mismatch as a miss).
        var pages: [Int: [AnyObject]] = [:]
        /// Page LRU order (least recent first), bounded by maxCachedPages.
        var pageLRU: [Int] = []
        /// The superseded generation's pages, kept until the next successful
        /// supersession (§1.2 ladder rung (b)).
        var previousPages: [Int: [AnyObject]] = [:]
        /// Last element any fill returned for this shape (§1.2 rung (c)).
        var lifeboat: AnyObject?
        /// Persistent keyset anchors (§2.4): pageIndex → the `(sortValue,
        /// id)` of the LAST row of that filled page (~24 B each). Deliberately
        /// NOT touched by `revalidate` (anchors survive epoch bumps —
        /// content-anchored burst refill) nor by page-LRU eviction; they live
        /// as long as the shape does. A stale anchor is rank-approximate but
        /// content-exact: the resume predicate is position-free, so a refill
        /// starts at the same content position and never traps.
        var anchors: [Int: KeysetAnchor] = [:]
        /// Diagnostics (tests): how fills were resumed. `offset` counts fills
        /// that included an OFFSET clause (cold jumps / carve-out shapes);
        /// `keyset` counts fills resumed by anchor predicate (or page-0
        /// fills, which need neither). A gap fill (anchor + OFFSET remainder)
        /// bumps both.
        var offsetFillCount = 0
        var keysetFillCount = 0
    }

    private let lock: UnfairLock<State>

    init(table: String, columnDependency: ShapeColumnDependency = .mustInvalidate) {
        self.table = table
        self.columnDependency = columnDependency
        self.lock = UnfairLock(initialState: State())
    }

    /// Rotate stale cache state out if a write invalidated it: caches
    /// validated before `floor` move to `previousPages` (rung (b)) and the
    /// shape re-validates at `epoch`. Caches over untouched tables carry
    /// over across epoch bumps (§2.2) — that is the `validatedEpoch >= floor`
    /// branch, which merely retags.
    private static func revalidate(_ state: inout State, epoch: UInt64, floor: UInt64) {
        if state.validatedEpoch >= floor {
            state.validatedEpoch = max(state.validatedEpoch, epoch)
            return
        }
        if !state.pages.isEmpty {
            state.previousPages = state.pages
        }
        state.pages = [:]
        state.pageLRU = []
        state.cachedCount = nil
        state.ids = nil
        state.validatedEpoch = epoch
    }

    /// Cached count for the batch-pinned `(epoch, floor)`, or nil (caller
    /// runs `COUNT(*)` lock-free and publishes).
    func count(epoch: UInt64, floor: UInt64) -> Int? {
        lock.withLockUnchecked { state in
            Self.revalidate(&state, epoch: epoch, floor: floor)
            return state.cachedCount
        }
    }

    /// Publish a freshly counted value, unless a write landed while the
    /// statement ran (`currentFloor > epoch` — serve it, don't cache it).
    func publishCount(_ count: Int, epoch: UInt64, floor: UInt64, currentFloor: UInt64) {
        lock.withLockUnchecked { state in
            state.lastKnownCount = count
            guard currentFloor <= epoch else { return }
            Self.revalidate(&state, epoch: epoch, floor: floor)
            state.cachedCount = count
        }
    }

    // MARK: Materialized-id generations (§4.1, memory family — Commit 5)

    /// The id vector valid for the batch-pinned `(epoch, floor)`, or nil
    /// (caller captures via `queryIDs` — a gated capture transaction — and
    /// publishes).
    func ids(epoch: UInt64, floor: UInt64) -> ContiguousArray<Int64>? {
        lock.withLockUnchecked { state in
            Self.revalidate(&state, epoch: epoch, floor: floor)
            return state.ids
        }
    }

    /// Publish a captured id vector (and the count it implies), unless a
    /// write landed while the capture ran — serve it, don't cache it.
    func publishIDs(_ ids: ContiguousArray<Int64>, epoch: UInt64, floor: UInt64, currentFloor: UInt64) {
        lock.withLockUnchecked { state in
            state.lastKnownCount = ids.count
            guard currentFloor <= epoch else { return }
            Self.revalidate(&state, epoch: epoch, floor: floor)
            state.ids = ids
            state.cachedCount = ids.count
        }
    }

    /// Tolerant-ladder standby: the last successfully captured/counted count
    /// (survives revalidation). Served when a capture returns the stale
    /// sentinel; corrected at the next successful epoch.
    func lastKnownCountValue() -> Int? {
        lock.withLockUnchecked { $0.lastKnownCount }
    }

    /// Cached page for the batch-pinned `(epoch, floor)`.
    func page(_ pageIndex: Int, epoch: UInt64, floor: UInt64) -> [AnyObject]? {
        lock.withLockUnchecked { state in
            Self.revalidate(&state, epoch: epoch, floor: floor)
            guard let rows = state.pages[pageIndex] else { return nil }
            if let idx = state.pageLRU.firstIndex(of: pageIndex) {
                state.pageLRU.remove(at: idx)
            }
            state.pageLRU.append(pageIndex)
            return rows
        }
    }

    /// Publish a fill. Always records the lifeboat (rung (c) serves even
    /// from a fill we chose not to cache) and the end-of-page keyset anchor
    /// (anchors are content-positional and epoch-agnostic, §2.4 — a fill
    /// that raced a write still marks a real content position); caches the
    /// page only when no write landed during the statement (two-phase
    /// re-validation).
    func publishPage(_ pageIndex: Int, rows: [AnyObject], endAnchor: KeysetAnchor? = nil,
                     epoch: UInt64, floor: UInt64,
                     currentFloor: UInt64, maxCachedPages: Int) {
        lock.withLockUnchecked { state in
            if let last = rows.last {
                state.lifeboat = last
            }
            if let endAnchor {
                state.anchors[pageIndex] = endAnchor
            }
            guard currentFloor <= epoch else { return }
            Self.revalidate(&state, epoch: epoch, floor: floor)
            state.pages[pageIndex] = rows
            if let idx = state.pageLRU.firstIndex(of: pageIndex) {
                state.pageLRU.remove(at: idx)
            }
            state.pageLRU.append(pageIndex)
            while state.pageLRU.count > max(1, maxCachedPages) {
                let evicted = state.pageLRU.removeFirst()
                state.pages.removeValue(forKey: evicted)
            }
        }
    }

    /// Tolerant-ladder rung (b): the retained previous generation's page.
    func previousPage(_ pageIndex: Int) -> [AnyObject]? {
        lock.withLockUnchecked { state in
            state.previousPages[pageIndex]
        }
    }

    /// Tolerant-ladder rung (c): the last element any fill returned.
    func lifeboatElement() -> AnyObject? {
        lock.withLockUnchecked { state in
            state.lifeboat
        }
    }

    // MARK: Keyset anchors (§2.4, Commit 2)

    /// The nearest recorded anchor at or before `pageIndex` (anchors mark
    /// page *ends*: filling page p resumes from the anchor at p−1 when
    /// present, else from the nearest earlier boundary plus a small OFFSET
    /// remainder — still one statement, O(gap) not O(p·pageSize)).
    func nearestAnchor(atOrBefore pageIndex: Int) -> (page: Int, anchor: KeysetAnchor)? {
        guard pageIndex >= 0 else { return nil }
        return lock.withLockUnchecked { state in
            var best: Int? = nil
            for page in state.anchors.keys where page <= pageIndex {
                if best == nil || page > best! { best = page }
            }
            guard let best, let anchor = state.anchors[best] else { return nil }
            return (best, anchor)
        }
    }

    /// Record the end-of-page anchor for `pageIndex` (iterator walks record
    /// boundaries as they stream past; page fills record via `publishPage`).
    func recordAnchor(_ anchor: KeysetAnchor, endOfPage pageIndex: Int) {
        lock.withLockUnchecked { state in
            state.anchors[pageIndex] = anchor
        }
    }

    /// Diagnostics (tests): count one fill statement by resume mechanism.
    func noteFill(usedOffset: Bool, usedKeyset: Bool) {
        lock.withLockUnchecked { state in
            if usedOffset { state.offsetFillCount += 1 }
            if usedKeyset { state.keysetFillCount += 1 }
        }
    }

    /// Diagnostics (tests): (fills that paid an OFFSET, fills resumed by
    /// keyset — page-0 fills count as keyset; a gap fill counts as both).
    var fillCounts: (offset: Int, keyset: Int) {
        lock.withLockUnchecked { state in
            (state.offsetFillCount, state.keysetFillCount)
        }
    }

    /// Diagnostics (tests): number of recorded page anchors.
    var anchorCount: Int {
        lock.withLockUnchecked { $0.anchors.count }
    }
}
