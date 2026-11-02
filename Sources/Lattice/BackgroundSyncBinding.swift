import Foundation
import Dispatch

extension Lattice {
    /// The outcome of one bounded sync opportunity. Completion covers the
    /// operation's starting upload prefix and the server's initial replay.
    /// It does not promise that no newer edits exist on either side.
    public enum SyncOnceResult: Sendable, Equatable {
        case completed
        /// Useful work may have committed, but completion was not confirmed.
        case budgetExhausted
        /// Another session already owns sync; it was left running.
        case alreadyRunning
        /// The configured store or sync endpoint is no longer available.
        case unavailable
    }

    /// Perform finite sync without registering an Apple background task.
    ///
    /// Use a deferred store when the caller owns the execution opportunity.
    /// An already running foreground session returns `alreadyRunning`.
    /// Cancellation waits for owned work to settle before throwing.
    public func syncOnce(
        maximumDuration: TimeInterval = 20,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> SyncOnceResult {
        guard maximumDuration.isFinite, maximumDuration > 0 else {
            throw Error.databaseError("The sync duration must be finite and greater than zero.")
        }
        let group = try BackgroundSyncBindings.attach(backend: backend, isolation: isolation)
        return try await group.perform(.refresh(duration: maximumDuration))
    }
}

/// A capability over a retained native store, not the non-Sendable facade.
/// Implementations perform blocking settlement on the caller's worker thread.
internal protocol BackgroundSyncBackend: AnyObject, Sendable {
    var identityHash: Int64 { get }
    func closeBackgroundSyncMember()
    func performBackgroundSync(
        _ command: BackgroundTaskCommand,
        cancellation: SyncWorkCancellation
    ) throws -> Lattice.SyncOnceResult
}

/// Cancellation can arrive before native setup has installed its token. The
/// installation observes that race and forwards cancellation immediately.
internal final class SyncWorkCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handler: (@Sendable () -> Void)?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func install(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        let alreadyCancelled = cancelled
        let retired = self.handler
        self.handler = handler
        lock.unlock()
        withExtendedLifetime(retired) {}
        if alreadyCancelled { handler() }
    }

    func cancel() {
        lock.lock()
        let first = !cancelled
        cancelled = true
        let callback = first ? handler : nil
        lock.unlock()
        callback?()
    }

    func clearHandler() {
        lock.lock()
        let retired = handler
        handler = nil
        lock.unlock()
        withExtendedLifetime(retired) {}
    }

    /// Transfer a successfully resumed foreground session out of this command.
    /// Cancellation either wins before transfer (requiring settlement) or can
    /// no longer cancel the session through an obsolete command's handler.
    func disarmIfNotCancelled() -> Bool {
        lock.lock()
        let succeeded = !cancelled
        let retired = handler
        handler = nil
        lock.unlock()
        withExtendedLifetime(retired) {}
        return succeeded
    }
}

/// Runtime lineage is separate from public policy/hash data. Configurations and
/// sendable references may retain this token, but the group retains only weak
/// backends/actors while idle. An invalidated lineage never adopts a new account.
internal final class BackgroundSyncLineage: @unchecked Sendable {
    private let lock = NSLock()
    private var group: BackgroundSyncBindingGroup?

    var current: BackgroundSyncBindingGroup? {
        lock.lock(); defer { lock.unlock() }
        return group
    }

    func bind(_ proposed: BackgroundSyncBindingGroup) throws {
        lock.lock(); defer { lock.unlock() }
        guard group == nil || group === proposed else {
            throw Lattice.Error.databaseError("A background store lineage cannot adopt another owner.")
        }
        group = proposed
    }

    func validate() throws {
        guard current?.isInvalidated != true else {
            throw Lattice.Error.databaseError("This background store was closed; open a new store for the current account.")
        }
    }
}

/// One task owner coordinates every local native handle derived from it. The
/// owner alone may upload; borrowed handles have local-only configurations.
/// Candidates keep both the actor and native backend weak outside a command.
internal final class BackgroundSyncBindingGroup: @unchecked Sendable {
    private final class Candidate: @unchecked Sendable {
        let identity: ObjectIdentifier
        let nativeIdentity: Int64
        weak var backend: (any BackgroundSyncBackend)?
        weak var owner: (any Actor)?
        let requiresActor: Bool
        var ownsLifecycle: Bool

