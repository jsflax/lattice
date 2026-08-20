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
// ("nudge + pump"), NOT a writer-frame tee. ONE `FileWatchManager` actor per
// PROCESS (`FileWatchManager.shared`, shared by every push-enabled mount),
// keyed by canonical channel-file path, opens ONE watcher `Lattice` per live
// file (via the subscribing mount's `storeConfiguration`, sync config
// stripped) and registers a payload-free AuditLog commit observer — two push
// mounts over one file share one watcher and one observer. Each watch
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

    /// TEST-ONLY knob (internal — reachable via `@testable` only): when
    /// true, the watch group registers NO commit observer, making the
    /// reconcile tick the only nudge source, so tests can prove the tick
    /// alone delivers within its interval. Production mounts always run the
    /// commit observer.
    var _suppressCommitObserverForTesting = false

    public init(pageSize: Int = 256, reconcileInterval: Duration? = .seconds(30)) {
        precondition(pageSize > 0,
                     "SyncObserverPush.pageSize must be at least 1 (got \(pageSize)) — "
                     + "each pushed frame pages the AuditLog by pageSize rows")
        self.pageSize = pageSize
        self.reconcileInterval = reconcileInterval
    }
}

// MARK: - MountPushContext

/// Per-mount push configuration handed to the process-wide
/// `FileWatchManager` at subscribe time (the manager itself is shared, so
/// mount-specific state cannot live on it). `@unchecked`: the schema array
/// is a non-Sendable `[any Model.Type]` that is only ever read — the same
/// claim `configureSyncRelay` makes with its `nonisolated(unsafe)` capture.
struct MountPushContext: @unchecked Sendable {
    let schema: [any Lattice.Model.Type]
    let storeConfiguration: (@Sendable (URL) -> Lattice.Configuration)?
    let options: SyncObserverPush
}

// MARK: - WatcherRef

/// A pump's own strong reference to the watcher `Lattice`, held for the
/// pump task's whole lifetime. Created ON the manager actor (where the
/// group's box is still guaranteed populated) and released when the pump
/// task ends — always in a detached-task context, never inline on the actor
/// or an event loop. This is what makes last-subscriber teardown safe: the
/// group's box can be cleared while a pump is mid-pass and the pump keeps a
/// valid instance, exiting cleanly on its next inactive/closed check instead
/// of trapping on a cleared box.
private final class WatcherRef: @unchecked Sendable {
    let lattice: Lattice
    init(_ lattice: Lattice) { self.lattice = lattice }
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
    /// AuditLog entries per pushed frame, from the subscribing MOUNT's
    /// options (the manager is process-wide, so per-mount tuning rides the
    /// subscription). Clamped positive at construction.
    let pageSize: Int
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

    init(socket: WebSocket, revocation: RevocationFlag, key: String, pageSize: Int) {
        self.socket = socket
        self.revocation = revocation
        self.key = key
        self.pageSize = max(1, pageSize)
    }
}

// MARK: - FileWatchGroup

