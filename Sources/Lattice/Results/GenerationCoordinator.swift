import Foundation
#if canImport(CoreFoundation) && canImport(os)
import CoreFoundation
#endif
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

// MARK: - ResultsTuning (item A §1.7)
//
// Per-Lattice live-results tuning knobs, carried on `Lattice.Configuration`.
// Back-deployable types only (`Int` milliseconds, `TimeInterval` seconds —
// NOT `Duration`, which is iOS 16+ and cannot be availability-gated in a
// stored property; the package floor is iOS 15 / macOS 14).
//
// Knobs active as of Commit 6: `pageSize`, `maxCachedPages`,
// `maxCachedShapes` (Commit 1); `generationTTLSeconds` and
// `walKeeperEvictionThresholdBytes` (forwarded to the core read-pool
// tunables at open — §3.2/§3.4); `keeperPoolSize` documents the core pool
// capacity (the core cap is currently fixed at its default 3 — the bridge
// exposes no per-instance setter); `crossProcessBeltIntervalMs` floors the
// Commit-6 `data_version` belt (nil disables it).
public struct ResultsTuning: Sendable, Equatable, Hashable {
    public var pageSize: Int = 100
    /// LRU bound, per query shape.
    public var maxCachedPages: Int = 16
    /// Cross-process freshness belt floor interval; nil disables. (Commit 6.)
    public var crossProcessBeltIntervalMs: Int? = 500
    /// Idle generation self-retire (§3.2). Forwarded to the core pool TTL at
    /// open; enforced by the coordinator's maintenance timer.
    public var generationTTLSeconds: TimeInterval = 30
    /// Read-generation keeper pool size (§2.5). Documents the core pool
    /// capacity; the core cap is its default (3) in 1.0.
    public var keeperPoolSize: Int = 3
    /// Registry LRU bound (query shapes per lattice).
    public var maxCachedShapes: Int = 64
    /// WAL size at which ALL keepers are force-retired to open a reader gap
    /// so the log can rewind/truncate (§3.4). The hard WAL bound. Forwarded
    /// to the core WAL-hook threshold at open.
    public var walKeeperEvictionThresholdBytes: Int = 16 << 20   // 16 MB

    public init() {}
}

// MARK: - Generation value types (item A §1.1)

/// One minted generation: the coordinator epoch it serves plus the core
/// keeper generation id. `id == 0` means "no keeper" — the memory family
/// (§4.1 materialized-id generations) or a file store that could not be
/// pinned (falls back to live reads for that epoch).
struct GenerationRef: Equatable {
    let epoch: UInt64
    let id: UInt64
}

/// What `resolve(table:)` hands a facade for one top-level access: the
/// batch-pinned epoch, the staleness floor for the access's table, and the
/// keeper generation id to route generation-scoped reads through (0 = no
/// keeper — memory-family materialized-id or live-read path).
struct GenerationContext {
    let epoch: UInt64
    let floor: UInt64
    let generationID: UInt64
}

// MARK: - GenerationCoordinator (item A §2.1/§2.2, Commit-5 slice)
//
// One coordinator per Lattice identity (`backend.identityHash`), held in a
// process-global registry, created lazily on the first live-Results access
// and torn down on `close()` / registry eviction.
//
// COMMIT-5 STATE: a generation is now a REAL pinned read snapshot on file
// (WAL) databases — a core keeper connection holding an open read
// transaction, acquired through the Commit-4 bridge surface — and a
// materialized-id vector per query shape on the memory family (§4.1; the
// vectors live in `QueryShapeState`, captured via `queryIDs`). Invalidation
// is the SYNCHRONOUS core hook (§2.3): registered per coordinator on its
// backend, fired INLINE on the writer's thread for every settled commit on
// the store — fanned per path across core instances, so cross-handle writes
// (a second app-side `Lattice`, sync-applied chunks, TSR-resolved handles)
// bump this coordinator's epoch before the write call returns. The interim
// scheduler-dispatched `addTableObserver` freshness signal from Commit 1 is
// REMOVED — the trampoline remains the UI-repaint signal only (§1.5).
//
//   * Same-handle read-your-writes stays exact via BOTH layers (§1.3):
//     Swift write paths bump directly after the backend returns (Layer 1),
//     and the core hook bumps inline during the write (Layer 2). The double
//     bump is harmless (mint happens per access, not per bump).
//   * The render-batch generation pin (§1.3) now pins the RESOLVED
//     GENERATION, not just the epoch: one main-thread runloop tick serves
//     one pinned `GenerationRef`, so a cross-thread commit mid-frame cannot
//     tear the frame (identity diffed and rows hydrated at one snapshot —
//     §8.6, pinned by T8). Same-thread write bumps clear the pin
//     immediately (same-thread RYW stays exact).
//   * Superseded/unpinned generations are RELEASED off the hook frame
//     (§2.2): the hook only moves ids into `pendingRetire` (state stores —
//     hook-frame legal); the actual core release (keeper COMMIT — SQL) runs
//     on the next resolve, the maintenance tick, or teardown.
//
// LOCKING INVARIANT (§2.3, pinned by test T10): the coordinator lock and
// every `QueryShapeState` lock are LEAF locks — no thread may hold them
// across any SQL statement, backend call, or operation that can block on a
// connection mutex. Registry/shape lookups snapshot state under the lock,
// release it, run SQL, then re-validate the epoch before publishing.
// Keeper acquisition/release and all generation-scoped reads run with NO
// coordinator lock held (two-phase).
final class GenerationCoordinator: @unchecked Sendable {
    let identityHash: Int64
    let path: String
    let tuning: ResultsTuning
    /// §4.1: memory-family stores (private `:memory:`, named shared-cache —
    /// SQLite URI forms) never hold keepers; their generations are
    /// materialized-id vectors. Mirrors the core's `path_is_memory`.
    let isMemoryFamily: Bool
    /// Weak: the coordinator must not keep a closed/released backend alive
    /// (the Lattice cache itself is weak for exactly this reason).
    private(set) weak var backend: (any LatticeBackend)?

