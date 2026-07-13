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

    private struct State {
        /// Epoch at which `count`/`pages` were last known valid. 0 = never.
        var validatedEpoch: UInt64 = 0
        var cachedCount: Int?
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

    init(table: String) {
        self.table = table
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
        guard currentFloor <= epoch else { return }
        lock.withLockUnchecked { state in
            Self.revalidate(&state, epoch: epoch, floor: floor)
            state.cachedCount = count
        }
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
