import Foundation
#if canImport(CoreFoundation) && canImport(os)
import CoreFoundation
#endif

// MARK: - ResultsTuning (item A §1.7)
//
// Per-Lattice live-results tuning knobs, carried on `Lattice.Configuration`.
// Back-deployable types only (`Int` milliseconds, `TimeInterval` seconds —
// NOT `Duration`, which is iOS 16+ and cannot be availability-gated in a
// stored property; the package floor is iOS 15 / macOS 14).
//
// Knobs active as of Commit 1 (shared shape cache + epochs + never-trap):
//   `pageSize`, `maxCachedPages`, `maxCachedShapes`.
// The remaining knobs are part of the item-A public surface but are consumed
// by later commits: `crossProcessBeltIntervalMs` (Commit 6, data_version
// belt), `generationTTLSeconds` / `keeperPoolSize` /
// `walKeeperEvictionThresholdBytes` (Commits 3/5, keeper generations + WAL
// retention policy).
public struct ResultsTuning: Sendable, Equatable, Hashable {
    public var pageSize: Int = 100
    /// LRU bound, per query shape.
    public var maxCachedPages: Int = 16
    /// Cross-process freshness belt floor interval; nil disables. (Commit 6.)
    public var crossProcessBeltIntervalMs: Int? = 500
    /// Idle generation self-retire. (Commits 3/5.)
    public var generationTTLSeconds: TimeInterval = 30
    /// Read-generation keeper pool size. (Commits 3/5.)
    public var keeperPoolSize: Int = 3
    /// Registry LRU bound (query shapes per lattice).
    public var maxCachedShapes: Int = 64
    /// WAL size at which ALL keepers are force-retired to open a reader gap
    /// so the log can rewind/truncate (§3.4). (Commits 3/5.)
    public var walKeeperEvictionThresholdBytes: Int = 16 << 20   // 16 MB

    public init() {}
}

// MARK: - GenerationCoordinator (item A §2.1/§2.2, Commit-1 slice)
//
// One coordinator per Lattice identity (`backend.identityHash`), held in a
// process-global registry, created lazily on the first live-Results access
// and torn down on `close()` / registry eviction.
//
// COMMIT-1 STAGING NOTE (per spec §7 "Commit 1 … logical epochs only, all
// storages"): a "generation" here is a *logical epoch* — a monotone counter —
// NOT yet a pinned read snapshot. Generation-scoped reads fall back to live
// reads through the existing neutral backend surface until the keeper pool
// and the generation-scoped bridge surface land (Commits 3–5). What this
// commit does provide:
//
//   * Same-handle read-your-writes, exact: `Lattice.add()` / `transaction()`
//     / `delete()` / managed-property setters bump the epoch synchronously on
//     the writer's thread, after the backend write returns (§1.3 Layer 1).
//   * Cross-handle / cross-process freshness, interim: the coordinator
//     subscribes to the existing `backend.addTableObserver` trampoline for
//     every table with a live shape. That trampoline is scheduler-dispatched
//     (`notify_changes_batched` routes through `scheduler_->invoke`), so its
//     delivery can land *after* the write call returns — it is explicitly
//     NOT read-your-writes and remains an interim freshness signal only,
//     replaced by the synchronous core invalidation hook in Commits 3–5
//     (§2.3: `lattice_db::add_invalidation_hook`, fanned per path via
//     `instance_registry::for_each_alive`).
//   * The render-batch generation pin (§1.3): epoch resolution is pinned per
//     main-thread runloop tick so one render batch serves one epoch;
//     same-thread write bumps clear the pin immediately (same-thread RYW
//     stays exact); other threads resolve per top-level access.
//
// LOCKING INVARIANT (§2.3, pinned by test T10): the coordinator lock and
// every `QueryShapeState` lock are LEAF locks — no thread may hold them
// across any SQL statement, backend call, or operation that can block on a
// connection mutex. Registry/shape lookups snapshot state under the lock,
// release it, run SQL, then re-validate the epoch before publishing.
final class GenerationCoordinator: @unchecked Sendable {
    let identityHash: Int64
    let path: String
    let tuning: ResultsTuning
    /// Weak: the coordinator must not keep a closed/released backend alive
    /// (the Lattice cache itself is weak for exactly this reason).
    private(set) weak var backend: (any LatticeBackend)?