    private struct State {
        /// Monotone logical-generation counter (§1.1). Starts at 1 so an
        /// "unvalidated" shape (validatedEpoch == 0) is always stale.
        var epoch: UInt64 = 1
        /// Last epoch at which each table saw a write (write-path bump or
        /// hook delivery). Shapes over untouched tables keep their caches
        /// across epoch bumps (§2.2 carry-over).
        var tableWriteEpochs: [String: UInt64] = [:]
        /// Last epoch of a write whose table set is unknown (explicit
        /// `transaction()` commits, `refresh()`, rollback re-capture §2.3):
        /// invalidates every shape.
        var allTablesWriteEpoch: UInt64 = 0
        /// The coordinator's current generation — minted lazily at the first
        /// top-level access batch whose facade observes a stale/absent
        /// current (§2.2 "mints": never inside the invalidation hook frame).
        var current: GenerationRef?
        /// Render-batch pin (§1.3): the generation the current main-thread
        /// runloop tick is pinned to. Main-thread-only; cleared on
        /// `.beforeWaiting` and by same-thread write bumps. While set, its
        /// keeper id is never released.
        var mainPin: GenerationRef?
        var mainPinObserverInstalled = false
        /// Keeper ids whose coordinator hold should be released — superseded
        /// generations, cleared pins, stale-read casualties. Drained OFF the
        /// hook frame (§2.2: the keeper COMMIT is SQL) by resolve /
        /// maintenance / teardown.
        var pendingRetire: [UInt64] = []
        /// Synchronous invalidation hook registration (§2.3).
        var hookRegistered = false
        var hookToken: UInt64?
        /// Maintenance timer (§3.2) armed flag — armed only while
        /// generations are outstanding or work is pending.
        var maintenanceArmed = false
        /// §4.2/§2.5: attach exposes union tables as per-connection TEMP
        /// views on `db_`/`read_db_` ONLY — pool (keeper) connections do not
        /// carry them, so a keeper-routed read on an attach-parent handle
        /// would silently serve base-table rows. While this path is an
        /// attach parent, keepers are suppressed: attached/union shapes get
        /// logical-epoch caching with live reads (their §4.2 1.0 contract).
        var keepersSuppressed = false
        /// Live query shapes for this lattice, LRU-bounded by
        /// `tuning.maxCachedShapes`.
        var shapes: [QueryShapeKey: QueryShapeState] = [:]
        var shapeLRU: [QueryShapeKey] = []
        // MARK: data_version belt (§1.3 cross-process, Commit 6)
        /// Monotonic uptime (ns) of the last belt probe; 0 = never probed.
        var beltLastProbeUptimeNanos: UInt64 = 0
        /// Last `PRAGMA data_version` observed on `xproc_read_db_`. nil =
        /// no baseline yet (the first probe only records; the first access
        /// mints a fresh generation anyway, so nothing can be missed).
        var beltLastSeenDataVersion: Int64?
        /// A same-process write was observed (write-path bump or hook
        /// delivery) since the last probe. `data_version` changes when ANY
        /// other connection commits — including this process's own write
        /// connection as seen from `xproc_read_db_` — so a delta explained
        /// by a local write re-baselines instead of double-invalidating
        /// (the hook already bumped precisely, per table).
        var beltLocalWriteSinceProbe: Bool = false
        /// Diagnostics (tests): PRAGMA probes issued / foreign bumps seen.
        var beltProbeCount: UInt64 = 0
        var beltForeignBumpCount: UInt64 = 0
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
        self.isMemoryFamily = Self.pathIsMemory(path)
        self.lock = UnfairLock(initialState: State())
    }

