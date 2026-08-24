import Foundation
import Vapor
import Lattice
import NIOConcurrencyHelpers

// ============================================================================
// Busy-safe relay apply (1.7.1).
//
// The JoyJet incident: a live-socket upload was invisible on the server for
// 40+ seconds and then vanished. The mechanism was NOT the print-only catch
// at the top of `processFrame` — nothing threw at all:
//
//   1. The relay opened every channel store with `.init(fileURL:)`, i.e. the
//      library default `busyTimeoutMs = 30_000`. LatticeCore's
//      `database::begin_transaction` uses the configured busy timeout as the
//      WALL-CLOCK BUDGET for acquiring `BEGIN IMMEDIATE` (db.cpp:758), so a
//      contended apply parked a full 30 s inside SQLite's busy handler.
//   2. `apply_remote_changes_impl` contains chunk failures on purpose: a
//      failed chunk is rolled back, retried ONCE (sync.cpp — "retrying once",
//      +50 ms), and on the second failure the DELIVERY STOPS and the function
//      RETURNS the ids that did commit — it does not throw. So one apply cost
//      ~60 s and came back with a partial (often empty) id list.
//   3. The relay acked `globalIds` only when non-empty and had no other
//      output path: no ack, no nack, no log line. The frame was gone, and
//      because nothing threw, the `print("Error:")` catch never even ran.
//
// The fix has four parts, all here or wired from `configureSyncRelay`:
//
//   A. BOUNDED BUSY BUDGET — channel stores open with `busyTimeoutMs = 2_000`
//      instead of 30 s (`SyncRelayApplyPolicy.configuration(fileURL:...)`).
//      A live socket must never park half a minute inside one BEGIN.
//   B. BOUNDED RETRY — `applyWithRetry` re-runs the apply on a shortfall or a
//      thrown error with a doubling backoff (20 ms → 320 ms, 5 attempts,
//      whole-frame retry budget). Re-applying a frame is cheap and safe: the
//      core's per-entry loop re-checks `AuditLog`/`_lattice_applied_receipts`
//      by globalId and acks already-applied entries without rewriting them.
//   C. EXPLICIT NACK — a terminal shortfall answers the client with
//      `ServerSentEvent.nack(ids:reason:)` naming the entries that did NOT
//      make it, so the client can release them from in-flight and resend
//      immediately instead of waiting out its ack timeout.
//   D. PER-FILE SERIALIZATION — every apply on a channel FILE queues on
//      `FileApplyGate`, keyed by the same canonical path key the observer-push
//      watch groups use (`FileWatchManager.canonicalKey(for:)`). Connections
//      on one channel share ONE cached `swift_lattice` and ONE serialized
//      SQLite connection, so concurrent applies previously collided inside
//      `begin_transaction`'s "cannot start a transaction within a transaction"
//      retry loop and burned each other's busy budget. Queuing is strictly
//      better: FIFO, no lock thrash, and a catch-up ack burst (which IS a
//      write — `mark_audit_entries_synced` runs BEGIN + UPDATEs, chunked at
//      100) can no longer starve a live upload.
// ============================================================================

/// Relay-wide log. Apply failures are reported here at `.warning` (retry) and
/// `.error` (terminal), never swallowed — the incident's defining symptom was
/// a frame disappearing with zero output.
let relayLog = Logger(label: "lattice.relay")

// MARK: - Apply policy

/// Tuning for the relay's apply path. Public so an operator can read the
/// values the relay actually runs with (they are deliberately NOT
/// per-mount knobs: a live socket must never park, whatever the mount).
public enum SyncRelayApplyPolicy: Sendable {
    /// BEGIN-acquisition budget for channel stores, in milliseconds.
    ///
    /// LatticeCore uses the configured busy timeout as the wall-clock budget
    /// for `BEGIN IMMEDIATE`, and `apply_remote_changes` retries a failed
    /// chunk once — so this value bounds one apply's worst-case park at
    /// ~2 × 2 s, not the library default's ~2 × 30 s.
    ///
    /// Do NOT read this as "the longest legitimate apply": it is how long the
    /// relay is willing to WAIT FOR THE WRITE LOCK, not how long it may hold
    /// it. A mount whose channel files are also written by a slow foreign
    /// process can raise it by returning an explicit `busyTimeoutMs` from
    /// `storeConfiguration` (see `configuration(fileURL:storeConfiguration:)`).
    public static let busyTimeoutMs = 2_000

    /// Total attempts (the first try plus up to four retries).
    public static let maxAttempts = 5

    /// First backoff step; each retry doubles up to `maxRetryDelayMs`.
    public static let baseRetryDelayMs = 20

