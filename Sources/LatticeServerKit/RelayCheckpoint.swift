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
/// `@unchecked`: every stored property is behind an NIOLockedValueBox; the registry's `Lattice`
/// values are the same process-lifetime relay handles the mounts themselves hold (non-Sendable by
/// declaration, touched here only under the box's lock — the RevocationFlag/UnsafeSendableBox idiom).
final class RelayCheckpointGovernor: @unchecked Sendable {
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
    /// §amber-2 (drill finding): the governor was commit-cadence-driven — a QUIET channel carries its
    /// WAL indefinitely (durability-safe post-preservation, but recovery windows and main staleness
    /// persist). The registry + wall-timer sweep closes it: every store the relay touches registers
    /// here, and a lazy timer checkpoints any registered store whose WAL is non-empty and whose last
    /// checkpoint is stale — commits or not. Registered handles are process-lifetime in production
    /// (relay mounts hold them forever); tests unregister.
    private let registry = NIOLockedValueBox<[String: Lattice]>([:])
    private let sweeper = NIOLockedValueBox<Task<Void, Never>?>(nil)

    /// Reset (tests).
    func _reset() {
        state.withLockedValue { $0 = [:] }
        registry.withLockedValue { $0 = [:] }
        sweeper.withLockedValue { $0?.cancel(); $0 = nil }
    }

    func register(lattice: Lattice, storePath: String) {
        registry.withLockedValue { $0[storePath] = lattice }
        sweeper.withLockedValue { task in
            guard task == nil else { return }
            task = Task.detached { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(Self.maxIntervalSeconds * 1_000_000_000))
                    self?.sweepQuietStores()
                }
            }
        }
    }

    func unregister(storePath: String) {
        registry.withLockedValue { $0[storePath] = nil }
    }

    /// The timer leg: checkpoint every registered store whose WAL is non-empty and stale — the
    /// commit-cadence hook never fires on an idle channel, and idleness is exactly when the drill
    /// found week-old WALs riding along.
    func sweepQuietStores() {
        let entries = registry.withLockedValue { Array($0) }
        let now = Date()
        for (path, lattice) in entries {
            let wal = Self.walBytes(forStorePath: path)
            guard wal > 0 else { continue }
            let stale: Bool = state.withLockedValue { map in
                now.timeIntervalSince((map[path] ?? FileState()).lastCheckpoint) >= Self.maxIntervalSeconds
            }
            if stale { checkpoint(lattice: lattice, storePath: path, walBefore: wal) }
        }
    }

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
        register(lattice: lattice, storePath: storePath)   // idempotent; arms the quiet-store sweeper
        let now = Date()
        let wal = Self.walBytes(forStorePath: storePath)
        let due: Bool = state.withLockedValue { map in
            let s = map[storePath] ?? FileState()
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
                DurableHeadLedger.shared.record(lattice: lattice, storePath: storePath)
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

    /// The SHUTDOWN/PRE-STOP DRAIN: checkpoint every store, best-effort, bounded. Wire to the host's
    /// graceful-shutdown hook (Vapor `Application.lifecycle` / signal grace window) and to any admin
    /// drain endpoint. Idempotent; safe on wedged files (returns -1, disturbs nothing).
    ///
    /// §amber-1 (drill finding): the drill's drain outcome was UNDIAGNOSABLE because its evidence
    /// logged below the fleet's LOG_LEVEL=warn floor. A shutdown drain runs ONCE per process — its
    /// per-file outcome lines log at .warning deliberately (the warn-floor doctrine targets hot-path
    /// per-entry logging, which this is not), so post-drill forensics can discriminate didn't-run /
    /// ran-and-deferred / integrated from the standard log level.
    func drain(stores: [(lattice: Lattice, storePath: String)]? = nil) {
        let entries: [(lattice: Lattice, storePath: String)] = stores
            ?? registry.withLockedValue { $0.map { (lattice: $0.value, storePath: $0.key) } }
        for entry in entries {
            let before = Self.walBytes(forStorePath: entry.storePath)
            checkpoint(lattice: entry.lattice, storePath: entry.storePath, walBefore: before)
            let after = Self.walBytes(forStorePath: entry.storePath)
            relayLog.warning("wal governor drain: \(entry.storePath) wal \(before)→\(after) bytes")
        }
        relayLog.warning("wal governor: shutdown drain complete over \(entries.count) store(s)")
    }
}