    /// Swift mirror of the core's `configuration::path_is_memory`: URI forms
    /// are only URI-parsed by SQLite when they start with `file:`.
    static func pathIsMemory(_ path: String) -> Bool {
        if path.isEmpty || path == ":memory:" { return true }
        guard path.hasPrefix("file:") else { return false }
        if path.contains(":memory:") { return true }
        guard let query = path.range(of: "?") else { return false }
        return path[query.upperBound...].contains("mode=memory")
    }

    // MARK: Synchronous invalidation hook (§2.3)

    /// Register the core invalidation hook. Called by the registry AFTER its
    /// own lock is released (hook registration is a backend call — never
    /// made under a registry/coordinator lock). Idempotent.
    func activate() {
        let needsRegistration: Bool = lock.withLockUnchecked { state in
            guard !state.hookRegistered else { return false }
            state.hookRegistered = true
            return true
        }
        guard needsRegistration, let backend else { return }
        // The callback body runs INLINE in the writer's hook frame — for
        // file DBs inside SQLite's post-commit C frame (§2.3). It is
        // restricted to leaf-lock state stores: `noteWrite` is an O(1)
        // counter/flag update under the coordinator leaf lock — no SQL, no
        // keeper release (that is deferred via `pendingRetire`), nothing
        // that can throw.
        let token = backend.addInvalidationHook { [weak self] tables, reason in
            guard let self else { return }
            switch reason {
            case .commit:
                // Epoch bump is table-agnostic (every settled commit — §2.3,
                // keeper retirement depends on it); the changed-table payload
                // only refines which shapes drop caches. An EMPTY payload is
                // a bookkeeping-only commit: bump, keep every cache.
                self.noteWrite(tables: tables)
            case .rollback:
                // No change batch is delivered for a rollback by design —
                // any capture that raced the transaction may be poisoned
                // (§4.1 dirty-read belt), so every shape re-captures.
                self.noteWrite(tables: nil)
            case .advance:
                // §3.3/§3.4: content did not change — facades re-pin at the
                // next access (fresh keeper behind the truncated log);
                // epoch-keyed caches survive (floors untouched).
                self.noteWrite(tables: [])
            }
        }
        lock.withLockUnchecked { state in
            state.hookToken = token
        }
    }

    // MARK: Generation resolution (render-batch pinned, §1.3)

    /// Resolve the generation this top-level access serves: the batch-pinned
    /// epoch, the staleness floor for `table` (clamped to the pinned epoch so
    /// a mid-batch cross-thread bump takes effect at the next batch boundary,
    /// never mid-frame), and the keeper generation id (0 = no keeper).
    ///
    /// Two-phase (§2.3): pin/cache decisions under the leaf lock; keeper
    /// acquisition (BEGIN + pin statement — SQL) with NO lock held, published
    /// under epoch re-validation. A write landing during acquisition retries
    /// the mint (bounded) so a writer's own next access never serves a
    /// snapshot that predates its commit (read-your-writes, §1.3).
    func resolve(table: String) -> GenerationContext {
        // Cross-process freshness belt (§1.3, Commit 6): runs FIRST so a
        // detected foreign commit bumps the epoch before this access pins.
        beltCheckIfDue()
        var installObserver = false
        var attempts = 0
        defer {
            if installObserver { installMainPinObserver() }
            drainPendingRetires()
        }
        while true {
            enum Step {
                case serve(GenerationContext)
                case mint(epoch: UInt64)
            }
            let step: Step = lock.withLockUnchecked { state in
                if Thread.isMainThread, let pinned = state.mainPin {
                    return .serve(GenerationContext(epoch: pinned.epoch,
                                                    floor: Self.floorFor(state, table: table, epoch: pinned.epoch),
                                                    generationID: pinned.id))
                }
                let epoch = state.epoch
                if let current = state.current, current.epoch == epoch {
                    Self.pinIfMainThread(&state, current, installObserver: &installObserver)
                    return .serve(GenerationContext(epoch: epoch,
                                                    floor: Self.floorFor(state, table: table, epoch: epoch),
                                                    generationID: current.id))
                }
                if isMemoryFamily || state.keepersSuppressed {
                    // §4.1: no keepers on the memory family — the generation
                    // is the per-shape materialized-id vector (captured by
                    // the facade). §4.2: no keepers while this path is an
                    // attach parent (TEMP views live on `db_`/`read_db_`
                    // only). Publish a keeperless current so the batch pin
                    // has a stable ref.
                    let fresh = GenerationRef(epoch: epoch, id: 0)
                    Self.supersede(&state, with: fresh)
                    Self.pinIfMainThread(&state, fresh, installObserver: &installObserver)
                    return .serve(GenerationContext(epoch: epoch,
                                                    floor: Self.floorFor(state, table: table, epoch: epoch),
                                                    generationID: 0))
                }
                return .mint(epoch: epoch)
            }
            switch step {
            case .serve(let context):
                return context
            case .mint(let epochAtStart):
                attempts += 1
                // SQL (BEGIN + pin) — NO locks held.
                let acquired = backend?.acquireReadGeneration() ?? 0
                var redundant: UInt64 = 0
                let published: GenerationContext? = lock.withLockUnchecked { state in
                    if let current = state.current, current.epoch == state.epoch {
                        // Another thread minted for this epoch — serve theirs.
                        redundant = acquired
                        Self.pinIfMainThread(&state, current, installObserver: &installObserver)
                        return GenerationContext(epoch: current.epoch,
                                                 floor: Self.floorFor(state, table: table, epoch: current.epoch),
                                                 generationID: current.id)
                    }
                    guard state.epoch == epochAtStart else {
                        // A write landed while pinning: the snapshot may
                        // predate it — do not publish (RYW); retry fresh.
                        redundant = acquired
                        return nil
                    }
                    let fresh = GenerationRef(epoch: epochAtStart, id: acquired)
                    Self.supersede(&state, with: fresh)
                    Self.pinIfMainThread(&state, fresh, installObserver: &installObserver)
                    return GenerationContext(epoch: epochAtStart,
                                             floor: Self.floorFor(state, table: table, epoch: epochAtStart),
                                             generationID: acquired)
                }
                if redundant != 0 {
                    backend?.releaseReadGeneration(redundant)   // SQL — no locks held
                }
                if let published {
                    if published.generationID != 0 { armMaintenanceTimer() }
                    return published
                }
                if attempts >= 3 {
                    // Write storm: serve the freshest epoch keeperless this
                    // once (live-read fallback); the next batch re-pins.
                    return lock.withLockUnchecked { state in
                        GenerationContext(epoch: state.epoch,
                                          floor: Self.floorFor(state, table: table, epoch: state.epoch),
                                          generationID: 0)
                    }
                }
            }
        }
    }

