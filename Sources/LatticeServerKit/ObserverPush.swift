import Foundation
import Dispatch
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
// `ServerSentEvent.auditLog` → socket send completion — advancing the cursor as it
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
// cursor only advances after a successful send completion), in order (at most
// one pump per subscription). Pushed frames are byte-shape identical to
// catch-up frames, which the client engine already applies unconditionally —
// zero client changes. No kick-signaling: push carries only real sync frames.
// ============================================================================

// MARK: - Benchmark-only send boundary

/// Immutable, channel-scoped opt-in. Production options contain nil. The
/// callback receives only the IDs of this already-encoded page, never payloads.
/// This is a send-attempt timestamp, not completion or proof of client receipt.
struct ObserverSendBoundaryProbe: Sendable {
    enum Route: String, Sendable { case catchup, push }
    let channelID: String
    let record: @Sendable (Route, [UUID?], UInt64) -> Void
    let pipeline: Pipeline?

    // Keep the existing channelID + trailing send callback initializer valid.
    init(channelID: String, pipeline: Pipeline? = nil,
         record: @escaping @Sendable (Route, [UUID?], UInt64) -> Void) {
        self.channelID = channelID
        self.pipeline = pipeline
        self.record = record
    }

    /// Immutable per-benchmark observer. No global hook, payload, SQL or logging.
    /// Tokens name recorder rows, not commit IDs or chronological ordering.
    final class Pipeline: Sendable {
        enum Stage: String, Sendable {
            case groupInstallEntry, observerRegistered, subscribed, activated
            case commitCallback, nudgeEntry, nudgeSubscription, pumpScheduled, pumpEntry
            case nudgeTaskStarted, pumpTaskStarted, sendAwaitReturned
            case advanceRequested, advanceEntry, advanceReturned
            case beginPassRequested, beginPassEntry, beginPassReturned
            case pageReadBegin, pageReadEnd, encodeBegin, encodeEnd, encodeFailed, sendPage, finishPass
        }
        struct Event: Sendable {
            let actorGroupID: UInt64?
            let stage: Stage
            let parent: UInt64?
            let related: UInt64?
            let cursor: Int64?
            let count: Int?
            let lastPK: Int64?
            let active: Bool?
            let dirty: Bool?
            let pumping: Bool?
            let callbackCovered: Bool?
            let auditIDs: [UUID?]
        }
        private let record: @Sendable (Event, UInt64) -> UInt64?

        init(record: @escaping @Sendable (Event, UInt64) -> UInt64?) {
            self.record = record
        }

        @discardableResult
        func capture(_ stage: Stage, parent: UInt64? = nil, related: UInt64? = nil,
                     cursor: Int64? = nil, count: Int? = nil, lastPK: Int64? = nil,
                     active: Bool? = nil, dirty: Bool? = nil, pumping: Bool? = nil,
                     callbackCovered: Bool? = nil, auditIDs: [UUID?] = [],
                     actorGroupID: UInt64? = nil,
                     at uptime: UInt64? = nil) -> UInt64? {
            // Timestamp BEFORE recorder locking (sendPage reuses the existing
            // send timestamp). Observation overhead is never subtracted.
            let capturedUptime = uptime ?? DispatchTime.now().uptimeNanoseconds
            return record(Event(actorGroupID: actorGroupID, stage: stage, parent: parent, related: related,
                                cursor: cursor, count: count, lastPK: lastPK,
                                active: active, dirty: dirty, pumping: pumping,
                                callbackCovered: callbackCovered,
                                auditIDs: auditIDs), capturedUptime)
        }
    }

    @discardableResult
    func capture(page: [AuditLog], route: Route, pipelinePage: UInt64? = nil) -> UInt64? {
        // Preserve every entry in order, including coalesced IDs and nil IDs.
        let ids = page.map { $0.globalId }
        return capture(ids: ids, route: route, pipelinePage: pipelinePage)
    }