    private struct State {
        /// Monotone logical-generation counter (§1.1). Starts at 1 so an
        /// "unvalidated" shape (validatedEpoch == 0) is always stale.
        var epoch: UInt64 = 1
        /// Last epoch at which each table saw a write (write-path bump or
        /// interim observer delivery). Shapes over untouched tables keep
        /// their caches across epoch bumps (§2.2 carry-over).
        var tableWriteEpochs: [String: UInt64] = [:]
        /// Last epoch of a write whose table set is unknown (explicit
        /// `transaction()` commits, `refresh()`): invalidates every shape.
        var allTablesWriteEpoch: UInt64 = 0
        /// Render-batch pin (§1.3): the epoch the current main-thread runloop
        /// tick is pinned to. Main-thread-only; cleared on `.beforeWaiting`
        /// and by same-thread (main) write bumps.
        var mainPin: UInt64?
        var mainPinObserverInstalled = false
        /// Live query shapes for this lattice, LRU-bounded by
        /// `tuning.maxCachedShapes`.
        var shapes: [QueryShapeKey: QueryShapeState] = [:]
        var shapeLRU: [QueryShapeKey] = []
        /// table → interim observer id (0 while registration is in flight).
        var observedTables: [String: UInt64] = [:]
    }

    private let lock: UnfairLock<State>
    #if canImport(CoreFoundation) && canImport(os)
    // Only touched from the main thread (install + invalidate on evict).
    private let runLoopObserverBox = UnfairLock<CFRunLoopObserver?>(initialState: nil)
    #endif

    init(identityHash: Int64, path: String, tuning: ResultsTuning, backend: any LatticeBackend) {
        self.identityHash = identityHash
        self.path = path
        self.tuning = tuning
        self.backend = backend
        self.lock = UnfairLock(initialState: State())
    }

    // MARK: Epoch resolution (render-batch pinned, §1.3)

    /// Resolve the epoch this top-level access serves, plus the staleness
    /// floor for `table` (the last write epoch affecting it, clamped to the
    /// pinned epoch so a mid-batch cross-thread bump takes effect at the next
    /// batch boundary, never mid-frame).
    func resolve(table: String) -> (epoch: UInt64, floor: UInt64) {
        var installObserver = false
        let result: (UInt64, UInt64) = lock.withLockUnchecked { state in
            var epoch = state.epoch
            if Thread.isMainThread {
                if let pinned = state.mainPin {
                    epoch = pinned
                } else {
                    state.mainPin = epoch
                    if !state.mainPinObserverInstalled {
                        state.mainPinObserverInstalled = true
                        installObserver = true
                    }
                }
            }
            let tableFloor = max(state.tableWriteEpochs[table] ?? 0, state.allTablesWriteEpoch)
            return (epoch, min(tableFloor, epoch))
        }
        if installObserver { installMainPinObserver() }
        return result
    }

    /// Current effective floor for `table` against the *live* epoch — used to
    /// re-validate before publishing a fill (§2.3 two-phase pattern).
    func currentFloor(table: String) -> UInt64 {
        lock.withLockUnchecked { state in
            max(state.tableWriteEpochs[table] ?? 0, state.allTablesWriteEpoch)
        }
    }

