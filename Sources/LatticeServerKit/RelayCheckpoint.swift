import Foundation
import Lattice
import NIOConcurrencyHelpers

// §1.7.2 interim — the relay-side WAL CHECKPOINT GOVERNOR, from the WalEpochForensics facts:
//
// LatticeCore's own change hook DISPLACES SQLite's default autocheckpoint (installing a custom
// `sqlite3_wal_hook` unregisters the built-in one — core lattice.cpp:204), and the replacement only sets
// a keeper-eviction flag drained by read-pool maintenance a relay never runs. The sole unconditional
// checkpoint left is the destructor's PASSIVE pass — and server processes are SIGKILLed, not destructed.
// Net: every relay-held channel file's main freezes at boot state while its WAL grows without bound
// (measured: 4KB mains under 16.7MB WALs on both production fleets). Committed frames in the -wal DO
// survive kill -9 (harness B1-B3) — the governor is not what makes commits durable; it un-starves
// checkpointing so recovery windows, disk growth, external-reader visibility, and VACUUM-INTO backup
// honesty stay bounded.
//
// Cadence (design §interim): apply-coupled THRESHOLD with a time backstop — after a successful apply,
// checkpoint iff the -wal has crossed `walThresholdBytes` OR `maxIntervalSeconds` has passed for this
// canonical file key. Not per-apply (TRUNCATE thrashes under held readers; fsync storm), not timer-only
// (misses bursts, runs pointlessly idle).
//
// RETURN-VALUE LAW (harness D): `checkpointBounded` returning 0 is the BEST outcome — a fully successful
// TRUNCATE answers post-rewind, so 0 frames-remaining is success. Only -1 means could-not-run. A
// persistent -1 while the -wal is NOT shrinking under continuing applies is the WEDGE ALARM: the shared
// channel connection is sitting inside a begun-never-committed transaction (harness B4 — the epoch that
// evaporates on kill), or the -wal at the path is not the writer's inode (B5). Alarm loudly, never
// hot-retry: only an in-process commit can save a wedged epoch, and the alarm is what summons a human
// while the process is still alive to try.
final class RelayCheckpointGovernor: Sendable {
    static let shared = RelayCheckpointGovernor()

    /// Checkpoint when the -wal crosses this (default 4 MiB — deliberately far below the core's 16 MiB
    /// keeper-eviction threshold, which relay-shaped stores never drain).
    static let walThresholdBytes: Int64 = 4 * 1_048_576
    /// Time backstop per file key: even a slow trickle of applies checkpoints at least this often.
    static let maxIntervalSeconds: TimeInterval = 30
    /// Consecutive could-not-run results (with a non-shrinking WAL) before the wedge alarm fires.
    static let wedgeAlarmThreshold = 3

    private struct FileState {
        var lastCheckpoint = Date.distantPast
        var consecutiveFailures = 0
        var lastWalBytes: Int64 = 0
        var alarmed = false
    }
    private let state = NIOLockedValueBox<[String: FileState]>([:])

    /// Reset (tests).
    func _reset() { state.withLockedValue { $0 = [:] } }

    private static func walBytes(forStorePath path: String) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: path + "-wal")[.size] as? Int64)
            .flatMap { $0 } ?? 0
    }

    /// The apply-coupled hook: call after a successful apply, OUTSIDE the apply gate (the checkpoint
    /// takes its own bounded budget and must not extend the slot hold; TRUNCATE-busy falls back to
    /// PASSIVE inside `checkpointBounded`, worst-case ~bounded-budget ms).
    ///
    /// `storePath` is the channel file's filesystem path (the canonical apply key already is one).
    func afterApply(lattice: Lattice, storePath: String) {
        let now = Date()
        let wal = Self.walBytes(forStorePath: storePath)
        let due: Bool = state.withLockedValue { map in
            var s = map[storePath] ?? FileState()
            defer { map[storePath] = s }
            let crossed = wal >= Self.walThresholdBytes
            let stale = now.timeIntervalSince(s.lastCheckpoint) >= Self.maxIntervalSeconds
            return crossed || stale
        }
        guard due else { return }
        checkpoint(lattice: lattice, storePath: storePath, walBefore: wal)
    }

    /// One governed checkpoint pass with the wedge-alarm bookkeeping.
    func checkpoint(lattice: Lattice, storePath: String, walBefore: Int64? = nil) {
        let before = walBefore ?? Self.walBytes(forStorePath: storePath)
        let result = lattice.checkpointBounded(busyBudgetMs: 250)
        let after = Self.walBytes(forStorePath: storePath)
        state.withLockedValue { map in
            var s = map[storePath] ?? FileState()
            defer { map[storePath] = s }
            if result >= 0 {
                s.lastCheckpoint = Date()
                s.consecutiveFailures = 0
                s.lastWalBytes = after
                if s.alarmed {
                    s.alarmed = false
                    relayLog.notice("wal governor: \(storePath) recovered — checkpoint succeeded after wedge alarm (wal \(before)→\(after) bytes)")
                }
                return
            }
            // -1 = could-not-run. Only alarming when the WAL is ALSO not shrinking under load —
            // a held external reader legitimately defers TRUNCATE (PASSIVE still backfills).
            s.consecutiveFailures += 1
            let shrinking = after < max(s.lastWalBytes, before)
            s.lastWalBytes = after
            if s.consecutiveFailures >= Self.wedgeAlarmThreshold, !shrinking, !s.alarmed {
                s.alarmed = true
                relayLog.error("""
                    WAL WEDGE ALARM: \(storePath) — checkpoint could-not-run ×\(s.consecutiveFailures) \
                    with a non-shrinking WAL (\(after) bytes). The shared channel connection is likely \
                    inside a begun-never-committed transaction (its epoch is CACHE-ONLY and dies with \
                    the process — harness B4), or the on-path -wal is not the writer's inode (B5). \
                    Do NOT restart this process; the epoch is only saveable in-process.
                    """)
            }
        }
    }

    /// The SHUTDOWN/PRE-STOP DRAIN: checkpoint every registered store, best-effort, bounded. Wire to
    /// the host's graceful-shutdown hook (Vapor `Application.lifecycle` / signal grace window) and to
    /// any admin drain endpoint. Idempotent; safe on wedged files (returns -1, disturbs nothing).
    func drain(stores: [(lattice: Lattice, storePath: String)]) {
        for entry in stores {
            checkpoint(lattice: entry.lattice, storePath: entry.storePath)
        }
        relayLog.notice("wal governor: drain pass complete over \(stores.count) store(s)")
    }
}