        init(backend: any BackgroundSyncBackend, owner: (any Actor)?, ownsLifecycle: Bool) {
            identity = ObjectIdentifier(backend)
            nativeIdentity = backend.identityHash
            self.backend = backend
            self.owner = owner
            requiresActor = owner != nil
            self.ownsLifecycle = ownsLifecycle
        }
    }

    private struct Member: Sendable {
        let identity: Int64
        let backend: any BackgroundSyncBackend
        let owner: (any Actor)?
    }
    private struct Operation: Sendable {
        let identity: Int64
        let cancellation: SyncWorkCancellation
    }

    let identity: Int64
    private let commands = BackgroundSyncCommandQueue()
    private let lock = NSLock()
    private var candidates: [Candidate] = []
    private var operations: [UUID: Operation] = [:]
    private var invalidated = false
    private var retiredIdentities = Set<Int64>()
    private var foregroundRequested = false

    init(identity: Int64) { self.identity = identity }

    var isInvalidated: Bool {
        lock.lock(); defer { lock.unlock() }
        return invalidated
    }

    @discardableResult
    func add(backend: any BackgroundSyncBackend, owner: (any Actor)?, ownsLifecycle: Bool) throws -> Bool {
        let candidate = Candidate(backend: backend, owner: owner, ownsLifecycle: ownsLifecycle)
        lock.lock()
        let snapshot = candidates
        lock.unlock()
        let expired = Set(snapshot.filter { $0.backend == nil }.map(ObjectIdentifier.init))
        lock.lock()
        let retired = candidates
        let rejected = invalidated || retiredIdentities.contains(candidate.nativeIdentity)
        let addedIdentity = !candidates.contains {
            !expired.contains(ObjectIdentifier($0)) && $0.nativeIdentity == candidate.nativeIdentity
        }
        if !rejected {
            candidate.ownsLifecycle = candidate.ownsLifecycle ||
                candidates.contains { $0.identity == candidate.identity && $0.ownsLifecycle }
            candidates.removeAll { expired.contains(ObjectIdentifier($0)) || $0.identity == candidate.identity }
            candidates.append(candidate)
        }
        lock.unlock()
        withExtendedLifetime(retired) {}
        guard !rejected else {
            throw Lattice.Error.databaseError("Cannot attach a handle to a closed background store.")
        }
        return addedIdentity
    }

    func pruneExpiredCandidates(forgetRetiredIdentity identity: Int64? = nil) {
        lock.lock(); let snapshot = candidates; lock.unlock()
        let expired = Set(snapshot.filter { $0.backend == nil }.map(ObjectIdentifier.init))
        lock.lock()
        let retired = candidates
        candidates.removeAll { expired.contains(ObjectIdentifier($0)) }
        if let identity { retiredIdentities.remove(identity) }
        lock.unlock()
        withExtendedLifetime(retired) {}
    }

    private func liveMembers() -> [Member] {
        lock.lock()
        let snapshot = invalidated ? [] : candidates
        lock.unlock()
        var seen = Set<Int64>()
        var members: [Member] = []
        // Weak loads and their possible last-owner releases occur off the lock.
        for candidate in snapshot.reversed() {
            guard !seen.contains(candidate.nativeIdentity) else { continue }
            let owner = candidate.owner
            guard !candidate.requiresActor || owner != nil,
                  let backend = candidate.backend else { continue }
            seen.insert(candidate.nativeIdentity)
            members.append(Member(identity: candidate.nativeIdentity, backend: backend, owner: owner))
        }
        return members.sorted { $0.identity == identity && $1.identity != identity }
    }

    /// Hold this original-owner allocation across derived attachment. Numeric
    /// native IDs are addresses and may be reused after the allocation dies.
    func retainedOwner() -> (any BackgroundSyncBackend, (any Actor)?)? {
        lock.lock(); let snapshot = invalidated ? [] : candidates; lock.unlock()
        for candidate in snapshot.reversed() where candidate.ownsLifecycle {
            let owner = candidate.owner
            guard !candidate.requiresActor || owner != nil,
                  let backend = candidate.backend else { continue }
            return (backend, owner)
        }
        return nil
    }

    var isAvailable: Bool {
        guard let owner = retainedOwner() else {
            // The caller contract retains the original owner. Losing it must
            // not leave borrowed native resources outside lifecycle control.
            invalidate()
            return false
        }
        return withExtendedLifetime(owner) { true }
    }