    /// The render-batch boundary: on the main thread the batch is the runloop
    /// tick — a `CFRunLoopObserver` on `.beforeWaiting` clears the pin (the
    /// same batch boundary the Commit-6 `data_version` belt will use). On
    /// platforms without CFRunLoop main-loop semantics (Linux CI) there is no
    /// frame concept: every access is its own batch (no pin is taken —
    /// `installMainPinObserver` clears it immediately below).
    private func installMainPinObserver() {
        #if canImport(CoreFoundation) && canImport(os)
        // We are on the main thread (only main-thread accesses pin).
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue,
            true, // repeats
            0
        ) { [weak self] _, _ in
            self?.clearMainPin()
        }
        if let observer {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            runLoopObserverBox.withLockUnchecked { $0 = observer }
        } else {
            // No observer — never hold a pin that nothing can clear.
            clearMainPin()
            lock.withLockUnchecked { $0.mainPinObserverInstalled = false }
        }
        #else
        clearMainPin()
        lock.withLockUnchecked { $0.mainPinObserverInstalled = false }
        #endif
    }

    private func clearMainPin() {
        lock.withLockUnchecked { state in
            state.mainPin = nil
        }
    }

    // MARK: Write-path epoch bumps (§1.3 Layer 1)

    /// Record a settled write. `tables == nil` means the touched table set is
    /// unknown (an explicit transaction commit) — every shape is invalidated.
    /// A bump performed by the main thread clears the render-batch pin
    /// immediately, keeping same-thread read-your-writes exact (§1.3).
    ///
    /// Callback-restriction note (§2.3): this is an O(1) counter update under
    /// a leaf lock — no SQL, no allocation-heavy work, nothing that can
    /// throw — so it is safe from every write path, including (in later
    /// commits) the synchronous core invalidation hook frame.
    func noteWrite(tables: [String]?) {
        lock.withLockUnchecked { state in
            state.epoch &+= 1
            let epoch = state.epoch
            if let tables {
                for table in tables {
                    state.tableWriteEpochs[table] = epoch
                }
            } else {
                state.allTablesWriteEpoch = epoch
            }
            if Thread.isMainThread {
                state.mainPin = nil
            }
        }
    }

    /// `Results.refresh()` (§1.7): force the next access to advance the
    /// generation and drop caches.
    func forceAdvance() {
        noteWrite(tables: nil)
    }

    // MARK: Shape registry (two-phase, §2.3)

    /// Look up (or create) the shared shape state for `key`, touching the
    /// per-lattice LRU and enforcing `maxCachedShapes`. The registry lock is
    /// never held across SQL; the caller runs its query lock-free and
    /// re-validates before publishing into the returned state.
    func shape(for key: QueryShapeKey) -> QueryShapeState {
        var needsObserver = false
        let state: QueryShapeState = lock.withLockUnchecked { state in
            if let existing = state.shapes[key] {
                // LRU touch.
                if let idx = state.shapeLRU.firstIndex(of: key) {
                    state.shapeLRU.remove(at: idx)
                }
                state.shapeLRU.append(key)
                return existing
            }
            let created = QueryShapeState(table: key.table)
            state.shapes[key] = created
            state.shapeLRU.append(key)
            // Registry LRU bound (§2.2): evict least-recently-used shapes
            // beyond `maxCachedShapes`. Facades re-register (cold) on their
            // next access.
            while state.shapeLRU.count > max(1, tuning.maxCachedShapes) {
                let evicted = state.shapeLRU.removeFirst()
                state.shapes.removeValue(forKey: evicted)
            }
            if state.observedTables[key.table] == nil {
                state.observedTables[key.table] = 0   // registration in flight
                needsObserver = true
            }
            return created
        }
        if needsObserver {
            registerInterimObserver(table: key.table)
        }
        return state
    }

    /// Number of live shapes (diagnostics / test pin for the LRU bound).
    var shapeCount: Int {
        lock.withLockUnchecked { $0.shapes.count }
    }

    /// INTERIM cross-handle freshness signal (Commit 1 only): ride the
    /// existing table-observer trampoline so writes arriving through *other*
    /// handles to the same store — a second app-side `Lattice`, sync-applied
    /// chunks, cross-process notifier wakeups — eventually bump the epoch.
    /// This delivery is scheduler-dispatched (it can land after the write
    /// call returns), so it is a freshness signal, NOT read-your-writes;
    /// Commit 3's synchronous core invalidation hook replaces it (§2.3).
    /// Same-handle Swift write paths bump synchronously via `noteWrite` and
    /// merely double-bump here, which is harmless (an extra cache drop).
    private func registerInterimObserver(table: String) {
        guard let backend else { return }
        let observerId = backend.addTableObserver(table: table) { [weak self] _ in
            self?.noteWrite(tables: [table])
        }
        lock.withLockUnchecked { state in
            state.observedTables[table] = observerId
        }
    }

    // MARK: Teardown

    /// Remove interim observers and drop all shape caches. Called from the
    /// registry on `Lattice.close()` / `Lattice.delete(for:)`.
    func tearDown() {
        let observers: [String: UInt64] = lock.withLockUnchecked { state in
            let observed = state.observedTables
            state.observedTables = [:]
            state.shapes = [:]
            state.shapeLRU = []
            state.mainPin = nil
            return observed
        }
        if let backend {
            for (table, observerId) in observers where observerId != 0 {
                backend.removeTableObserver(table: table, observerId: observerId)
            }
        }
        #if canImport(CoreFoundation) && canImport(os)
        let observer = runLoopObserverBox.withLockUnchecked { box -> CFRunLoopObserver? in
            let o = box
            box = nil
            return o
        }
        if let observer {
            CFRunLoopObserverInvalidate(observer)
        }
        #endif
    }

    deinit {
        // Backend already gone or being torn down; the CFRunLoop observer
        // holds only a weak self, but invalidate it so it stops firing.
        #if canImport(CoreFoundation) && canImport(os)
        if let observer = runLoopObserverBox.withLockUnchecked({ $0 }) {
            CFRunLoopObserverInvalidate(observer)
        }
        #endif
    }
}

// MARK: - Process-global coordinator registry (§2.2)

