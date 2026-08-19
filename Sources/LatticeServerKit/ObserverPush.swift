import Foundation
import Vapor
import Lattice
#if canImport(Combine)
import Combine
#endif

// ============================================================================
// Observer push (1.7): live fan-out of committed changes to watch sockets.
//
// Mechanism: commit-notification → per-socket incremental catch-up
// ("nudge + pump"), NOT a writer-frame tee. One `FileWatchManager` actor per
// push-enabled mount, keyed by canonical channel-file path, opens ONE watcher
// `Lattice` per live file (via the mount's `storeConfiguration`, sync config
// stripped) and registers a payload-free AuditLog commit observer. Each watch
// socket owns a monotone Int64 AuditLog-pk cursor and a serial pump that
// re-runs the existing catch-up machinery — `eventsAfter(id:)` → page →
// `ServerSentEvent.auditLog` → awaited `ws.send` — advancing the cursor as it
// goes. Push IS incremental catch-up, triggered by a change notification
// instead of a client redial.
//
// Why not the tee: co-process / in-process non-relay writers (e.g. a
// projector actor's own `Lattice`) have no writer mount and no wire frame to
// tee — while ANY commit to the file fires the AuditLog observer. The core
// unifies all writer classes at that surface: same-process sibling instances
// deliver exactly-once/commit-ordered (`flush_changes` →
// `instance_registry::for_each_alive`), cross-process writers arrive
// best-effort via the sibling-file notifier (covered by the reconcile tick
// and the retained client redial).
//
// Cursor semantics give ordering by construction: no gaps (parked
// registration precedes the catch-up snapshot; activation installs the
// snapshot boundary), no dupes (`WHERE id > cursor ORDER BY id ASC`; the
// cursor only advances after a successful awaited send), in order (at most
// one pump task per subscription). Pushed frames are byte-shape identical to
// catch-up frames, which the client engine already applies unconditionally —
// zero client changes. No kick-signaling: push carries only real sync frames.
// ============================================================================

// MARK: - SyncObserverPush

/// Per-mount opt-in + tuning for committed-change push.
///
/// Passing this to `configureSyncRelay(observerPush:)` subscribes every
/// admitted socket to a per-file commit watcher; `nil` (the default) keeps
/// pre-1.7 behavior exactly — the parameter is purely additive, so rollback
/// is `observerPush: nil`.
public struct SyncObserverPush: Sendable {
    /// AuditLog entries per pushed frame. Catch-up uses 1000; push defaults
    /// lower because a worst-case entry is ~16KiB (the ToolEvent result
    /// cap), so 256 bounds a page at ~4MiB.
    public var pageSize: Int
    /// Safety-net pump for the documented best-effort cross-process wakeup:
    /// every interval, nudge all subscribers (a clean pump is one indexed
    /// SELECT returning zero rows). `nil` disables — unit tests disable it
    /// so they prove push (not the tick) delivered. Irrelevant when every
    /// writer is same-process (exactly-once delivery path).
    public var reconcileInterval: Duration?

    public init(pageSize: Int = 256, reconcileInterval: Duration? = .seconds(30)) {
        self.pageSize = pageSize
        self.reconcileInterval = reconcileInterval
    }
}

// MARK: - PushSubscription

/// Per-socket push state — the cursor/ordering unit.
///
/// `cursor`/`dirty`/`pumping`/`active` are confined to the owning
/// `FileWatchManager` actor (every mutation happens in an actor-isolated
/// method); the pump's detached task only touches them through actor hops.
/// `socket` and `revocation` are thread-safe by their own contracts and are
/// read directly between pages.
final class PushSubscription: @unchecked Sendable {
    let socket: WebSocket
    /// The SAME flag the `SocketManager` entry holds — the pump checks it
    /// before every page, so a kicked observer stops receiving pushed frames
    /// immediately, even if its transport lingers because the peer never
    /// answers the close frame (same authority as the apply path).
    let revocation: RevocationFlag
    /// Canonical channel-file path — the watch-group key.
    let key: String
    /// `nil` = parked (connect-time catch-up in flight). Installed once by
    /// `activate(_:cursor:)` with the catch-up boundary, then only advanced
    /// by the pump after a successful awaited send.
    var cursor: Int64?
    /// A nudge arrived while parked or while a pump pass was running.
    var dirty = false
    /// At most one pump task per subscription (serialization: per-socket
    /// frames are strictly ordered because only one pump advances the
    /// cursor).
    var pumping = false
    /// Cleared by `unsubscribe`; in-flight pump passes check it and stop.
    var active = true