    /// Called synchronously before the original owner closes. Cancel permits
    /// first, then close borrowed native identities outside every registry lock.
    /// A queued actor hop sees its already-cancelled permit before native start.
    func beginInvalidation() -> @Sendable () -> Void {
        lock.lock()
        invalidated = true
        let retired = candidates
        candidates = []
        let active = Array(operations.values)
        lock.unlock()
        return { [identity] in
            for operation in active { operation.cancellation.cancel() }
            var closed = Set<Int64>()
            for candidate in retired where candidate.nativeIdentity != identity {
                guard !closed.contains(candidate.nativeIdentity), let backend = candidate.backend else { continue }
                closed.insert(candidate.nativeIdentity)
                backend.closeBackgroundSyncMember()
            }
            withExtendedLifetime(retired) {}
        }
    }

    func invalidate() { beginInvalidation()() }

    /// Publish removal before close can race another facade of this identity.
    /// The caller performs its ordinary backend close after cancellation.
    func beginRemovingMember(identity: Int64) -> @Sendable () -> Void {
        lock.lock()
        retiredIdentities.insert(identity)
        let retired = candidates
        candidates.removeAll { $0.nativeIdentity == identity }
        let active = Array(operations.values.filter { $0.identity == identity })
        lock.unlock()
        return {
            for operation in active { operation.cancellation.cancel() }
            withExtendedLifetime(retired) {}
        }
    }

    internal var activeOperationCount: Int { lock.withLock { operations.count } }

    private func containsMember(_ identity: Int64) -> Bool {
        lock.withLock { !invalidated && candidates.contains { $0.nativeIdentity == identity } }
    }

    var binding: BackgroundTaskBinding {
        BackgroundTaskBinding(identity: identity, isAvailable: { [self] in isAvailable }) { [self] command in
            switch try await perform(command) {
            case .completed: return .completed
            case .budgetExhausted: return .incomplete
            case .alreadyRunning, .unavailable: return .notNeeded
            }
        }
    }

    func perform(_ command: BackgroundTaskCommand) async throws -> Lattice.SyncOnceResult {
        try await commands.perform(command) { [self] in try await performAdmitted(command) }
    }

    private func performAdmitted(_ command: BackgroundTaskCommand) async throws -> Lattice.SyncOnceResult {
        guard let ownerLease = retainedOwner() else {
            invalidate()
            return .unavailable
        }
        defer { withExtendedLifetime(ownerLease) {} }
        let members = liveMembers()
        guard !members.isEmpty else { return .unavailable }
        switch command {
        case let .refresh(duration):
            let nanoseconds = duration * 1_000_000_000
            let deadline: DispatchTime = nanoseconds < Double(Int64.max / 2)
                ? .now() + .nanoseconds(Int(nanoseconds)) : .distantFuture
            guard let (ownerBackend, ownerActor) = retainedOwner() else {
                try await settleBorrowers()
                return .unavailable
            }
            let owner = Member(identity: identity, backend: ownerBackend, owner: ownerActor)
            let wasForeground = lock.withLock { foregroundRequested }
            do {
                let result = try await perform(command, member: owner, deadline: deadline)
                // This receipt means another foreground/finite session was
                // left untouched; do not suspend its local observer cohort.
                if result != .alreadyRunning && !wasForeground { try await settleBorrowers() }
                if result == .completed && DispatchTime.now() >= deadline { return .budgetExhausted }
                return result
            } catch {
                if !wasForeground { try await settleBorrowers() }
                throw error
            }
        case .resume, .suspend:
            lock.withLock {
                if case .resume = command { foregroundRequested = true } else { foregroundRequested = false }
            }
            var firstError: (any Swift.Error)?
            var anyAvailable = false
            var incomplete = false
            // One bounded snapshot. Late members start natively suspended;
            // scheduler membership revision requests any missing resume pass.
            for member in members {
                do {
                    let result = try await perform(command, member: member)
                    anyAvailable = anyAvailable || result != .unavailable
                    incomplete = incomplete || result == .budgetExhausted ||
                        (result == .unavailable && containsMember(member.identity))
                } catch { if firstError == nil { firstError = error } }
            }
            if let firstError { throw firstError }
            if isInvalidated || !anyAvailable { return .unavailable }
            return incomplete ? .budgetExhausted : .completed
        }
    }