    /// A generation-scoped read at `failedGeneration` came back stale
    /// (force-retired keeper, thrown core read — §3.4 protocol). Drop the
    /// dead generation (and any pin on it) and re-resolve, minting fresh.
    func resolveAfterStaleRead(failedGeneration: UInt64, table: String) -> GenerationContext {
        guard failedGeneration != 0 else { return resolve(table: table) }
        lock.withLockUnchecked { state in
            if state.current?.id == failedGeneration {
                state.current = nil
            }
            if state.mainPin?.id == failedGeneration {
                state.mainPin = nil
            }
            if !state.pendingRetire.contains(failedGeneration) {
                state.pendingRetire.append(failedGeneration)
            }
        }
        return resolve(table: table)
    }

    // MARK: data_version belt (§1.3 cross-process, Commit 6)
    //
    // Foreign (out-of-process) writers cannot fire this process's
    // synchronous invalidation hook — their commits are announced by the
    // best-effort notifier, which is documented droppable. The belt bounds
    // the staleness window after a dropped wakeup: at most once per belt
    // interval, a top-level access batch issues `PRAGMA data_version` on
    // the dedicated NON-TRANSACTION cross-process read connection
    // (`xproc_read_db_` — inside a keeper's held read txn the value is
    // frozen at the snapshot, so the belt must never run on a keeper). The
    // value changes exactly when another connection committed; a change not
    // explained by a locally-observed write is a FOREIGN commit with an
    // unknown table set — bump the epoch and re-capture every shape
    // (`noteWrite(tables: nil)`, the same advance path the hook's
    // unknown-table reasons take).
    //
    // Batch alignment: `resolve` calls this before pin/serve decisions, so
    // on the main thread the belt runs only at a render-batch START (a held
    // pin skips it — a mid-frame foreign bump must not tear the frame,
    // §1.3); on other threads every top-level access is its own batch,
    // floored by `crossProcessBeltIntervalMs`. Memory-family stores skip
    // the belt entirely (no cross-process writers; `xproc_read_db_` has no
    // meaning there). `nil` interval disables (§1.7).
    private func beltCheckIfDue() {
        guard !isMemoryFamily, let intervalMs = tuning.crossProcessBeltIntervalMs else { return }
        let intervalNanos = UInt64(max(0, intervalMs)) &* 1_000_000
        let now = DispatchTime.now().uptimeNanoseconds
        let shouldProbe: Bool = lock.withLockUnchecked { state in
            // Mid-batch on the main thread: the frame is pinned — the belt
            // re-checks at the next batch boundary.
            if Thread.isMainThread, state.mainPin != nil { return false }
            guard now &- state.beltLastProbeUptimeNanos >= intervalNanos
                    || state.beltLastProbeUptimeNanos == 0 else { return false }
            // Claim the probe slot under the lock (≤ 1 PRAGMA per interval
            // even under concurrent resolves).
            state.beltLastProbeUptimeNanos = now
            state.beltProbeCount &+= 1
            return true
        }
        guard shouldProbe, let backend else { return }
        // SQL — NO locks held (leaf-lock rule).
        let version = backend.dataVersion()
        guard version >= 0 else { return }   // -1 = probe failed: no information
        let foreignBump: Bool = lock.withLockUnchecked { state in
            defer { state.beltLastSeenDataVersion = version }
            let localWrite = state.beltLocalWriteSinceProbe
            state.beltLocalWriteSinceProbe = false
            guard let lastSeen = state.beltLastSeenDataVersion else { return false }  // baseline
            guard version != lastSeen else { return false }
            if localWrite { return false }   // delta explained by a local write (already bumped, per table)
            state.beltForeignBumpCount &+= 1
            return true
        }
        if foreignBump {
            // Foreign commit, table set unknown — every shape re-captures.
            noteWrite(tables: nil)
            // The bump above was the belt's own: it must not mask the NEXT
            // foreign delta as a local write.
            lock.withLockUnchecked { $0.beltLocalWriteSinceProbe = false }
        }
    }