// §1.7.2 — the DURABLE-HEAD LEDGER: a sidecar record of each channel file's last-known durable audit
// head (max AuditLog pk + its globalId). Written on every successful governed checkpoint and at boot;
// compared at boot: a HEAD REGRESSION (boot head < ledgered head) means the process lost history it
// once served durably — the channel is marked FLOOR-SUSPECT, which is what attributes a later client
// floor violation to "server lost history" rather than "client floor foreign/corrupt". The sidecar is
// tiny JSON at `<db>-ledger`; losing IT costs only attribution quality, never data.
final class DurableHeadLedger: Sendable {
    static let shared = DurableHeadLedger()

    struct Entry: Codable, Sendable {
        var headPk: Int64
        var headGlobalId: UUID?
        var recordedAt: Date
    }

    private struct PathState {
        var bootChecked = false
        var floorSuspect = false
    }
    private let state = NIOLockedValueBox<[String: PathState]>([:])

    func _reset() { state.withLockedValue { $0 = [:] } }

    private static func ledgerPath(_ storePath: String) -> String { storePath + "-ledger" }

    static func readEntry(storePath: String) -> Entry? {
        guard let data = FileManager.default.contents(atPath: ledgerPath(storePath)) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    private static func writeEntry(_ entry: Entry, storePath: String) {
        if let data = try? JSONEncoder().encode(entry) {
            try? data.write(to: URL(fileURLWithPath: ledgerPath(storePath)), options: .atomic)
        }
    }

    private static func durableHead(of lattice: Lattice) -> (pk: Int64, globalId: UUID?) {
        let last = lattice.objects(AuditLog.self).sortedBy(\.primaryKey, order: .reverse).snapshot(limit: 1).first
        return (last?.primaryKey ?? 0, last?.globalId)
    }

    /// Boot check (idempotent per path per process): compare the file's current durable head against
    /// the ledgered one, mark floor-suspect on regression, and re-record the current truth either way.
    /// Call on the relay's first touch of a channel store (and from the governor after checkpoints).
    @discardableResult
    func bootCheck(lattice: Lattice, storePath: String) -> Bool {
        let alreadyChecked: Bool = state.withLockedValue { $0[storePath]?.bootChecked ?? false }
        if alreadyChecked { return isFloorSuspect(storePath: storePath) }
        let head = Self.durableHead(of: lattice)
        var suspect = false
        if let prior = Self.readEntry(storePath: storePath), head.pk < prior.headPk {
            suspect = true
            relayLog.error("""
                DURABLE-HEAD REGRESSION: \(storePath) — boot head pk=\(head.pk) is BEHIND the ledgered \
                head pk=\(prior.headPk) (recorded \(prior.recordedAt)). This process lost history it \
                once served durably (the WAL-epoch class); the channel is FLOOR-SUSPECT and client \
                floor violations will be attributed to server-side loss.
                """)
        }
        Self.writeEntry(Entry(headPk: head.pk, headGlobalId: head.globalId, recordedAt: Date()),
                        storePath: storePath)
        state.withLockedValue { $0[storePath] = PathState(bootChecked: true, floorSuspect: suspect) }
        return suspect
    }

    /// Record the current durable head (governor calls this after each successful checkpoint —
    /// checkpointed frames are as durable as data gets short of fsync-of-main, which the checkpoint did).
    func record(lattice: Lattice, storePath: String) {
        let head = Self.durableHead(of: lattice)
        Self.writeEntry(Entry(headPk: head.pk, headGlobalId: head.globalId, recordedAt: Date()),
                        storePath: storePath)
    }

    func isFloorSuspect(storePath: String) -> Bool {
        state.withLockedValue { $0[storePath]?.floorSuspect ?? false }
    }
}
