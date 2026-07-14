import Foundation
#if ORBITAL_PERF
import os
#endif

/// Compile-time-gated performance counters for the Orbital perf build (`-DORBITAL_PERF`).
///
/// Lives in Lattice (not Orbital) because the hottest probes — per-row model materialization
/// (`Model.init(dynamicObject:)`) and `TableResults.snapshot()` — happen inside Lattice, where
/// Orbital code cannot reach. The subsystem string `io.orbital.perf` is shared verbatim with
/// Orbital's `OrbitalPerf` so `log show` unifies both packages; there is otherwise no cross-package
/// dependency. (The `-DORBITAL_PERF` define reaches this path dependency because `swift build
/// -Xswiftc -DORBITAL_PERF` applies to every target built from source.)
///
/// DEBUG builds (the `swift test` configuration) keep the counters live even without
/// `ORBITAL_PERF`, so tests can pin registration/materialization churn budgets (item A
/// Commit 7 — fling-scroll observer-registration churn, §1.6/A1 risk 3). In a release build
/// without `ORBITAL_PERF` the whole type collapses to inline no-ops the optimizer strips —
/// zero footprint.
public enum LatticePerf {
    public enum Metric: Sendable { case materializations, registrations, deregistrations, snapshots, fetches }

#if ORBITAL_PERF || DEBUG

    /// Cumulative counters; read as a snapshot by the Orbital HUD / report and diffed over a
    /// window. The decisive chat-jank signal is `materializations` (+ `registrations == deregistrations`
    /// throwaway churn) per second during a streaming turn.
    ///
    /// Process-global: parallel test suites bump these concurrently — tests assert on deltas
    /// with generous budgets (or pair them with scoped probes like
    /// `ModelInstanceRegistry._liveInstanceCount`), never on absolute values.
    public struct Counters: Sendable, Equatable {
        public var materializations = 0   // Model.init(dynamicObject:) — a DB row hydrated into a Swift instance
        public var registrations = 0      // ModelInstanceRegistry.register   (C++ add_object_observer + NSLock churn)
        public var deregistrations = 0    // ModelInstanceRegistry.deregister
        public var snapshots = 0          // TableResults.snapshot()          — one SQL SELECT + N materializations
        public var fetches = 0            // LatticeQuery.fetch()             — wrapper re-query on an observer fire
        public init() {}
    }

    // UnfairLock wraps the same os_unfair_lock primitive OSAllocatedUnfairLock is built on,
    // and back-deploys below its iOS-16 floor (NSLock on Linux).
    private static let _lock = UnfairLock<Counters>(initialState: Counters())

    @inline(__always) private static func _apply(_ metric: Metric, to c: inout Counters) {
        switch metric {
        case .materializations: c.materializations += 1
        case .registrations:    c.registrations += 1
        case .deregistrations:  c.deregistrations += 1
        case .snapshots:        c.snapshots += 1
        case .fetches:          c.fetches += 1
        }
    }

    @inline(__always) public static func bump(_ metric: Metric) {
        _lock.withLockUnchecked { c in
            _apply(metric, to: &c)
        }
        #if DEBUG && !ORBITAL_PERF
        _apply(metric, to: &_threadBox.counters)
        #endif
    }

    public static func counters() -> Counters { _lock.withLockUnchecked { $0 } }
    public static func reset() { _lock.withLockUnchecked { $0 = Counters() } }

    #if DEBUG && !ORBITAL_PERF
    // Thread-local twin of `counters()` for tests: counts only bumps made
    // from the calling thread — immune to parallel test suites in the same
    // process (mirrors `Lattice.threadSQLStatementCount`). DEBUG-only so
    // the ORBITAL_PERF profiling build keeps its single-lock hot path.
    private final class _ThreadCountersBox { var counters = Counters() }
    private static let _threadKey = "io.lattice.perf.thread-counters"
    private static var _threadBox: _ThreadCountersBox {
        let dictionary = Thread.current.threadDictionary
        if let box = dictionary[_threadKey] as? _ThreadCountersBox { return box }
        let box = _ThreadCountersBox()
        dictionary[_threadKey] = box
        return box
    }

    /// Counters for bumps made from the CALLING thread only. Use for exact
    /// churn budgets on synchronous paths (item A Commit 7 fling-scroll).
    public static func threadCounters() -> Counters { _threadBox.counters }
    #endif

#else  // release build without ORBITAL_PERF — no-op, zero footprint

    @inline(__always) public static func bump(_ metric: Metric) {}

#endif

#if ORBITAL_PERF

    /// The query-category signposter for Instruments timelines (e.g. `LatticeQuery.fetch` events).
    public static let signposter = OSSignposter(subsystem: "io.orbital.perf", category: "query")

    @inline(__always) static func emitFetchEvent() { signposter.emitEvent("LatticeQuery.fetch") }

#else

    @inline(__always) static func emitFetchEvent() {}

#endif
}