    /// Backoff ceiling.
    public static let maxRetryDelayMs = 320

    /// Wall-clock budget checked BEFORE starting another attempt. It bounds
    /// how long a client waits for its answer: with the 2 s busy budget a
    /// genuinely locked file answers with a nack in ~4 s (one attempt) rather
    /// than parking for a minute and answering with nothing.
    public static let retryBudgetMs = 3_000

    /// Backoff before the attempt AFTER `attempt` (1-based): 20, 40, 80, 160,
    /// capped at `maxRetryDelayMs`.
    static func retryDelayMs(afterAttempt attempt: Int) -> Int {
        guard attempt >= 1 else { return baseRetryDelayMs }
        let doublings = min(attempt - 1, 16)
        return min(baseRetryDelayMs << doublings, maxRetryDelayMs)
    }

    /// The configuration the relay opens a channel store with.
    ///
    /// A mount's `storeConfiguration` still decides schema/migration (that is
    /// what it exists for), but the relay's busy budget is applied on top
    /// UNLESS the mount asked for a specific one: a configuration still
    /// carrying the library default (`Lattice.Configuration.defaultBusyTimeoutMs`)
    /// is treated as "didn't think about it" and gets the relay budget, while
    /// any explicit value is respected verbatim.
    ///
    /// Note on aliasing: LatticeCore's instance cache keys on
    /// (path, scheduler, wss url, schema, target version, ipc, sync tuning) —
    /// NOT on the busy timeout. Whichever open wins the race for a given file
    /// installs its busy timeout for every later aliased handle, so the relay
    /// applies the same budget in `FileWatchManager.openWatcher`.
    static func configuration(
        fileURL: URL?,
        storeConfiguration: (@Sendable (URL) -> Lattice.Configuration)?
    ) -> Lattice.Configuration {
        var configuration = fileURL.flatMap { storeConfiguration?($0) } ?? .init(fileURL: fileURL)
        if configuration.busyTimeoutMs == Lattice.Configuration.defaultBusyTimeoutMs {
            configuration.busyTimeoutMs = busyTimeoutMs
        }
        return configuration
    }
}

// MARK: - Error classification

/// What SQLite told us, recovered from the core's error text (the Swift
/// surface receives `LatticeError.syncReceiveFailed(String)`, and the string
/// is `sqlite3_errmsg`'s, e.g. "Failed to begin transaction: database is
/// locked"). Reported in every log line and in the nack reason so a drop is
/// attributable instead of anonymous.
enum RelayApplyErrorClass: String, Sendable {
    /// Another connection holds the write lock (`SQLITE_BUSY`).
    case busy = "SQLITE_BUSY"
    /// A table/shared-cache lock (`SQLITE_LOCKED`).
    case locked = "SQLITE_LOCKED"
    /// "cannot start a transaction within a transaction" — a sibling apply on
    /// the SAME serialized connection. Per-file serialization is what removes
    /// this one.
    case nestedTransaction = "SQLITE_ERROR(nested-transaction)"
    /// No error was raised at all: the core contained a chunk failure and
    /// returned a partial id list. THE incident's shape.
    case containedChunkFailure = "no-throw-shortfall"
    case other = "unclassified"

    /// Contention classes worth another attempt. `other` is retried too (the
    /// attempt budget bounds it), but it is reported differently.
    var isContention: Bool {
        switch self {
        case .busy, .locked, .nestedTransaction, .containedChunkFailure: return true
        case .other: return false
        }
    }

    static func classify(_ message: String?) -> RelayApplyErrorClass {
        guard let message else { return .containedChunkFailure }
        let text = message.lowercased()
        if text.contains("cannot start a transaction within a transaction") {
            return .nestedTransaction
        }
        if text.contains("database table is locked") || text.contains("database schema is locked")
            || text.contains("sqlite_locked") {
            return .locked
        }
        if text.contains("database is locked") || text.contains("sqlite_busy")
            || text.contains("busy") || text.contains("failed to begin transaction") {
            return .busy
        }
        return .other
    }
}

// MARK: - Frame inspection

/// One parse of an inbound frame, shared by the write-policy gate and the
/// apply path.
///
/// The relay already re-parsed every frame with Foundation on write-policy
/// mounts; this makes that parse unconditional and reuses it, because
/// answering "which entries did the client ask us to store?" is what turns a
/// silent shortfall into a nack. The cost is one Foundation parse next to the
/// nlohmann parse the apply performs anyway — deliberate, and the reason the
/// id list is extracted once here rather than per use.
struct RelayFrame {
    /// `nil` when the bytes are not readable JSON at all (the write policy
    /// treats that as a violation; it is also unapplyable).
    let json: Any?
    let byteCount: Int
    /// globalIds this frame asks the relay to store, in wire order. Empty for
    /// ack/replay frames — those apply no entries, so they can neither be
    /// acked nor nacked (they are still bookkeeping WRITES, which is why they
    /// go through the same retry and the same per-file gate).
    let requestedIds: [UUID]