    /// Diagnostics (tests): (PRAGMA probes issued, foreign bumps detected).
    var beltCounters: (probes: UInt64, foreignBumps: UInt64) {
        lock.withLockUnchecked { ($0.beltProbeCount, $0.beltForeignBumpCount) }
    }

    /// Current effective floor for `table` against the *live* epoch — used to
    /// re-validate before publishing a fill (§2.3 two-phase pattern).
    func currentFloor(table: String) -> UInt64 {
        lock.withLockUnchecked { state in
            max(state.tableWriteEpochs[table] ?? 0, state.allTablesWriteEpoch)
        }
    }

    private static func floorFor(_ state: State, table: String, epoch: UInt64) -> UInt64 {
        min(max(state.tableWriteEpochs[table] ?? 0, state.allTablesWriteEpoch), epoch)
    }

    private static func pinIfMainThread(_ state: inout State, _ generation: GenerationRef,
                                        installObserver: inout Bool) {
        guard Thread.isMainThread else { return }
        state.mainPin = generation
        if !state.mainPinObserverInstalled {
            state.mainPinObserverInstalled = true
            installObserver = true
        }
    }

    /// Replace `current`, queuing the superseded keeper for off-frame release
    /// unless the render-batch pin still references it (§2.2: the pool
    /// overlap that lets an in-flight render drain on N while N+1 serves).
    private static func supersede(_ state: inout State, with fresh: GenerationRef) {
        if let old = state.current, old.id != 0, old.id != fresh.id,
           state.mainPin?.id != old.id,
           !state.pendingRetire.contains(old.id) {
            state.pendingRetire.append(old.id)
        }
        state.current = fresh
    }