/// Process-global registry of coordinators, keyed by `backend.identityHash`,
/// with a secondary path index so write-path bumps reach every same-path
/// coordinator in this process — the Swift-side stand-in for the per-path
/// fan-out the Commit-3 core hook performs via
/// `instance_registry::for_each_alive` (§2.3).
enum GenerationCoordinatorRegistry {
    private struct State {
        var byIdentity: [Int64: GenerationCoordinator] = [:]
        var byPath: [String: Set<Int64>] = [:]
        /// attached store path → parent store paths whose handles union it
        /// (`Lattice.attach`). While linked, a write on the attached store
        /// invalidates the parents' shapes too (Commit-1 stand-in for §4.2's
        /// hook-driven member-table invalidation).
        var attachedToParents: [String: Set<String>] = [:]
    }
    private static let lock = UnfairLock<State>(initialState: State())

    /// Record that handles over `parent` now union rows from `attached`.
    static func linkAttachedPaths(parent: String, attached: String) {
        lock.withLockUnchecked { state in
            state.attachedToParents[attached, default: []].insert(parent)
        }
    }

    static func unlinkAttachedPaths(parent: String, attached: String) {
        lock.withLockUnchecked { state in
            state.attachedToParents[attached]?.remove(parent)
            if state.attachedToParents[attached]?.isEmpty == true {
                state.attachedToParents.removeValue(forKey: attached)
            }
        }
    }

    /// Coordinator for a live backend — created lazily on first live-Results
    /// access (§2.2 "mints").
    static func coordinator(for backend: any LatticeBackend, tuning: ResultsTuning) -> GenerationCoordinator {
        let identityHash = backend.identityHash
        let path = backend.path
        return lock.withLockUnchecked { state in
            if let existing = state.byIdentity[identityHash], existing.backend != nil {
                return existing
            }
            let created = GenerationCoordinator(identityHash: identityHash, path: path,
                                                tuning: tuning, backend: backend)
            state.byIdentity[identityHash] = created
            state.byPath[path, default: []].insert(identityHash)
            // Opportunistic prune of dead-backend entries for this path (a
            // reopened database mints a new identityHash).
            if let hashes = state.byPath[path] {
                for hash in hashes where hash != identityHash {
                    if let dead = state.byIdentity[hash], dead.backend == nil {
                        state.byIdentity.removeValue(forKey: hash)
                        state.byPath[path]?.remove(hash)
                    }
                }
            }
            return created
        }
    }

    /// Same-process write-path bump, fanned out per path (§1.3 Layer 1 for
    /// the writing handle; a synchronous freshness bonus for sibling handles
    /// on the same store — the Commit-3 hook makes this per-path fan-out a
    /// core guarantee). Near-zero cost when no coordinator exists (no
    /// live-Results usage on the store).
    static func noteWrite(path: String, tables: [String]?) {
        let coordinators: [GenerationCoordinator] = lock.withLockUnchecked { state in
            // The written store plus (transitively) every store whose handles
            // union it via attach — a union view over an attached store goes
            // stale when the attached store changes.
            var paths: [String] = [path]
            var visited: Set<String> = [path]
            var i = 0
            while i < paths.count {
                if let parents = state.attachedToParents[paths[i]] {
                    for parent in parents where !visited.contains(parent) {
                        visited.insert(parent)
                        paths.append(parent)
                    }
                }
                i += 1
            }
            var found: [GenerationCoordinator] = []
            for p in paths {
                guard let hashes = state.byPath[p] else { continue }
                found.append(contentsOf: hashes.compactMap { state.byIdentity[$0] })
            }
            return found
        }
        for coordinator in coordinators {
            coordinator.noteWrite(tables: tables)
        }
    }

    /// Tear down and remove the coordinator for a closing backend.
    static func evict(identityHash: Int64) {
        let coordinator: GenerationCoordinator? = lock.withLockUnchecked { state in
            guard let c = state.byIdentity.removeValue(forKey: identityHash) else { return nil }
            state.byPath[c.path]?.remove(identityHash)
            if state.byPath[c.path]?.isEmpty == true {
                state.byPath.removeValue(forKey: c.path)
            }
            return c
        }
        coordinator?.tearDown()
    }

    /// Tear down every coordinator over `path` (used by `Lattice.delete(for:)`,
    /// which closes every cached backend for the file before unlinking).
    static func evictAll(path: String) {
        let coordinators: [GenerationCoordinator] = lock.withLockUnchecked { state in
            guard let hashes = state.byPath.removeValue(forKey: path) else { return [] }
            return hashes.compactMap { state.byIdentity.removeValue(forKey: $0) }
        }
        for coordinator in coordinators {
            coordinator.tearDown()
        }
    }
}