    private func settleBorrowers() async throws {
        var firstError: (any Swift.Error)?
        for member in liveMembers() where member.identity != identity {
            do {
                let result = try await perform(.suspend, member: member)
                if result != .completed && containsMember(member.identity) {
                    throw Lattice.Error.databaseError("A derived background store did not confirm suspension.")
                }
            } catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }

    private func perform(_ command: BackgroundTaskCommand, member: Member,
                         deadline: DispatchTime? = nil) async throws -> Lattice.SyncOnceResult {
        let cancellation = SyncWorkCancellation()
        let key = UUID()
        let admitted = lock.withLock {
            let admitted = !invalidated && candidates.contains { $0.nativeIdentity == member.identity }
            if admitted { operations[key] = Operation(identity: member.identity, cancellation: cancellation) }
            return admitted
        }
        guard admitted else { return .unavailable }
        defer {
            let retired = lock.withLock { operations.removeValue(forKey: key) }
            withExtendedLifetime(retired) {}
        }
        return try await Self.perform(command, backend: member.backend, cancellation: cancellation,
                                      deadline: deadline, isolation: member.owner)
    }

    private static func perform(
        _ command: BackgroundTaskCommand,
        backend: any BackgroundSyncBackend,
        cancellation: SyncWorkCancellation,
        deadline: DispatchTime?,
        isolation: isolated (any Actor)?
    ) async throws -> Lattice.SyncOnceResult {
        isolation?.preconditionIsolated()
        return try await withTaskCancellationHandler {
            let result = try await Task.detached {
                defer { cancellation.clearHandler() }
                if case .suspend = command {} else if cancellation.isCancelled { throw CancellationError() }
                var admittedCommand = command
                if case .refresh = command, let deadline {
                    let now = DispatchTime.now()
                    guard now < deadline else { return Lattice.SyncOnceResult.budgetExhausted }
                    admittedCommand = .refresh(duration: TimeInterval(deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000_000)
                }
                return try backend.performBackgroundSync(admittedCommand, cancellation: cancellation)
            }.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            cancellation.cancel()
        }
    }
}

/// One queue serves both the app's manual finite calls and the automatic
/// lifecycle. A foreground transition cancels and settles a manual attempt
/// before claiming continuous sync, instead of mistaking it for that session.
private actor BackgroundSyncCommandQueue {
    private var revision: UInt64 = 0
    private var active: Task<Lattice.SyncOnceResult, any Swift.Error>?

    func perform(
        _ command: BackgroundTaskCommand,
        operation: @escaping @Sendable () async throws -> Lattice.SyncOnceResult
    ) async throws -> Lattice.SyncOnceResult {
        if case .refresh = command, active != nil { return .alreadyRunning }
        revision &+= 1
        let request = revision
        if let previous = active {
            previous.cancel()
            _ = await previous.result
            guard revision == request else { return .unavailable }
        }
        active = nil
        // Suspension must finish even when its caller loses its execution
        // assertion; other cancelled commands must not begin new work.
        if case .suspend = command {} else { try Task.checkCancellation() }
        let work = Task { try await operation() }
        active = work
        defer { if revision == request { active = nil } }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }
}

internal enum BackgroundSyncBindings {
    private final class WeakBackend {
        let identity: ObjectIdentifier
        weak var value: (any BackgroundSyncBackend)?
        init(_ value: any BackgroundSyncBackend) { self.value = value; identity = ObjectIdentifier(value) }
    }
    private final class WeakGroup {
        weak var value: BackgroundSyncBindingGroup?
        let backends: [WeakBackend]
        init(_ value: BackgroundSyncBindingGroup, backends: [WeakBackend]) {
            self.value = value
            self.backends = backends
        }
    }
    private static let lock = NSLock()
    private nonisolated(unsafe) static var groups: [Int64: WeakGroup] = [:]

    /// Alias lifetime follows native facade candidates, not the longer-lived
    /// owner lineage. Probe weak values outside the registry lock: a last
    /// temporary backend release can run arbitrary native teardown.
    private static func pruneAliases() {
        lock.lock(); let snapshot = groups; lock.unlock()
        let inspected = snapshot.map { identity, entry in
            (identity, entry, entry.value, entry.backends.filter { $0.value != nil })
        }
        var expired: [(Int64, BackgroundSyncBindingGroup)] = []
        lock.lock()
        for (identity, entry, group, live) in inspected where groups[identity] === entry {
            if let group, !live.isEmpty {
                if live.count != entry.backends.count { groups[identity] = WeakGroup(group, backends: live) }
            } else {
                groups.removeValue(forKey: identity)
                if let group { expired.append((identity, group)) }
            }
        }
        lock.unlock()
        for (identity, group) in expired { group.pruneExpiredCandidates(forgetRetiredIdentity: identity) }
        var pruned = Set<ObjectIdentifier>()
        for (_, _, group, _) in inspected {
            if let group, pruned.insert(ObjectIdentifier(group)).inserted { group.pruneExpiredCandidates() }
        }
    }

    static func attach(
        backend: any LatticeBackend,
        isolation: isolated (any Actor)?
    ) throws -> BackgroundSyncBindingGroup {
        guard let capability = backend as? any BackgroundSyncBackend else {
            throw Lattice.Error.databaseError("This backend does not support finite background sync.")
        }
        return try attachManaged(capability: capability, owner: isolation, lineage: nil, ownsLifecycle: false)
    }

    static func attach(
        capability: any BackgroundSyncBackend,
        isolation: isolated (any Actor)?
    ) throws -> BackgroundSyncBindingGroup {
        try attachManaged(capability: capability, owner: isolation, lineage: nil, ownsLifecycle: false)
    }

    static func attachManaged(
        backend: any LatticeBackend,
        owner: (any Actor)?,
        lineage: BackgroundSyncLineage,
        ownsLifecycle: Bool
    ) throws -> BackgroundSyncBindingGroup {
        guard let capability = backend as? any BackgroundSyncBackend else {
            throw Lattice.Error.databaseError("This backend cannot join managed background lifecycle.")
        }
        return try attachManaged(capability: capability, owner: owner, lineage: lineage, ownsLifecycle: ownsLifecycle)
    }

    static func attachManaged(
        capability: any BackgroundSyncBackend,
        owner: (any Actor)?,
        lineage: BackgroundSyncLineage?,
        ownsLifecycle: Bool
    ) throws -> BackgroundSyncBindingGroup {
        pruneAliases()
        let inheritedBeforeLock = lineage?.current
        let retainedOwner = ownsLifecycle ? nil : inheritedBeforeLock?.retainedOwner()
        if !ownsLifecycle, lineage != nil, retainedOwner == nil {
            inheritedBeforeLock?.invalidate()
            throw Lattice.Error.databaseError("A derived background handle requires its original store owner to remain alive.")
        }
        defer { withExtendedLifetime(retainedOwner) {} }
        let identity = capability.identityHash
        lock.lock()
        let existingEntry = groups[identity]
        let existing = existingEntry?.value
        let inherited = lineage?.current
        let group = inherited ?? existing ?? BackgroundSyncBindingGroup(identity: identity)
        do {
            guard !group.isInvalidated else {
                throw Lattice.Error.databaseError("This background store lineage has been closed.")
            }
            guard existing == nil || existing === group else {
                throw Lattice.Error.databaseError("A native store identity cannot belong to two background lineages.")
            }
            guard !ownsLifecycle || group.identity == identity else {
                throw Lattice.Error.databaseError("A derived local handle cannot replace its background task owner.")
            }
            try lineage?.bind(group)
            groups[identity] = WeakGroup(group, backends:
                (existingEntry?.backends ?? []).filter { $0.identity != ObjectIdentifier(capability) } + [WeakBackend(capability)])
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        let added = try group.add(backend: capability, owner: owner,
            ownsLifecycle: ownsLifecycle || (lineage == nil && existing == nil))
        if added { BackgroundTaskScheduler.shared.membersDidChange(identity: group.identity) }
        return group
    }

    static func invalidate(identity: Int64) {
        lock.lock()
        let retired = groups[identity]?.value
        let finish: (@Sendable () -> Void)?
        if let retired, retired.identity == identity {
            finish = retired.beginInvalidation()
        } else {
            finish = retired?.beginRemovingMember(identity: identity)
        }
        // Keep weak tombstones until the lineage dies. A close-racing native
        // cache hit must not be silently adopted by a fresh family.
        lock.unlock()
        finish?()
        guard let retired else { return }
        if retired.identity == identity {
            BackgroundTaskScheduler.shared.invalidate(identity: identity)
        } else {
            BackgroundTaskScheduler.shared.membersDidChange(identity: retired.identity)
        }
    }
}