    init(socket: WebSocket, revocation: RevocationFlag, key: String) {
        self.socket = socket
        self.revocation = revocation
        self.key = key
    }
}

// MARK: - FileWatchGroup

/// Per-file watch group: ONE watcher `Lattice` + ONE payload-free commit
/// observer, shared by every push subscriber whose channel resolves to the
/// same canonical file path. Actor-confined to `FileWatchManager`.
private final class FileWatchGroup {
    /// Opened via the mount's `storeConfiguration` (sync config stripped so
    /// the watcher never joins sync channels or mints spurious entries).
    /// Boxed because `Lattice` is non-Sendable and pump tasks read it
    /// off-actor; released off-actor at teardown (`~lattice_db` tears down
    /// sync threads — never inline that on the actor).
    let watcher: UnsafeSendableBox<Lattice>
    /// `watcher.observeCommits { nudge }` registration.
    var token: AnyCancellable?
    /// Optional reconcile tick (see `SyncObserverPush.reconcileInterval`).
    var reconcile: Task<Void, Never>?
    var subscribers: [PushSubscription] = []

    init(watcher: UnsafeSendableBox<Lattice>) {
        self.watcher = watcher
    }
}

// MARK: - FileWatchManager

/// One per push-enabled relay mount; owns the per-file watch groups.
///
/// Files shared across mounts — a writer mount and a watch mount over one
/// `rooms-<code>.sqlite` — resolve to one canonical path, but only
/// push-enabled mounts create a manager, so a legacy writer mount adds no
/// group here; its commits reach this mount's watcher through the core's
/// same-process instance registry.
actor FileWatchManager {
    /// Keyed by canonical channel-file path.
    private var groups: [String: FileWatchGroup] = [:]

    // Per-mount constants, captured once at mount configuration. The schema
    // array is non-Sendable ([any Model.Type]); it is only read, mirroring
    // the `nonisolated(unsafe)` capture in `configureSyncRelay`.
    private nonisolated(unsafe) let schema: [any Lattice.Model.Type]
    private let storeConfiguration: (@Sendable (URL) -> Lattice.Configuration)?
    private let options: SyncObserverPush
    private let log = Logger(label: "lattice.observer-push")

    init(schema: [any Lattice.Model.Type],
         storeConfiguration: (@Sendable (URL) -> Lattice.Configuration)?,
         options: SyncObserverPush) {
        self.schema = schema
        self.storeConfiguration = storeConfiguration
        self.options = options
    }

    /// Number of live watch groups — group-teardown observability (tests
    /// assert 0 after the last subscriber leaves, so a big fleet cannot
    /// accumulate watcher opens/fds).
    var groupCount: Int { groups.count }

    /// Registers a PARKED subscription (no cursor yet). MUST be called
    /// before the caller takes its catch-up snapshot: the commit observer is
    /// live from here on, so any commit after the snapshot lands as a
    /// `dirty` nudge on the parked subscription and activation's first pump
    /// picks it up — no commit can fall between snapshot and watch.
    ///
    /// Returns `nil` when the watcher cannot be opened (file deleted, fd
    /// exhaustion): logged once, subscribers stay catch-up-only (the client
    /// redial fallback remains correct), retried on the next subscriber join.
    func subscribe(fileURL: URL, socket: WebSocket, revocation: RevocationFlag) -> PushSubscription? {
        let key = Self.canonicalKey(for: fileURL)
        let group: FileWatchGroup
        if let existing = groups[key] {
            group = existing
        } else {
            guard let created = makeGroup(key: key, fileURL: fileURL) else { return nil }
            groups[key] = created
            group = created
        }
        let sub = PushSubscription(socket: socket, revocation: revocation, key: key)
        group.subscribers.append(sub)
        return sub
    }

    /// End of connect-time catch-up: install the boundary cursor (pk of the
    /// last catch-up entry the socket was sent; the checkpoint entry's pk
    /// when catch-up was empty; 0 on an empty log) and pump. The first pass
    /// reads strictly beyond the boundary, so pushed frames never interleave
    /// with — or duplicate — catch-up pages; it also drains any nudges that
    /// buffered while parked (a clean pass is one indexed SELECT).
    func activate(_ sub: PushSubscription, cursor: Int64) {
        guard sub.active else { return }
        sub.cursor = cursor
        sub.dirty = true
        maybePump(sub)
    }

    /// Idempotent: `onClose`, pump send-failure, and the abandoned-connection
    /// paths all funnel here. Last subscriber out tears the group down —
    /// observer token cancelled, reconcile tick cancelled, watcher `Lattice`
    /// released OFF the actor (same discipline as the relay's off-loop
    /// per-connection release).
    func unsubscribe(_ sub: PushSubscription) {
        sub.active = false
        guard let group = groups[sub.key] else { return }
        group.subscribers.removeAll { $0 === sub }
        if group.subscribers.isEmpty {
            groups[sub.key] = nil
            group.token?.cancel()
            group.token = nil
            group.reconcile?.cancel()
            group.reconcile = nil
            let box = group.watcher
            Task.detached { box.clear() }
        }
    }

    /// Commit notification (or reconcile tick) for one file: mark every
    /// subscriber dirty and spawn pumps for the activated ones. Parked
    /// subscriptions keep the dirty flag until activation. Nudges are
    /// coalesced by `dirty`: N commits during one pump pass cost exactly one
    /// extra pass — O(new entries), not O(commits).
    func nudge(key: String) {
        guard let group = groups[key] else { return }
        for sub in group.subscribers {
            sub.dirty = true
            maybePump(sub)
        }
    }

    // MARK: pump machinery

    private func maybePump(_ sub: PushSubscription) {
        guard sub.active, sub.cursor != nil, !sub.pumping,
              let group = groups[sub.key] else { return }
        sub.pumping = true
        let watcher = group.watcher
        let pageSize = options.pageSize
        // Detached: page queries + JSON encoding never run on this actor or
        // on any socket's event loop (the B3.2 lesson). One task per
        // subscription; every other subscription pumps independently, so a
        // slow socket lags only itself.
        Task.detached { [weak self] in
            await self?.pump(sub, watcher: watcher, pageSize: pageSize)
        }
    }

    /// The pump loop. Runs off-actor; per-page state transitions hop back in.
    /// Never holds any write transaction — it reads committed state on the
    /// watcher's read connection, and the nudge itself fired from the
    /// writer's post-commit WAL hook, so "don't hold the apply/write
    /// transaction while fanning" is satisfied by construction.
    private nonisolated func pump(_ sub: PushSubscription, watcher: UnsafeSendableBox<Lattice>, pageSize: Int) async {
        while true {
            guard var cursor = await beginPass(sub) else { return }
            while true {
                // Same authority as the apply path: revocation (and a dead
                // transport) stops the stream before the next page.
                if sub.revocation.isRevoked || sub.socket.isClosed {
                    await unsubscribe(sub)
                    await clearPumping(sub)
                    return
                }
                let page = watcher.value.eventsAfter(id: cursor).snapshot(limit: Int64(pageSize))
                guard !page.isEmpty, let last = page.last?.primaryKey else { break }
                guard let encoded = try? JSONEncoder().encode(ServerSentEvent.auditLog(page)) else {
                    log.error("observer-push: failed to encode page after id \(cursor); dropping subscriber")
                    await unsubscribe(sub)
                    await clearPumping(sub)
                    return
                }
                do {
                    // AWAIT the write promise — flow control. The pump
                    // self-throttles to THIS socket's drain rate instead of
                    // stuffing the unbounded outbound buffer; memory bound is
                    // one page in flight per socket.
                    try await sub.socket.send(raw: encoded, opcode: .binary)
                } catch {
                    await unsubscribe(sub)
                    await clearPumping(sub)
                    return
                }
                // Batch-level logging ONLY (never per row — per-entry logging
                // at fan-out multiplicity is the 11-20s apply-log incident
                // class, multiplied).
                log.debug("observer-push: sent \(page.count) entries (\(cursor + 1)...\(last))")
                cursor = last
                await advance(sub, to: last)
            }
            if await finishPass(sub) == false { return }
        }
    }

    /// Start of a pump pass: consume the dirty flag and read the cursor.
    /// `nil` = subscription gone or still parked; the pump exits (pumping
    /// released so a later nudge/activation can start a fresh one).
    private func beginPass(_ sub: PushSubscription) -> Int64? {
        guard sub.active, let cursor = sub.cursor else {
            sub.pumping = false
            return nil
        }
        sub.dirty = false
        return cursor
    }

    /// The cursor only advances after a successful awaited send — every
    /// frame is produced by `id > cursor ORDER BY id ASC`, so no dupes by
    /// construction.
    private func advance(_ sub: PushSubscription, to cursor: Int64) {
        sub.cursor = cursor
    }

    /// End of a pass. `true` = a nudge landed during the pass (dirty again):
    /// run another pass with `pumping` still claimed. `false` = drained;
    /// release the pump slot. Checked under the actor so a nudge that
    /// arrives between the pump's last empty query and this call is never
    /// lost (it either re-loops this pump or — after release — spawns a
    /// fresh one).
    private func finishPass(_ sub: PushSubscription) -> Bool {
        if sub.dirty && sub.active { return true }
        sub.pumping = false
        return false
    }

    private func clearPumping(_ sub: PushSubscription) {
        sub.pumping = false
    }

    // MARK: group construction

    private func makeGroup(key: String, fileURL: URL) -> FileWatchGroup? {
        // The mount's own storeConfiguration (the 1.6.3 per-mount factory) —
        // mandatory, or a watcher on a projector-migrated file would refuse
        // the open exactly like the pre-1.6.3 relay did — then strip sync
        // config the way `changeStream`'s query lattice does, so the watcher
        // never joins sync channels or mints spurious entries.
        var configuration = storeConfiguration?(fileURL) ?? .init(fileURL: fileURL)
        configuration.ipcTargets = nil
        configuration.wssEndpoint = nil
        configuration.authorizationToken = nil
        guard let watcher = try? Lattice(for: schema, configuration: configuration) else {
            log.error("observer-push: could not open watcher for \(key); subscribers stay catch-up-only")
            return nil
        }
        let group = FileWatchGroup(watcher: UnsafeSendableBox(watcher))
        // Payload-free commit signal. The callback runs on the core's
        // notification thread: flag-set + task-spawn ONLY (no SQL, no
        // encoding, no hydration) — the pump re-queries by cursor, which is
        // the correctness mechanism.
        group.token = watcher.observeCommits { [weak self] in
            guard let self else { return }
            Task { await self.nudge(key: key) }
        }
        if let interval = options.reconcileInterval {
            group.reconcile = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled else { return }
                    await self?.nudge(key: key)
                }
            }
        }
        return group
    }

    /// Canonical channel-file key: channels shared across mounts (writer +
    /// watch over one file) resolve to ONE group.
    static func canonicalKey(for fileURL: URL) -> String {
        fileURL.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