/// Per-file watch group: ONE watcher `Lattice` + ONE payload-free commit
/// observer, shared by every push subscriber whose channel resolves to the
/// same canonical file path. Actor-confined to `FileWatchManager`.
private final class FileWatchGroup {
    /// Opened via the creating mount's `storeConfiguration` (sync config
    /// stripped so the watcher never joins sync channels or mints spurious
    /// entries). Boxed because `Lattice` is non-Sendable and the group's
    /// reference is released off-actor at teardown (`~lattice_db` tears
    /// down sync threads — never inline that on the actor). Pumps do NOT
    /// read this box off-actor: each takes its own strong `WatcherRef` on
    /// the actor in `maybePump`, so clearing the box never races a pump.
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

/// ONE per relay process (the design's invariant), owning every per-file
/// watch group: push-enabled mounts all share `FileWatchManager.shared`, so
/// two push mounts over the same channel file resolve to ONE watcher
/// `Lattice` and ONE commit observer. Per-mount configuration (schema,
/// `storeConfiguration`, options) travels with each subscribe call as a
/// `MountPushContext`; the group-level parts (watcher open, reconcile tick)
/// are taken from the FIRST subscriber's mount, per-socket parts (pageSize)
/// from each subscription's own mount.
///
/// Legacy (non-push) mounts never subscribe, so they add no group here;
/// their commits reach a shared file's watcher through the core's
/// same-process instance registry.
actor FileWatchManager {
    /// The process-wide instance every push-enabled mount shares.
    static let shared = FileWatchManager()

    /// Keyed by canonical channel-file path.
    private var groups: [String: FileWatchGroup] = [:]

    /// In-flight watcher opens, keyed the same way. Every subscriber that
    /// arrives for a key while its open is running awaits THIS task instead
    /// of starting a second open (dedupe), and the task itself installs the
    /// group before it completes — so `groups[key]` is authoritative the
    /// moment any waiter resumes.
    private var creating: [String: Task<Bool, Never>] = [:]

    /// Watcher opens STARTED for each live group's key — teardown clears the
    /// entry with the group, so this is bounded by live groups, never by
    /// channels ever seen. Dedupe observability (see `watcherOpenCount`).
    private var opensStarted: [String: Int] = [:]

    private let log = Logger(label: "lattice.observer-push")

    /// Whether a live watch group exists for the given channel file —
    /// key-scoped teardown observability (the manager is process-wide, so a
    /// global count would be cross-mount/cross-suite noise). Tests assert
    /// this goes false after the last subscriber leaves, so a big fleet
    /// cannot accumulate watcher opens/fds.
    func hasGroup(forFile fileURL: URL) -> Bool {
        groups[Self.canonicalKey(for: fileURL)] != nil
    }

    /// Live subscriber count on the given file's group (0 when no group).
    func subscriberCount(forFile fileURL: URL) -> Int {
        groups[Self.canonicalKey(for: fileURL)]?.subscribers.count ?? 0
    }

    /// Watcher opens started for this file since its current group began —
    /// cleared with the group, exactly like `hasGroup`. However many sockets
    /// race to be the first subscriber, a live group must report 1: the
    /// per-key in-flight task dedupes them onto ONE open.
    func watcherOpenCount(forFile fileURL: URL) -> Int {
        opensStarted[Self.canonicalKey(for: fileURL)] ?? 0
    }

    /// Registers a PARKED subscription (no cursor yet). MUST be called
    /// before the caller takes its catch-up snapshot: the commit observer is
    /// live from here on (it is registered before this returns), so any
    /// commit after the snapshot lands as a `dirty` nudge on the parked
    /// subscription and activation's first pump picks it up — no commit can
    /// fall between snapshot and watch.
    ///
    /// The first subscriber for a file pays for the watcher open. That open
    /// runs OFF this actor (see `resolveGroup`): it is a full SQLite open —
    /// schema ensure, epoch migrations, WAL recovery on a cold file — and
    /// this actor is PROCESS-WIDE, so running it inline stalled every other
    /// file's pumps, nudges and teardowns behind one channel's first
    /// subscriber. Concurrent subscribers for the same file await the SAME
    /// in-flight open, so a file never gets a second watcher.
    ///
    /// Returns `nil` when the watcher cannot be opened (file deleted, fd
    /// exhaustion): logged once, subscribers stay catch-up-only (the client
    /// redial fallback remains correct), retried on the next subscriber join.
    func subscribe(fileURL: URL, context: MountPushContext,
                   socket: WebSocket, revocation: RevocationFlag) async -> PushSubscription? {
        let key = Self.canonicalKey(for: fileURL)
        guard let group = await resolveGroup(key: key, fileURL: fileURL, context: context) else {
            return nil
        }
        let sub = PushSubscription(socket: socket, revocation: revocation, key: key,
                                   pageSize: context.options.pageSize)
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
    /// observer token cancelled, reconcile tick cancelled, the group's
    /// watcher reference released OFF the actor (same discipline as the
    /// relay's off-loop per-connection release). In-flight pumps are NOT
    /// waited on: each holds its own strong `WatcherRef` (taken in
    /// `maybePump`) and exits cleanly on its next inactive/closed/revoked
    /// check, so clearing the box here can never trap or dangle a pump —
    /// the underlying Lattice is destroyed only when the last holder
    /// (this detached clear or the final pump task) lets go, always in a
    /// detached-task context.
    func unsubscribe(_ sub: PushSubscription) {
        sub.active = false
        guard let group = groups[sub.key] else { return }
        group.subscribers.removeAll { $0 === sub }
        if group.subscribers.isEmpty {
            groups[sub.key] = nil
            opensStarted[sub.key] = nil
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
              let group = groups[sub.key],
              // NEVER force-unwrap on the pump path: a subscription that
              // loses the teardown race (box already cleared by a stale
              // group's release) exits cleanly instead of trapping. With
              // teardown ordered under this actor the guard can't actually
              // fire — it is the structural backstop.
              let lattice = group.watcher.valueIfPresent else { return }
        sub.pumping = true
        // The pump's OWN strong reference, taken on the actor while the
        // group is provably alive and held for the pump task's lifetime —
        // last-subscriber teardown can clear the group's box mid-pass
        // without invalidating this pump; it finishes its pass (or exits on
        // its next closed/revoked/inactive check) against a live instance,
        // and the Lattice is finally released off-actor when the last
        // holder (the teardown task or this pump task) drops it.
        let watcher = WatcherRef(lattice)
        let pageSize = sub.pageSize
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
    private nonisolated func pump(_ sub: PushSubscription, watcher: WatcherRef, pageSize: Int) async {
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
                let page = watcher.lattice.eventsAfter(id: cursor).snapshot(limit: Int64(pageSize))
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

    /// The live group for `key`, opening the watcher OFF this actor.
    ///
    /// The open used to run inline in an actor-isolated `makeGroup`, so one
    /// slow `Lattice(for:configuration:)` — schema ensure, epoch migration,
    /// WAL recovery on a cold file — blocked the PROCESS-WIDE manager:
    /// every other channel's pumps, nudges and teardowns queued behind one
    /// channel's first subscriber. Now the open runs on a detached task and
    /// this actor is SUSPENDED (not blocked) while it runs, so the rest of
    /// the process keeps pumping.
    ///
    /// Concurrent subscribers for one key dedupe onto that single in-flight
    /// task, so "one watcher `Lattice` + one commit observer per file"
    /// survives the added suspension point: the second subscriber cannot
    /// observe the empty `groups[key]` window and start a rival open.
    /// Failure is shared too — every waiter on a failed open returns nil
    /// rather than retrying in turn (the retry is the NEXT subscriber join).
    private func resolveGroup(key: String, fileURL: URL,
                              context: MountPushContext) async -> FileWatchGroup? {
        if let live = groups[key] { return live }
        let creation: Task<Bool, Never>
        if let inFlight = creating[key] {
            creation = inFlight
        } else {
            opensStarted[key, default: 0] += 1
            creation = Task.detached { [weak self] in
                let opened = Self.openWatcher(fileURL: fileURL, context: context)
                guard let self else {
                    // The manager is a process-wide singleton, so this is
                    // unreachable in production — but a watcher that has
                    // nowhere to live is released here rather than leaked,
                    // and off-actor as ~lattice_db requires.
                    opened?.clear()
                    return false
                }
                return await self.installGroup(key: key, watcher: opened, context: context)
            }
            creating[key] = creation
        }
        // Suspends this actor rather than blocking it. The task installs the
        // group (and clears `creating`) before it completes, so the lookup
        // below is authoritative for every waiter, whichever order they
        // resume in.
        _ = await creation.value
        return groups[key]
    }

    /// Hop back onto the actor with the opened watcher: register the
    /// payload-free commit observer + optional reconcile tick and publish
    /// the group. Performs NO `await`, so clearing `creating` and installing
    /// `groups[key]` are atomic against every other subscriber — a waiter
    /// can never see "no group and no creation in flight" for a key whose
    /// open succeeded.
    private func installGroup(key: String, watcher box: UnsafeSendableBox<Lattice>?,
                              context: MountPushContext) -> Bool {
        creating[key] = nil
        guard let box, let watcher = box.valueIfPresent else {
            opensStarted[key] = nil
            log.error("observer-push: could not open watcher for \(key); subscribers stay catch-up-only")
            return false
        }
        let group = FileWatchGroup(watcher: box)
        // Payload-free commit signal. The callback runs on the core's
        // notification thread: flag-set + task-spawn ONLY (no SQL, no
        // encoding, no hydration) — the pump re-queries by cursor, which is
        // the correctness mechanism. Registration itself is a leaf-lock map
        // insert, so it stays on the actor: the observer is live before
        // `subscribe` returns, which is what closes the
        // snapshot-versus-watch gap.
        if !context.options._suppressCommitObserverForTesting {
            group.token = watcher.observeCommits { [weak self] in
                guard let self else { return }
                Task { await self.nudge(key: key) }
            }
        }
        if let interval = context.options.reconcileInterval {
            group.reconcile = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled else { return }
                    await self?.nudge(key: key)
                }
            }
        }
        groups[key] = group
        return true
    }

    /// The watcher open itself — ALWAYS called off the actor.
    ///
    /// Uses the subscribing mount's own storeConfiguration (the 1.6.3
    /// per-mount factory) — mandatory, or a watcher on a projector-migrated
    /// file would refuse the open exactly like the pre-1.6.3 relay did —
    /// then strips sync config the way `changeStream`'s query lattice does,
    /// so the watcher never joins sync channels or mints spurious entries.
    /// The group is created from the FIRST subscriber's mount context; later
    /// subscribers from other mounts over the same file share it as-is.
    private static func openWatcher(fileURL: URL,
                                    context: MountPushContext) -> UnsafeSendableBox<Lattice>? {
        var configuration = context.storeConfiguration?(fileURL) ?? .init(fileURL: fileURL)
        configuration.ipcTargets = nil
        configuration.wssEndpoint = nil
        configuration.authorizationToken = nil
        guard let watcher = try? Lattice(for: context.schema, configuration: configuration) else {
            return nil
        }
        return UnsafeSendableBox(watcher)
    }

    /// Canonical channel-file key: channels shared across mounts (writer +
    /// watch over one file) resolve to ONE group.
    static func canonicalKey(for fileURL: URL) -> String {
        fileURL.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
