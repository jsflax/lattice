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
/// In a normal build the whole type collapses to inline no-ops the optimizer strips — zero footprint.
public enum LatticePerf {
    public enum Metric: Sendable { case materializations, registrations, deregistrations, snapshots, fetches }

#if ORBITAL_PERF

    /// Cumulative counters; read as a snapshot by the Orbital HUD / report and diffed over a window.
    /// The decisive chat-jank signal is `materializations` (+ `registrations == deregistrations`
    /// throwaway churn) per second during a streaming turn.
    public struct Counters: Sendable, Equatable {
        public var materializations = 0   // Model.init(dynamicObject:) — a DB row hydrated into a Swift instance
        public var registrations = 0      // ModelInstanceRegistry.register   (C++ add_object_observer + NSLock churn)
        public var deregistrations = 0    // ModelInstanceRegistry.deregister
        public var snapshots = 0          // TableResults.snapshot()          — one SQL SELECT + N materializations
        public var fetches = 0            // LatticeQuery.fetch()             — wrapper re-query on an observer fire
        public init() {}
    }

    private static let _lock = OSAllocatedUnfairLock(initialState: Counters())
    /// The query-category signposter for Instruments timelines (e.g. `LatticeQuery.fetch` events).
    public static let signposter = OSSignposter(subsystem: "io.orbital.perf", category: "query")

    @inline(__always) public static func bump(_ metric: Metric) {
        _lock.withLock { c in
            switch metric {
            case .materializations: c.materializations += 1
            case .registrations:    c.registrations += 1
            case .deregistrations:  c.deregistrations += 1
            case .snapshots:        c.snapshots += 1
            case .fetches:          c.fetches += 1
            }
        }
    }

    public static func counters() -> Counters { _lock.withLock { $0 } }
    public static func reset() { _lock.withLock { $0 = Counters() } }

    @inline(__always) static func emitFetchEvent() { signposter.emitEvent("LatticeQuery.fetch") }

#else  // normal build — no-op

    @inline(__always) public static func bump(_ metric: Metric) {}
    @inline(__always) static func emitFetchEvent() {}

#endif
}