    /// The render-batch boundary: on the main thread the batch is the runloop
    /// tick — a `CFRunLoopObserver` on `.beforeWaiting` clears the pin (the
    /// same batch boundary the Commit-6 `data_version` belt keys off: a held
    /// pin skips the belt; the next batch re-checks). On
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
        let hasPending: Bool = lock.withLockUnchecked { state in
            Self.clearPinLocked(&state)
            return !state.pendingRetire.isEmpty
        }
        // The batch is over — release anything the pin was keeping alive,
        // off the main runloop (§2.2: keeper COMMITs run on reader/utility
        // threads; the frame boundary should cost no SQL).
        if hasPending {
            Self.maintenanceQueue.async { [weak self] in
                self?.drainPendingRetires()
            }
        }
    }

    /// Clear the render-batch pin. If the pinned generation was superseded
    /// while pinned (a cross-thread bump mid-batch), the pin was its last
    /// reference — queue its keeper for release. State stores only
    /// (hook-frame legal; `noteWrite` uses this on same-thread bumps).
    private static func clearPinLocked(_ state: inout State) {
        if let pinned = state.mainPin, pinned.id != 0, pinned.id != state.current?.id,
           !state.pendingRetire.contains(pinned.id) {
            state.pendingRetire.append(pinned.id)
        }
        state.mainPin = nil
    }

    // MARK: Write-path epoch bumps (§1.3 Layer 1 + §2.3 hook Layer 2)

    /// Record a settled write. `tables == nil` means the touched table set is
    /// unknown (an explicit transaction commit, a rollback re-capture) —
    /// every shape is invalidated. `tables == []` bumps the epoch without
    /// invalidating any shape (bookkeeping-only commits, advance requests).
    /// A bump performed by the main thread clears the render-batch pin
    /// immediately, keeping same-thread read-your-writes exact (§1.3).
    ///
    /// Callback-restriction note (§2.3): this is an O(1) counter update under
    /// a leaf lock — no SQL, no keeper release (deferred via
    /// `pendingRetire`), nothing that can throw — so it is safe from every
    /// write path INCLUDING the synchronous core invalidation hook frame
    /// (for file DBs, SQLite's post-commit C frame on the writer's thread).
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
            // Belt bookkeeping (Commit 6): this locally-observed write will
            // move `data_version` on `xproc_read_db_` too — the next probe
            // re-baselines instead of double-invalidating.
            state.beltLocalWriteSinceProbe = true
            if Thread.isMainThread {
                Self.clearPinLocked(&state)
            }
            // The superseded `current` is NOT retired here — no SQL in the
            // hook frame. The next resolve mints fresh and supersedes it
            // (§2.2: release scheduled off-frame).
        }
    }

    /// `Results.refresh()` (§1.7): force the next access to advance the
    /// generation and drop caches.
    func forceAdvance() {
        noteWrite(tables: nil)
    }

    /// §4.2: toggle keeper suppression (this path became / stopped being an
    /// attach parent). Suppressing queues the held keeper for release —
    /// facades re-resolve keeperless at the next access; the attach path's
    /// own `noteWrite(tables: nil)` forces the refill.
    func setKeepersSuppressed(_ suppressed: Bool) {
        lock.withLockUnchecked { state in
            guard state.keepersSuppressed != suppressed else { return }
            state.keepersSuppressed = suppressed
            guard suppressed else { return }
            if let current = state.current, current.id != 0,
               state.mainPin?.id != current.id,
               !state.pendingRetire.contains(current.id) {
                state.pendingRetire.append(current.id)
            }
            state.current = nil
        }
        drainPendingRetires()
    }

    // MARK: Keeper release (off the hook frame, §2.2)

    /// Release every keeper hold queued by supersession/pin-clears/stale
    /// reads. Runs SQL (keeper COMMIT at refcount 0) — called only from
    /// reader/utility contexts (resolve, runloop batch boundary, maintenance
    /// tick, teardown), NEVER from the invalidation hook frame.
    func drainPendingRetires() {
        guard let backend else { return }
        let ids: [UInt64] = lock.withLockUnchecked { state in
            guard !state.pendingRetire.isEmpty else { return [] }
            let ids = state.pendingRetire
            state.pendingRetire = []
            return ids
        }
        for id in ids {
            backend.releaseReadGeneration(id)
        }
    }

    // MARK: Maintenance timer (§3.2)

    /// The §3.2 enforcement actor for EVERY storage/config (non-sync
    /// lattices have no pacer thread — the timer is the actor of record; a
    /// sync pacer is only ever a second caller). Low-frequency, utility QoS,
    /// armed only while generations are outstanding or retires are pending.
    /// Each tick drains pending releases and drives the core maintenance
    /// entry (TTL retire with the in-flight-statement "active reads"
    /// definition, absolute age re-pin, pending WAL-threshold evictions).
    private static let maintenanceQueue = DispatchQueue(
        label: "lattice.results.generation-maintenance", qos: .utility)

    /// Tick cadence derived from the TTL knob: fast enough that a TTL
    /// expiry is observed within ~half a TTL, floored/capped so ms-granular
    /// test tunings compress time and production tunings stay low-frequency.
    var maintenanceTickInterval: TimeInterval {
        min(max(tuning.generationTTLSeconds / 2, 0.025), 5.0)
    }

    private func armMaintenanceTimer() {
        let arm: Bool = lock.withLockUnchecked { state in
            guard !state.maintenanceArmed else { return false }
            state.maintenanceArmed = true
            return true
        }
        guard arm else { return }
        Self.maintenanceQueue.asyncAfter(deadline: .now() + maintenanceTickInterval) { [weak self] in
            self?.maintenanceTick()
        }
    }

    private func maintenanceTick() {
        drainPendingRetires()
        guard let backend else {
            lock.withLockUnchecked { $0.maintenanceArmed = false }
            return
        }
        backend.runReadPoolMaintenance()
        // Re-arm while there is anything left to police: outstanding keepers
        // (TTL/age caps), queued releases, or an unserviced WAL-threshold
        // eviction. Otherwise disarm; the next mint re-arms.
        let outstanding = backend.localReadGenerationsOutstanding()
        let pending: Bool = lock.withLockUnchecked { state in
            if outstanding > 0 || !state.pendingRetire.isEmpty || backend.walEvictionPending() {
                return true
            }
            state.maintenanceArmed = false
            return false
        }
        if pending {
            Self.maintenanceQueue.asyncAfter(deadline: .now() + maintenanceTickInterval) { [weak self] in
                self?.maintenanceTick()
            }
        }
    }

    // MARK: Lifecycle (§3.6)

    /// Retire every open read generation now: force-COMMIT keeper
    /// transactions (§3.4 protocol, core-side), return pooled connections,
    /// drop the coordinator's current/pinned refs. Facades re-pin lazily at
    /// the next access; epoch-keyed caches survive if no invalidation
    /// arrived meanwhile. Called by `Lattice.retireAllGenerations()` and the
    /// platform lifecycle observers (backgrounding — 0xdead10cc contract).
    func retireAllGenerations() {
        lock.withLockUnchecked { state in
            // The core retire-all force-commits EVERY live generation on the
            // instance — our per-id holds become no-op releases, so the
            // queue can simply be dropped alongside current/pin.
            state.current = nil
            state.mainPin = nil
            state.pendingRetire = []
        }
        backend?.retireAllReadGenerations()
    }

    // MARK: Shape registry (two-phase, §2.3)

    /// Look up (or create) the shared shape state for `key`, touching the
    /// per-lattice LRU and enforcing `maxCachedShapes`. The registry lock is
    /// never held across SQL; the caller runs its query lock-free and
    /// re-validates before publishing into the returned state.
    func shape(for key: QueryShapeKey) -> QueryShapeState {
        lock.withLockUnchecked { state in
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
            return created
        }
    }

    /// Number of live shapes (diagnostics / test pin for the LRU bound).
    var shapeCount: Int {
        lock.withLockUnchecked { $0.shapes.count }
    }

    // MARK: Teardown

    /// Remove the invalidation hook, release every keeper hold, and drop all
    /// shape caches. Called from the registry on `Lattice.close()` /
    /// `Lattice.delete(for:)` — BEFORE the backend closes (§4.6 ordering;
    /// the core close additionally retires its whole pool).
    func tearDown() {
        let cleanup: (token: UInt64?, generations: [UInt64]) = lock.withLockUnchecked { state in
            let token = state.hookToken
            state.hookToken = nil
            state.hookRegistered = true   // never re-register on a dying coordinator
            var generations = state.pendingRetire
            state.pendingRetire = []
            if let current = state.current, current.id != 0, !generations.contains(current.id) {
                generations.append(current.id)
            }
            state.current = nil
            if let pinned = state.mainPin, pinned.id != 0, !generations.contains(pinned.id) {
                generations.append(pinned.id)
            }
            state.mainPin = nil
            state.shapes = [:]
            state.shapeLRU = []
            return (token, generations)
        }
        if let backend {
            if let token = cleanup.token {
                backend.removeInvalidationHook(token: token)
            }
            for id in cleanup.generations {
                backend.releaseReadGeneration(id)
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
/// with a secondary path index so Swift write-path bumps reach every
/// same-path coordinator in this process. (The synchronous core hook — §2.3 —
/// already fans per path across CORE instances; the Swift-side path index
/// additionally propagates attach-relationships, which the core hook does
/// not know about, and serves the Layer-1 write-path bumps.)
enum GenerationCoordinatorRegistry {
    private struct State {
        var byIdentity: [Int64: GenerationCoordinator] = [:]
        var byPath: [String: Set<Int64>] = [:]
        /// attached store path → parent store paths whose handles union it
        /// (`Lattice.attach`). While linked, a write on the attached store
        /// invalidates the parents' shapes too (§4.2: attached/union shapes
        /// get logical-epoch caching only).
        var attachedToParents: [String: Set<String>] = [:]
        /// §3.6 lifecycle observers installed once per process.
        var lifecycleObserversInstalled = false
    }
    private static let lock = UnfairLock<State>(initialState: State())

    /// Whether `path` is currently an attach PARENT (its handles expose
    /// union TEMP views) — keeper suppression predicate (§4.2/§2.5).
    private static func isAttachParent(_ state: State, path: String) -> Bool {
        state.attachedToParents.values.contains { $0.contains(path) }
    }

    /// Record that handles over `parent` now union rows from `attached`.
    /// Keepers over `parent` are suppressed while the link exists: attach
    /// TEMP views live on `db_`/`read_db_` only — a keeper-routed read
    /// would silently serve base-table rows (§4.2/§2.5).
    static func linkAttachedPaths(parent: String, attached: String) {
        let coordinators: [GenerationCoordinator] = lock.withLockUnchecked { state in
            state.attachedToParents[attached, default: []].insert(parent)
            guard let hashes = state.byPath[parent] else { return [] }
            return hashes.compactMap { state.byIdentity[$0] }
        }
        for coordinator in coordinators {
            coordinator.setKeepersSuppressed(true)
        }
    }

    static func unlinkAttachedPaths(parent: String, attached: String) {
        let coordinators: [GenerationCoordinator] = lock.withLockUnchecked { state in
            state.attachedToParents[attached]?.remove(parent)
            if state.attachedToParents[attached]?.isEmpty == true {
                state.attachedToParents.removeValue(forKey: attached)
            }
            // Re-enable keepers only when NO remaining attachment names this
            // path as parent.
            guard !Self.isAttachParent(state, path: parent),
                  let hashes = state.byPath[parent] else { return [] }
            return hashes.compactMap { state.byIdentity[$0] }
        }
        for coordinator in coordinators {
            coordinator.setKeepersSuppressed(false)
        }
    }

    /// Coordinator for a live backend — created lazily on first live-Results
    /// access (§2.2 "mints"). Hook registration and lifecycle-observer
    /// installation happen AFTER the registry lock is released (backend
    /// calls are never made under a registry lock — §2.3 leaf-lock rule).
    static func coordinator(for backend: any LatticeBackend, tuning: ResultsTuning) -> GenerationCoordinator {
        let identityHash = backend.identityHash
        let path = backend.path
        var installLifecycleObservers = false
        let coordinator: GenerationCoordinator = lock.withLockUnchecked { state in
            if let existing = state.byIdentity[identityHash], existing.backend != nil {
                return existing
            }
            let created = GenerationCoordinator(identityHash: identityHash, path: path,
                                                tuning: tuning, backend: backend)
            if Self.isAttachParent(state, path: path) {
                created.setKeepersSuppressed(true)   // no keeper held yet — state-only
            }
            state.byIdentity[identityHash] = created
            state.byPath[path, default: []].insert(identityHash)
            if !state.lifecycleObserversInstalled {
                state.lifecycleObserversInstalled = true
                installLifecycleObservers = true
            }
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
        coordinator.activate()
        if installLifecycleObservers {
            GenerationLifecycleObserver.installIfAvailable()
        }
        return coordinator
    }

    /// The existing coordinator for a backend identity, WITHOUT creating one
    /// (used by `Lattice.retireAllGenerations()` — retiring must not mint).
    static func existingCoordinator(identityHash: Int64) -> GenerationCoordinator? {
        lock.withLockUnchecked { state in
            state.byIdentity[identityHash]
        }
    }

    /// Same-process write-path bump, fanned out per path (§1.3 Layer 1 for
    /// the writing handle; the Commit-4 core hook is the per-path guarantee
    /// across core instances — this Swift fan-out additionally walks attach
    /// links). Near-zero cost when no coordinator exists (no live-Results
    /// usage on the store).
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

    /// §3.6: retire every open read generation across every coordinator in
    /// the process (backgrounding / protected-data-unavailable). Suspended
    /// processes must hold ZERO read transactions and zero WAL read-marks
    /// (0xdead10cc).
    static func retireAllGenerationsGlobally() {
        let coordinators: [GenerationCoordinator] = lock.withLockUnchecked { state in
            Array(state.byIdentity.values)
        }
        for coordinator in coordinators {
            coordinator.retireAllGenerations()
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

// MARK: - Process lifecycle observers (§3.6)

/// iOS suspension contract (0xdead10cc): a keeper holds WAL read-mark locks
/// on the `-shm` file for the life of its read transaction, and iOS
/// terminates suspended apps holding SQLite/file locks in shared (app-group)
/// containers. Where UIKit is available, the registry installs
/// NotificationCenter observers for `willResignActive` and
/// `protectedDataWillBecomeUnavailable` and retires every generation in the
/// process; re-pin is lazy on the next access after foregrounding (two cheap
/// statements; epoch-keyed caches survive if no invalidation arrived).
///
/// ScenePhase note: SwiftUI apps that never post the UIKit lifecycle
/// notifications in some host contexts (widgets, previews) — and app
/// extensions / non-UIKit hosts sharing an app-group container — must call
/// `Lattice.retireAllGenerations()` from their own lifecycle hook (e.g.
/// `.onChange(of: scenePhase) { if $0 == .background { … } }`). This is a
/// REQUIRED contract for app-group deployments (§3.6; MIGRATION line 8).
enum GenerationLifecycleObserver {
    static func installIfAvailable() {
        #if canImport(UIKit) && !os(watchOS)
        // Observing the notification NAMES is extension-safe (no
        // UIApplication.shared): in hosts where the notifications never
        // fire, the observer is inert and the manual contract applies.
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.willResignActiveNotification,
                           object: nil, queue: nil) { _ in
            GenerationCoordinatorRegistry.retireAllGenerationsGlobally()
        }
        center.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
                           object: nil, queue: nil) { _ in
            GenerationCoordinatorRegistry.retireAllGenerationsGlobally()
        }
        #endif
    }
}