    var root: [String: Any]? { json as? [String: Any] }
    /// The raw `auditLog` array when the frame is an upload.
    var rawEntries: [Any]? { root?["auditLog"] as? [Any] }
    /// True when the frame carries an `auditLog` key at all (even a malformed
    /// one) — i.e. it claims to be an upload.
    var claimsUpload: Bool { root?["auditLog"] != nil }

    init(_ data: Data) {
        byteCount = data.count
        json = try? JSONSerialization.jsonObject(with: data)
        guard let entries = (json as? [String: Any])?["auditLog"] as? [Any] else {
            requestedIds = []
            return
        }
        var ids: [UUID] = []
        ids.reserveCapacity(entries.count)
        for element in entries {
            guard let entry = element as? [String: Any],
                  let raw = entry["globalId"] as? String,
                  let id = UUID(uuidString: raw) else { continue }
            ids.append(id)
        }
        requestedIds = ids
    }

    /// The frame reduced to the entries that actually committed — the fan-out
    /// payload on a PARTIAL apply. A full apply fans the original bytes out
    /// verbatim (byte-for-byte pre-1.7.1 behavior); only the degraded path
    /// pays a re-encode. `nil` when nothing is left to fan out.
    func reencoded(keeping applied: Set<UUID>) -> Data? {
        guard var root, let entries = rawEntries else { return nil }
        let kept = entries.filter { element in
            guard let entry = element as? [String: Any],
                  let raw = entry["globalId"] as? String,
                  let id = UUID(uuidString: raw) else { return false }
            return applied.contains(id)
        }
        guard !kept.isEmpty else { return nil }
        root["auditLog"] = kept
        return try? JSONSerialization.data(withJSONObject: root)
    }
}

// MARK: - Apply outcome

/// What one (retried) apply achieved.
struct RelayApplyOutcome: Sendable {
    /// Entries the channel database now holds, wire order preserved. Acked.
    var applied: [UUID] = []
    /// Requested but still missing after the last attempt. Nacked.
    var unapplied: [UUID] = []
    var attempts: Int = 0
    /// Last error text from the core, if any attempt threw.
    var lastError: String?
    var errorClass: RelayApplyErrorClass = .containedChunkFailure
    var elapsedMs: Double = 0

    /// True when the frame was applied in full (or was a non-upload frame
    /// that completed without error) — the only state that fans out verbatim.
    var isComplete: Bool { unapplied.isEmpty && lastError == nil }

    /// Human-readable nack reason, carrying the SQLite classification.
    var nackReason: String {
        let detail = lastError.map { ": \($0)" } ?? " (apply returned a partial result without raising)"
        return "relay could not apply \(unapplied.count) entr\(unapplied.count == 1 ? "y" : "ies") "
            + "after \(attempts) attempt\(attempts == 1 ? "" : "s") "
            + "[\(errorClass.rawValue)]\(detail) — resend them"
    }
}

/// TEST-ONLY (internal — `@testable` reach only) fault injection for the apply
/// retry ladder, which is otherwise not reachable deterministically: real
/// contention needs a foreign process holding a write lock for seconds. When
/// non-nil it is called at the top of EVERY attempt with (channelId, attempt),
/// and a throw stands in for that attempt's apply failing. Nil in production:
/// one lock-protected read per attempt.
let _applyFaultForTesting = NIOLockedValueBox<(@Sendable (String, Int) throws -> Void)?>(nil)