    @discardableResult
    func capture(ids: [UUID?], route: Route, pipelinePage: UInt64? = nil) -> UInt64? {
        let uptime = DispatchTime.now().uptimeNanoseconds
        record(route, ids, uptime)
        if let pipelinePage {
            // Reuse the EXISTING IDs/time, without an extra AuditLog traversal.
            // Only the push pump supplies a page scope; catch-up stays separate.
            return pipeline?.capture(.sendPage, parent: pipelinePage, count: ids.count,
                                     auditIDs: ids, at: uptime)
        }
        return nil
    }
}

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

    /// Immutable diagnostic selection; only the benchmark copies in a probe.
    let _sendBoundaryProbeForTesting: ObserverSendBoundaryProbe?

    public init(pageSize: Int = 256, reconcileInterval: Duration? = .seconds(30)) {
        precondition(pageSize > 0,
                     "SyncObserverPush.pageSize must be at least 1 (got \(pageSize)) — "
                     + "each pushed frame pages the AuditLog by pageSize rows")
        self.pageSize = pageSize
        self.reconcileInterval = reconcileInterval
        self._sendBoundaryProbeForTesting = nil
    }

    init(copying options: SyncObserverPush, sendBoundaryProbe: ObserverSendBoundaryProbe) {
        self.pageSize = options.pageSize
        self.reconcileInterval = options.reconcileInterval
        self._suppressCommitObserverForTesting = options._suppressCommitObserverForTesting
        self._sendBoundaryProbeForTesting = sendBoundaryProbe
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

/// A pump's own strong reference to the watcher `Lattice`, held for that
/// pump generation. Created ON the manager actor (where the group's box is
/// still guaranteed populated) and released when that generation ends. The pump owns this through a box cleared on the IO pool,
/// never inline on the control actor or an event loop. This is what makes last-subscriber teardown safe: the
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
/// method); native IO work only reads immutable fields and the stop flag.
/// `socket` and `revocation` are thread-safe by their own contracts and are
/// read directly between pages.
final class PushSubscription: @unchecked Sendable {
    let socket: WebSocket
    /// The SAME flag the `SocketManager` entry holds — the pump checks it
    /// before every page, so a kicked observer stops receiving pushed frames
    /// immediately, even if its transport lingers because the peer never
    /// answers the close frame (same authority as the apply path).
    let revocation: RevocationFlag
    /// Separate from authorization: unsubscribe closes native-page admission
    /// even while the transport is still open. Cursor state stays actor-owned.
    let nativePagesStopped = RevocationFlag()
    /// Canonical channel-file path — the watch-group key.
    let key: String
    /// AuditLog entries per pushed frame, from the subscribing MOUNT's
    /// options (the manager is process-wide, so per-mount tuning rides the
    /// subscription). Clamped positive at construction.
    let pageSize: Int
    /// Already selected for this connection's exact channel by the mount.
    let sendBoundaryProbe: ObserverSendBoundaryProbe?
    /// Recorder-local identity, immutable for this subscription (nil when off).
    let pipelineSubscription: UInt64?
    let setupDiagnostic: ACKPathConnection?
    /// Process-local group incarnation, nil unless actor diagnostics are enabled.
    let diagnosticGroupID: UInt64?
    /// `nil` = parked (connect-time catch-up in flight). Installed once by
    /// `activate(_:cursor:)` with the catch-up boundary, then only advanced
    /// by the pump after a successful send completion.
    var cursor: Int64?
    /// A nudge arrived while parked or while a pump pass was running.
    var dirty = false
    /// At most one pump generation per subscription (serialization: per-socket
    /// frames are strictly ordered because only one pump advances the
    /// cursor).
    var pumping = false
    /// Cleared by `unsubscribe`; in-flight pump passes check it and stop.
    var active = true

    init(socket: WebSocket, revocation: RevocationFlag, key: String, pageSize: Int,
         sendBoundaryProbe: ObserverSendBoundaryProbe? = nil,
         pipelineSubscription: UInt64? = nil, diagnosticGroupID: UInt64? = nil, setupDiagnostic: ACKPathConnection? = nil) {
        self.socket = socket
        self.revocation = revocation
        self.key = key
        self.pageSize = max(1, pageSize)
        self.sendBoundaryProbe = sendBoundaryProbe
        self.pipelineSubscription = pipelineSubscription
        self.diagnosticGroupID = diagnosticGroupID
        self.setupDiagnostic = setupDiagnostic
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
    let signal = RelayCoalescedSignal()
    /// Optional reconcile tick (see `SyncObserverPush.reconcileInterval`).
    var reconcile: RelayReconcileTimer?
    var subscribers: [PushSubscription] = []

    // Only the FIRST creator's already channel-selected probe reaches the
    // file observer. Later subscribers neither replace nor install a hook.
    let pipeline: ObserverSendBoundaryProbe.Pipeline?
    let pipelineGroup: UInt64?
    let diagnosticGroupID: UInt64?

    init(watcher: UnsafeSendableBox<Lattice>,
         pipeline: ObserverSendBoundaryProbe.Pipeline?, pipelineGroup: UInt64?, diagnosticGroupID: UInt64?) {
        self.watcher = watcher
        self.pipeline = pipeline
        self.pipelineGroup = pipelineGroup
        self.diagnosticGroupID = diagnosticGroupID
    }
}

/// A prepared page owns bytes and fixed metadata, never managed row handles.
private enum PreparedPushPage: Sendable {
    case empty, stopped, encodingFailed
    case encoded(data: Data, count: Int, last: Int64, ids: [UUID?], trace: UInt64?)
}

/// One generation of a subscription's pump. Native ownership is reachable
/// only through its IO-owned box, which is emptied exactly once off control.
@RelayControlActor private final class ActivePushPump {
    enum Phase { case starting, reading, sending, finished }
    let sub: PushSubscription
    let watcher: UnsafeSendableBox<WatcherRef>
    let pipelinePump: UInt64?
    var trace: UInt64?
    var pass: UInt64?
    var cursor: Int64 = 0
    var phase = Phase.starting
    init(sub: PushSubscription, watcher: UnsafeSendableBox<WatcherRef>, pipelinePump: UInt64?) {
        self.sub = sub; self.watcher = watcher; self.pipelinePump = pipelinePump
    }
    func releaseWatcher() {
        guard phase != .finished else { return }
        phase = .finished
        let box = watcher
        RelayExecutionPool.io.submitRequired(for: sub.key) { box.clear() }
    }
}

@RelayControlActor private final class PendingWatchOpen {
    struct Waiter {
        let context: MountPushContext
        let socket: WebSocket
        let revocation: RevocationFlag
        let probe: ObserverSendBoundaryProbe?
        let diagnostic: ACKPathConnection?
        let completion: @RelayControlActor @Sendable (PushSubscription?) -> Void
    }
    var waiters: [Waiter] = []
    func fail() {
        let pending = waiters; waiters = []
        for waiter in pending { waiter.completion(nil) }
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
@RelayControlActor final class FileWatchManager {
    /// The process-wide instance every push-enabled mount shares.
    nonisolated static let shared = FileWatchManager()
    nonisolated init() {}

    /// Keyed by canonical channel-file path.
    private var groups: [String: FileWatchGroup] = [:]

    /// One pending watcher open per key. Subscribers join its waiter list;
    /// its control completion installs the observer/group, then publishes all
    /// parked subscriptions before resuming any external waiter.
    private var creating: [String: PendingWatchOpen] = [:]
    /// Identity of each pump is its generation; stale completion callbacks
    /// can never mutate a replacement pump for the same subscription.
    private var pumps: [ObjectIdentifier: ActivePushPump] = [:]

    /// Watcher opens STARTED for each live group's key — teardown clears the
    /// entry with the group, so this is bounded by live groups, never by
    /// channels ever seen. Dedupe observability (see `watcherOpenCount`).
    private var opensStarted: [String: Int] = [:]

    private let log = Logger(label: "lattice.observer-push")
    // Each scope below covers only a synchronous actor chunk, never an await.
    // Phase returns are call-site markers, not implicit ARC cleanup barriers.
    private let actorDiagnostics = ObserverActorDiagnostics.shared

    /// Whether a live watch group exists for the given channel file —
    /// key-scoped teardown observability (the manager is process-wide, so a
    /// global count would be cross-mount/cross-suite noise). Tests assert
    /// this goes false after the last subscriber leaves, so a big fleet
    /// cannot accumulate watcher opens/fds.
    func hasGroup(forFile fileURL: URL) -> Bool {
        let scope = actorDiagnostics.begin(.hasGroup)
        defer { actorDiagnostics.end(scope) }
        actorDiagnostics.phase(scope, .canonicalization)
        let key = Self.canonicalKey(for: fileURL)
        actorDiagnostics.phase(scope, .actorBody, group: groups[key]?.diagnosticGroupID)
        return groups[key] != nil
    }

    /// Live subscriber count on the given file's group (0 when no group).
    func subscriberCount(forFile fileURL: URL) -> Int {
        let scope = actorDiagnostics.begin(.subscriberCount)
        defer { actorDiagnostics.end(scope) }
        actorDiagnostics.phase(scope, .canonicalization)
        let key = Self.canonicalKey(for: fileURL)
        actorDiagnostics.phase(scope, .actorBody, group: groups[key]?.diagnosticGroupID)
        return groups[key]?.subscribers.count ?? 0
    }

    /// Watcher opens started for this file since its current group began —
    /// cleared with the group, exactly like `hasGroup`. However many sockets
    /// race to be the first subscriber, a live group must report 1: the
    /// per-key in-flight task dedupes them onto ONE open.
    func watcherOpenCount(forFile fileURL: URL) -> Int {
        let scope = actorDiagnostics.begin(.watcherOpenCount)
        defer { actorDiagnostics.end(scope) }
        actorDiagnostics.phase(scope, .canonicalization)
        let key = Self.canonicalKey(for: fileURL)
        actorDiagnostics.phase(scope, .actorBody, group: groups[key]?.diagnosticGroupID)
        return opensStarted[key] ?? 0
    }

    /// Registers a PARKED subscription (no cursor yet). MUST be called
    /// before the caller takes its catch-up snapshot: the commit observer is
    /// live from here on (it is registered before this returns), so any
    /// commit after the snapshot lands as a `dirty` nudge on the parked
    /// subscription and activation's first pump picks it up — no commit can
    /// fall between snapshot and watch.
    ///
    /// The first subscriber for a file pays for the watcher open. That open
    /// runs OFF this actor (see `startOpen`): it is a full SQLite open —
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
                   socket: WebSocket, revocation: RevocationFlag,
                   sendBoundaryProbe: ObserverSendBoundaryProbe? = nil,
                   setupDiagnostic: ACKPathConnection? = nil) async -> PushSubscription? {
        await withCheckedContinuation { continuation in
            subscribe(fileURL: fileURL, context: context, socket: socket,
                      revocation: revocation, sendBoundaryProbe: sendBoundaryProbe,
                      setupDiagnostic: setupDiagnostic) { subscription in
                continuation.resume(returning: subscription)
            }
        }
    }

    /// Internal relay setup avoids resuming an intermediate generic async
    /// waiter. Existing async callers retain their API and cancellation contract.
    /// A callback cannot cancel an open shared by other pending subscribers.
    func subscribe(fileURL: URL, context: MountPushContext,
                   socket: WebSocket, revocation: RevocationFlag,
                   sendBoundaryProbe: ObserverSendBoundaryProbe? = nil,
                   setupDiagnostic: ACKPathConnection? = nil,
                   completion: @escaping @RelayControlActor @Sendable (PushSubscription?) -> Void) {
        setupDiagnostic?.record(.watchSubscribeEntered)
        let canonicalScope = actorDiagnostics.begin(.subscribeCanonicalization)
        actorDiagnostics.phase(canonicalScope, .canonicalization)
        let key = Self.canonicalKey(for: fileURL)
        actorDiagnostics.end(canonicalScope)
        let waiter = PendingWatchOpen.Waiter(context: context, socket: socket,
                                            revocation: revocation, probe: sendBoundaryProbe,
                                            diagnostic: setupDiagnostic, completion: completion)
        let scope = actorDiagnostics.begin(.resolveGroupSetup, group: groups[key]?.diagnosticGroupID)
        if let group = groups[key] {
            actorDiagnostics.end(scope)
            let subscription = publish(waiter, key: key, group: group)
            completion(subscription)
        } else if let pending = creating[key] {
            pending.waiters.append(waiter)
            actorDiagnostics.end(scope)
        } else {
            let pending = PendingWatchOpen()
            pending.waiters.append(waiter)
            creating[key] = pending
            opensStarted[key, default: 0] += 1
            setupDiagnostic?.record(.watchOpenScheduled)
            actorDiagnostics.end(scope)
            Task { @RelayControlActor [weak self] in
                setupDiagnostic?.record(.watchOpenTaskStarted)
                guard let self else { pending.fail(); return }
                self.startOpen(pending, key: key, fileURL: fileURL, context: context,
                               probe: sendBoundaryProbe, diagnostic: setupDiagnostic)
            }
        }
    }

    private func publish(_ waiter: PendingWatchOpen.Waiter, key: String,
                         group: FileWatchGroup) -> PushSubscription {
        let context = waiter.context, socket = waiter.socket, revocation = waiter.revocation
        let sendBoundaryProbe = waiter.probe, setupDiagnostic = waiter.diagnostic
        let scope = actorDiagnostics.begin(.subscribePublish, group: group.diagnosticGroupID)
        defer { actorDiagnostics.end(scope) }
        let pipeline = sendBoundaryProbe?.pipeline
        let subscriptionTrace = pipeline?.capture(
            .subscribed, related: group.pipeline === pipeline ? group.pipelineGroup : nil,
            callbackCovered: group.pipeline === pipeline && group.token != nil,
            actorGroupID: group.diagnosticGroupID)
        let sub = PushSubscription(socket: socket, revocation: revocation, key: key,
                                   pageSize: context.options.pageSize,
                                   sendBoundaryProbe: sendBoundaryProbe,
                                   pipelineSubscription: subscriptionTrace,
                                   diagnosticGroupID: group.diagnosticGroupID,
                                   setupDiagnostic: setupDiagnostic)
        group.subscribers.append(sub)
        setupDiagnostic?.record(.watchSubscribePublished, span: group.diagnosticGroupID ?? 0,
                                count: group.subscribers.count)
        return sub
    }

    /// End of connect-time catch-up: install the boundary cursor (pk of the
    /// last catch-up entry the socket was sent; the checkpoint entry's pk
    /// when catch-up was empty; 0 on an empty log) and pump. The first pass
    /// reads strictly beyond the boundary, so pushed frames never interleave
    /// with — or duplicate — catch-up pages; it also drains any nudges that
    /// buffered while parked (a clean pass is one indexed SELECT).
    func activate(_ sub: PushSubscription, cursor: Int64) {
        let scope = actorDiagnostics.begin(.activate, group: sub.diagnosticGroupID)
        defer { actorDiagnostics.end(scope) }
        guard sub.active else { return }
        sub.cursor = cursor
        sub.setupDiagnostic?.record(.watchActivated, span: sub.diagnosticGroupID ?? 0)
        sub.dirty = true
        // This is the actual activation fact; receipt of a warmup frame is not.
        let activation = sub.sendBoundaryProbe?.pipeline?.capture(
            .activated, parent: sub.pipelineSubscription, cursor: cursor,
            active: sub.active, dirty: sub.dirty, pumping: sub.pumping)
        maybePump(sub, pipelineTrigger: activation)
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
    /// (the group or pump box) is cleared on the dedicated IO pool.
    func unsubscribe(_ sub: PushSubscription) {
        let scope = actorDiagnostics.begin(.unsubscribe, group: sub.diagnosticGroupID)
        defer { actorDiagnostics.end(scope) }
        sub.active = false
        sub.nativePagesStopped.revoke()
        if let pump = pumps[ObjectIdentifier(sub)] { stopPump(pump) }
        guard let group = groups[sub.key] else { return }
        group.subscribers.removeAll { $0 === sub }
        if group.subscribers.isEmpty {
            groups[sub.key] = nil
            opensStarted[sub.key] = nil
            actorDiagnostics.phase(scope, .observerRemoval, group: group.diagnosticGroupID)
            group.signal.cancel()
            group.token?.cancel()
            actorDiagnostics.phase(scope, .tokenRelease)
            group.token = nil
            actorDiagnostics.phase(scope, .reconcileCancellation)
            group.reconcile?.cancel()
            actorDiagnostics.phase(scope, .reconcileRelease)
            group.reconcile = nil
            actorDiagnostics.phase(scope, .watcherReleaseHandoff)
            let box = group.watcher
            RelayExecutionPool.io.submitRequired(for: sub.key) { box.clear() }
            actorDiagnostics.phase(scope, .actorBody)
        }
    }

    /// Commit notification (or reconcile tick) for one file: mark every
    /// subscriber dirty and spawn pumps for the activated ones. Parked
    /// subscriptions keep the dirty flag until activation. Nudges are
    /// coalesced by `dirty`: N commits during one pump pass cost exactly one
    /// extra pass — O(new entries), not O(commits).
    func nudge(key: String, pipeline: ObserverSendBoundaryProbe.Pipeline? = nil,
               pipelineCallback: UInt64? = nil, pipelineTask: UInt64? = nil) {
        let scope = actorDiagnostics.begin(.nudge, group: groups[key]?.diagnosticGroupID)
        defer { actorDiagnostics.end(scope) }
        let nudgeTrace = pipeline?.capture(.nudgeEntry, parent: pipelineCallback, related: pipelineTask)
        guard let group = groups[key] else { return }
        for sub in group.subscribers {
            let wake = sub.sendBoundaryProbe?.pipeline?.capture(
                .nudgeSubscription, parent: sub.pipelineSubscription,
                related: sub.sendBoundaryProbe?.pipeline === pipeline ? nudgeTrace : nil,
                cursor: sub.cursor, active: sub.active, dirty: sub.dirty, pumping: sub.pumping)
            sub.dirty = true
            maybePump(sub, pipelineTrigger: wake)
        }
    }

    // MARK: pump machinery

    private func maybePump(_ sub: PushSubscription, pipelineTrigger: UInt64? = nil) {
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
        // group is provably alive and held for the pump generation —
        // last-subscriber teardown can clear the group's box mid-pass
        // without invalidating this pump; it finishes its pass (or exits on
        // its next closed/revoked/inactive check) against a live instance,
        // and the Lattice is finally released off-actor when the last
        // holder's IO-owned box is cleared.
        let watcher = UnsafeSendableBox(WatcherRef(lattice))
        let pumpTrace = sub.sendBoundaryProbe?.pipeline?.capture(
            .pumpScheduled, parent: sub.pipelineSubscription, related: pipelineTrigger,
            cursor: sub.cursor, active: sub.active, dirty: sub.dirty, pumping: sub.pumping)
        let pump = ActivePushPump(sub: sub, watcher: watcher, pipelinePump: pumpTrace)
        pumps[ObjectIdentifier(sub)] = pump
        sub.setupDiagnostic?.record(.pushPumpScheduled, span: sub.diagnosticGroupID ?? 0)
        Task { @RelayControlActor [weak self] in
            sub.setupDiagnostic?.record(.pushPumpTaskStarted, span: sub.diagnosticGroupID ?? 0)
            let started = sub.sendBoundaryProbe?.pipeline?.capture(.pumpTaskStarted, parent: pumpTrace)
            guard let self else { pump.releaseWatcher(); return }
            guard self.isCurrent(pump) else { self.stopPump(pump); return }
            pump.trace = sub.sendBoundaryProbe?.pipeline?.capture(.pumpEntry, parent: pumpTrace, related: started)
            self.startPass(pump)
        }
    }

    private func isCurrent(_ pump: ActivePushPump) -> Bool {
        pump.phase != .finished && pump.sub.active && pumps[ObjectIdentifier(pump.sub)] === pump
    }

    private func stopPump(_ pump: ActivePushPump) {
        if pumps[ObjectIdentifier(pump.sub)] === pump {
            pumps[ObjectIdentifier(pump.sub)] = nil
            pump.sub.pumping = false
        }
        pump.releaseWatcher()
    }

    private func startPass(_ pump: ActivePushPump) {
        guard isCurrent(pump) else { stopPump(pump); return }
        let sub = pump.sub, pipeline = sub.sendBoundaryProbe?.pipeline
        let request = pipeline?.capture(.beginPassRequested, parent: pump.trace)
        guard let cursor = beginPass(sub, pipelineRequest: request) else { stopPump(pump); return }
        pump.cursor = cursor
        pump.pass = pipeline?.capture(.beginPassReturned, parent: request, cursor: cursor)
        readNextPage(pump)
    }

    private func readNextPage(_ pump: ActivePushPump) {
        guard isCurrent(pump) else { stopPump(pump); return }
        let sub = pump.sub
        guard !sub.revocation.isRevoked, !sub.socket.isClosed else { unsubscribe(sub); return }
        pump.phase = .reading
        let box = pump.watcher, cursor = pump.cursor, pass = pump.pass
        RelayExecutionPool.io.submitRequired(for: sub.key) { [weak self] in
            let prepared = Self.preparePage(sub, watcher: box, cursor: cursor, pageSize: sub.pageSize, pass: pass)
            // A native completion goes directly to the explicit actor. It
            // never resumes an intermediate nonisolated async function.
            Task { @RelayControlActor [weak self] in
                guard let self else { pump.releaseWatcher(); return }
                self.pagePrepared(prepared, for: pump)
            }
        }
    }

    private func pagePrepared(_ prepared: PreparedPushPage, for pump: ActivePushPump) {
        guard isCurrent(pump), pump.phase == .reading else { stopPump(pump); return }
        let sub = pump.sub
        guard !sub.revocation.isRevoked, !sub.socket.isClosed else { unsubscribe(sub); return }
        switch prepared {
        case .stopped:
            unsubscribe(sub)
        case .empty:
            // Dirty check and pumping-slot release remain a single actor
            // chunk. A nudge can neither fall between them nor start a rival.
            if finishPass(sub, pipelinePass: pump.pass) { startPass(pump) }
            else { stopPump(pump) }
        case .encodingFailed:
            log.error("observer-push: failed to encode page after id \(pump.cursor); dropping subscriber")
            unsubscribe(sub)
        case let .encoded(data, count, last, ids, pageTrace):
            pump.phase = .sending
            let send = sub.sendBoundaryProbe?.capture(ids: ids, route: .push, pipelinePage: pageTrace)
            sub.setupDiagnostic?.record(.pushSendBegin, span: sub.diagnosticGroupID ?? 0,
                                        bytes: data.count, count: count)
            let promise = sub.socket.eventLoop.makePromise(of: Void.self)
            promise.futureResult.whenComplete { [weak self] result in
                Task { @RelayControlActor [weak self] in
                    guard let self else { pump.releaseWatcher(); return }
                    self.sendCompleted(result, for: pump, last: last, count: count, send: send)
                }
            }
            // One page in flight. The next native read is admitted only from
            // the successful promise completion, preserving socket flow control.
            if sub.revocation.hasRecovery {
                sub.socket.eventLoop.execute {
                    guard !sub.revocation.isRevoked, !sub.socket.isClosed else {
                        promise.fail(SyncRecoveryConfigurationError.staleAuthorization); return
                    }
                    sub.socket.send(raw: data, opcode: .binary, promise: promise)
                }
            } else { sub.socket.send(raw: data, opcode: .binary, promise: promise) }
        }
    }

    private func sendCompleted(_ result: Result<Void, Error>, for pump: ActivePushPump,
                               last: Int64, count: Int, send: UInt64?) {
        guard isCurrent(pump), pump.phase == .sending else { stopPump(pump); return }
        let sub = pump.sub
        guard case .success = result else { unsubscribe(sub); return }
        sub.setupDiagnostic?.record(.pushSendReturn, span: sub.diagnosticGroupID ?? 0)
        // This remains a promise-completion-plus-control-admission marker,
        // not an event-loop-only write completion timestamp.
        let returned = sub.sendBoundaryProbe?.pipeline?.capture(.sendAwaitReturned, parent: send)
        log.debug("observer-push: sent \(count) entries (\(pump.cursor + 1)...\(last))")
        pump.cursor = last
        let request = sub.sendBoundaryProbe?.pipeline?.capture(.advanceRequested, parent: returned,
                                                               cursor: last, actorGroupID: sub.diagnosticGroupID)
        advance(sub, to: last, pipelineRequest: request)
        sub.sendBoundaryProbe?.pipeline?.capture(.advanceReturned, parent: request, cursor: last)
        readNextPage(pump)
    }

    private nonisolated static func preparePage(_ sub: PushSubscription,
                                               watcher box: UnsafeSendableBox<WatcherRef>,
                                               cursor: Int64, pageSize: Int, pass: UInt64?) -> PreparedPushPage {
        guard !sub.nativePagesStopped.isRevoked, !sub.revocation.isRevoked, !sub.socket.isClosed,
              let watcher = box.valueIfPresent else { return .stopped }
        let pipeline = sub.sendBoundaryProbe?.pipeline
        sub.setupDiagnostic?.record(.pushPageBegin, span: sub.diagnosticGroupID ?? 0)
        let pageRead = pipeline?.capture(.pageReadBegin, parent: pass, cursor: cursor)
        let sampled = watcher.lattice.eventsAfter(id: cursor).snapshot(limit: Int64(pageSize))
        let page = watcher.lattice.lateBindNoHistory(sub.revocation.filterRecoveryPage(sampled))
        let pageReadEnd = pipeline?.capture(.pageReadEnd, parent: pageRead, cursor: cursor, count: page.count)
        sub.setupDiagnostic?.record(.pushPageEnd, span: sub.diagnosticGroupID ?? 0, count: page.count)
        let cursorPage = sub.revocation.hasRecovery ? sampled : page
        guard !cursorPage.isEmpty, let last = cursorPage.last?.primaryKey else { return .empty }
        let encoding = pipeline?.capture(.encodeBegin, parent: pageReadEnd,
                                         cursor: cursor, count: page.count, lastPK: last)
        guard let encoded = try? JSONEncoder().encode(ServerSentEvent.auditLog(page)) else {
            pipeline?.capture(.encodeFailed, parent: encoding)
            return .encodingFailed
        }
        pipeline?.capture(.encodeEnd, parent: encoding, count: encoded.count)
        let ids = sub.sendBoundaryProbe == nil ? [] : page.map { $0.globalId }
        return .encoded(data: encoded, count: page.count, last: last, ids: ids, trace: pageReadEnd)
    }

    /// Start of a pump pass: consume the dirty flag and read the cursor.
    /// `nil` = subscription gone or still parked; the pump exits (pumping
    /// released so a later nudge/activation can start a fresh one).
    private func beginPass(_ sub: PushSubscription, pipelineRequest: UInt64?) -> Int64? {
        let scope = actorDiagnostics.begin(.beginPass, group: sub.diagnosticGroupID)
        defer { actorDiagnostics.end(scope) }
        sub.sendBoundaryProbe?.pipeline?.capture(
            .beginPassEntry, parent: pipelineRequest, cursor: sub.cursor,
            active: sub.active, dirty: sub.dirty, pumping: sub.pumping)
        guard sub.active, let cursor = sub.cursor else {
            sub.pumping = false
            return nil
        }
        sub.dirty = false
        return cursor
    }

    /// The cursor only advances after a successful send completion — every
    /// frame is produced by `id > cursor ORDER BY id ASC`, so no dupes by
    /// construction.
    private func advance(_ sub: PushSubscription, to cursor: Int64, pipelineRequest: UInt64?) {
        let scope = actorDiagnostics.begin(.advance, group: sub.diagnosticGroupID)
        defer { actorDiagnostics.end(scope) }
        sub.sendBoundaryProbe?.pipeline?.capture(.advanceEntry, parent: pipelineRequest, cursor: cursor,
                                                actorGroupID: sub.diagnosticGroupID)
        sub.cursor = cursor
    }

    /// End of a pass. `true` = a nudge landed during the pass (dirty again):
    /// run another pass with `pumping` still claimed. `false` = drained;
    /// release the pump slot. Checked under the actor so a nudge that
    /// arrives between the pump's last empty query and this call is never
    /// lost (it either re-loops this pump or — after release — spawns a
    /// fresh one).
    private func finishPass(_ sub: PushSubscription, pipelinePass: UInt64?) -> Bool {
        let scope = actorDiagnostics.begin(.finishPass, group: sub.diagnosticGroupID)
        defer { actorDiagnostics.end(scope) }
        sub.sendBoundaryProbe?.pipeline?.capture(
            .finishPass, parent: pipelinePass, cursor: sub.cursor,
            active: sub.active, dirty: sub.dirty, pumping: sub.pumping)
        if sub.dirty && sub.active { return true }
        sub.pumping = false
        return false
    }

    // MARK: group construction

    /// One pending open per key. Installation and waiter publication happen
    /// together in its explicit actor completion; one waiter's cancellation
    /// never cancels another waiter's shared native open.
    private func startOpen(_ pending: PendingWatchOpen, key: String, fileURL: URL,
                           context: MountPushContext, probe: ObserverSendBoundaryProbe?,
                           diagnostic: ACKPathConnection?) {
        RelayExecutionPool.io.submitRequired(for: key) { [weak self] in
            diagnostic?.record(.watchOpenBegin)
            let opened = Self.openWatcher(fileURL: fileURL, context: context)
            diagnostic?.record(.watchOpenEnd, result: opened != nil)
            diagnostic?.record(.watchInstallRequested)
            Task { @RelayControlActor [weak self] in
                guard let self else {
                    pending.fail()
                    RelayExecutionPool.io.submitRequired(for: key) { opened?.clear() }
                    return
                }
                guard self.creating[key] === pending else {
                    pending.fail()
                    RelayExecutionPool.io.submitRequired(for: key) { opened?.clear() }
                    return
                }
                let installed = self.installGroup(key: key, watcher: opened, context: context,
                                                  sendBoundaryProbe: probe, setupDiagnostic: diagnostic)
                let scope = self.actorDiagnostics.begin(.resolveGroupReturn,
                                                         group: self.groups[key]?.diagnosticGroupID)
                guard installed, let group = self.groups[key] else {
                    self.actorDiagnostics.end(scope)
                    pending.fail()
                    return
                }
                let waiters = pending.waiters
                pending.waiters = []
                self.actorDiagnostics.end(scope)
                let publications = waiters.map { waiter in
                    (waiter.completion, self.publish(waiter, key: key, group: group))
                }
                for (completion, subscription) in publications {
                    completion(subscription)
                }
            }
        }
    }

    /// Hop back onto the actor with the opened watcher: register the
    /// payload-free commit observer + optional reconcile tick and publish
    /// the group. Performs NO `await`, so clearing `creating` and installing
    /// `groups[key]` are atomic against every other subscriber — a waiter
    /// can never see "no group and no creation in flight" for a key whose
    /// open succeeded.
    private func installGroup(key: String, watcher box: UnsafeSendableBox<Lattice>?,
                              context: MountPushContext,
                              sendBoundaryProbe: ObserverSendBoundaryProbe?,
                              setupDiagnostic: ACKPathConnection?) -> Bool {
        setupDiagnostic?.record(.watchInstallEntered)
        let diagnosticGroupID = actorDiagnostics.groupID()
        let scope = actorDiagnostics.begin(.installGroup, group: diagnosticGroupID)
        defer { actorDiagnostics.end(scope) }
        creating[key] = nil
        guard let box, let watcher = box.valueIfPresent else {
            opensStarted[key] = nil
            log.error("observer-push: could not open watcher for \(key); subscribers stay catch-up-only")
            return false
        }
        let pipeline = sendBoundaryProbe?.pipeline
        let groupTrace = pipeline?.capture(.groupInstallEntry, actorGroupID: diagnosticGroupID)
        let group = FileWatchGroup(watcher: box, pipeline: pipeline, pipelineGroup: groupTrace,
                                   diagnosticGroupID: diagnosticGroupID)
        // Payload-free commit signal. The callback runs on the core's
        // notification thread: flag-set + task-spawn (and bounded metadata
        // only for the benchmark probe; no SQL, encoding or hydration). The pump
        // re-queries by cursor, which is
        // the correctness mechanism. Registration itself is a leaf-lock map
        // insert, so it stays on the actor: the observer is live before
        // `subscribe` returns, which is what closes the
        // snapshot-versus-watch gap.
        let signal = group.signal
        signal.install { @RelayControlActor [weak self, weak signal] in
            guard let self, let signal else { return }
            defer { signal.finish() }
            guard let callback = signal.take() else { return }
            let started = pipeline?.capture(.nudgeTaskStarted, parent: callback)
            self.nudge(key: key, pipeline: pipeline,
                       pipelineCallback: callback, pipelineTask: started)
        }
        if !context.options._suppressCommitObserverForTesting {
            actorDiagnostics.phase(scope, .observerRegistration)
            group.token = watcher.observeCommits {
                let callback = pipeline?.capture(.commitCallback, parent: groupTrace)
                signal.signal(callback: callback)
            }
            actorDiagnostics.phase(scope, .actorBody)
            pipeline?.capture(.observerRegistered, parent: groupTrace)
            setupDiagnostic?.record(.watchObserverRegistered, span: diagnosticGroupID ?? 0)
        }
        if let interval = context.options.reconcileInterval {
            let parts = interval.components
            group.reconcile = RelayReconcileTimer(seconds: parts.seconds, attoseconds: parts.attoseconds, signal: signal)
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
    private nonisolated static func openWatcher(fileURL: URL,
                                    context: MountPushContext) -> UnsafeSendableBox<Lattice>? {
        // Same bounded busy budget as the relay's per-connection open: the
        // core's instance cache does not key on `busyTimeoutMs`, so whichever
        // open wins the race for a file installs the budget every aliased
        // handle then runs with — a watcher opening first with the library's
        // 30s default would silently restore the parking behavior 1.7.1
        // removes.
        var configuration = SyncRelayApplyPolicy.configuration(
            fileURL: fileURL, storeConfiguration: context.storeConfiguration)
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
    nonisolated static func canonicalKey(for fileURL: URL) -> String {
        fileURL.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