/// Applies `data` to `lattice`, retrying a shortfall or a thrown failure with
/// a bounded doubling backoff.
///
/// Retrying the WHOLE frame is intentional and cheap: `apply_remote_changes`
/// opens each entry with a `SELECT 1 FROM AuditLog ... UNION ALL SELECT 1 FROM
/// _lattice_applied_receipts` probe and acks an already-applied entry without
/// touching the row, so a re-applied prefix costs one indexed lookup per entry
/// and mints nothing. Slicing the frame down to the missing ids would instead
/// require re-encoding entries the relay only half-understands.
///
/// Synchronous by design — it runs on the connection's detached apply consumer
/// (never an event loop), inside the per-file gate.
func applyWithRetry(
    lattice: Lattice,
    data: Data,
    frame: RelayFrame,
    channelId: String,
    userId: UUID
) -> RelayApplyOutcome {
    var outcome = RelayApplyOutcome()
    var appliedSet: Set<UUID> = []
    let started = DispatchTime.now()
    let requested = frame.requestedIds

    func elapsedMs() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- started.uptimeNanoseconds) / 1e6
    }

    while true {
        outcome.attempts += 1
        var thrown: String?
        do {
            if let fault = _applyFaultForTesting.withLockedValue({ $0 }) {
                try fault(channelId, outcome.attempts)
            }
            for id in try lattice.receive(data) where appliedSet.insert(id).inserted {
                outcome.applied.append(id)
            }
        } catch {
            thrown = String(describing: error)
        }

        let missing = requested.filter { !appliedSet.contains($0) }
        outcome.unapplied = missing
        outcome.lastError = thrown
        outcome.errorClass = RelayApplyErrorClass.classify(thrown)
        outcome.elapsedMs = elapsedMs()

        // Nothing missing and nothing raised: done. (An ack/replay frame has
        // no requested ids, so it exits here unless its bookkeeping write
        // threw — those are writes too, and they are worth retrying.)
        if missing.isEmpty && thrown == nil { return outcome }

        guard outcome.attempts < SyncRelayApplyPolicy.maxAttempts,
              outcome.elapsedMs < Double(SyncRelayApplyPolicy.retryBudgetMs) else {
            return outcome
        }

        let delayMs = SyncRelayApplyPolicy.retryDelayMs(afterAttempt: outcome.attempts)
        relayLog.warning("""
            relay apply retry: channel=\(channelId) user=\(userId) \
            attempt=\(outcome.attempts)/\(SyncRelayApplyPolicy.maxAttempts) \
            sqlite=\(outcome.errorClass.rawValue) frameBytes=\(frame.byteCount) \
            requested=\(requested.count) applied=\(outcome.applied.count) \
            missing=\(missing.count) elapsedMs=\(Int(outcome.elapsedMs)) \
            backoffMs=\(delayMs)\(thrown.map { " error=\($0)" } ?? "")
            """)
        // Deliberately a THREAD sleep, not `Task.sleep`: this runs inside the
        // per-file gate, holding the file's apply slot. Suspending would let a
        // queued frame for the same file jump in mid-backoff and re-contend
        // with whatever we are waiting out.
        Thread.sleep(forTimeInterval: Double(delayMs) / 1000.0)
    }
}

// MARK: - Per-file apply gate

/// Process-wide FIFO serialization of applies, keyed by canonical channel-file
/// path — the key `FileWatchManager` already uses for watch groups
/// (`FileWatchManager.canonicalKey(for:)` is the single definition; this gate
/// never invents its own path normalization).
///
/// Why a separate actor from `FileWatchManager`: that actor is the
/// observer-push registry, reached only by push-enabled mounts, and its job is
/// to stay instantly responsive for nudges, pumps and teardown. The apply gate
/// must serve EVERY mount (legacy relays have no watch group at all) and its
/// waiters are parked for the duration of a database write. Same key space,
/// separate queues.
///
/// The gate never blocks the actor: `acquire` either takes the slot or parks a
/// continuation, and the apply itself runs in the caller's task, off-actor.
actor FileApplyGate {
    static let shared = FileApplyGate()

    private var held: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// Waiters currently queued for a key (test observability).
    func queueDepth(forKey key: String) -> Int { waiters[key]?.count ?? 0 }

    /// Whether a key's slot is currently taken (test observability).
    func isHeld(_ key: String) -> Bool { held.contains(key) }

    fileprivate func acquire(_ key: String) async {
        if held.insert(key).inserted { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters[key, default: []].append(continuation)
        }
    }

    fileprivate func release(_ key: String) {
        guard var queued = waiters[key], !queued.isEmpty else {
            waiters[key] = nil
            held.remove(key)
            return
        }
        let next = queued.removeFirst()
        waiters[key] = queued.isEmpty ? nil : queued
        // Ownership passes straight to the next waiter: `held` stays set, so
        // no third party can slip between release and resume.
        next.resume()
    }
}

/// Runs `body` with exclusive access to `key`'s apply slot.
///
/// `body` is synchronous on purpose: the whole point is that ONE apply touches
/// a channel file at a time, and a suspension inside the critical section
/// would reopen the window this closes.
func withApplyLock<T>(_ key: String, _ body: () -> T) async -> T {
    await FileApplyGate.shared.acquire(key)
    let result = body()
    await FileApplyGate.shared.release(key)
    return result
}
