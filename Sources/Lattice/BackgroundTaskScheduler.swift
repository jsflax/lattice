import Foundation
#if canImport(os)
import os
#endif
#if os(iOS) && canImport(BackgroundTasks) && canImport(UIKit)
@preconcurrency import BackgroundTasks
import UIKit
#endif

// The scheduler owns Apple task lifetimes. The store binding owns native work,
// including cancellation and settlement, on the store's original actor.
internal enum BackgroundTaskCommand: Sendable, Equatable {
    case refresh(duration: TimeInterval)
    case resume
    case suspend
}

internal enum BackgroundTaskOutcome: Sendable, Equatable {
    case completed
    case incomplete
    case notNeeded
}

internal struct BackgroundTaskBinding: Sendable {
    let identity: Int64
    let isAvailable: @Sendable () -> Bool
    let operation: @Sendable @isolated(any) (BackgroundTaskCommand) async throws -> BackgroundTaskOutcome

    init(identity: Int64,
         isAvailable: @escaping @Sendable () -> Bool,
         @_inheritActorContext operation: @escaping @Sendable @isolated(any)
            (BackgroundTaskCommand) async throws -> BackgroundTaskOutcome) {
        self.identity = identity
        self.isAvailable = isAvailable
        self.operation = operation
    }
}

internal enum BackgroundTaskSchedulerError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedPlatform
    case applicationExtensionUnsupported
    case backgroundFetchNotEnabled
    case conflictingPolicy(String)
    case registrationRejected(String)
    case identifierNotRegistered(String)
    case conflictingStore(String)
    case storeAlreadyBound(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform: return "Lattice background task scheduling is supported only by iOS apps."
        case .applicationExtensionUnsupported: return "Register Lattice background sync in the host app, not its extension."
        case .backgroundFetchNotEnabled: return "Enable the fetch background mode before registering Lattice background sync."
        case let .conflictingPolicy(id): return "Background task '\(id)' already has a different policy."
        case let .registrationRejected(id): return "The system rejected registration of background task '\(id)'."
        case let .identifierNotRegistered(id): return "Register background task '\(id)' before binding its store."
        case let .conflictingStore(id): return "Background task '\(id)' is already bound to another live store."
        case let .storeAlreadyBound(id): return "This store is already bound to background task '\(id)'."
        }
    }
}

internal enum BackgroundTaskLifecycleEvent: Sendable {
    case active
    case inactive
    case background
    case protectedDataAvailable
    case protectedDataUnavailable
}

@MainActor
internal protocol BackgroundTaskDelivery: AnyObject {
    var identifier: String { get }
    var expirationHandler: (@Sendable () -> Void)? { get set }
    func complete(success: Bool)
}

@MainActor
internal protocol BackgroundTaskCleanupAssertion: AnyObject {
    func end()
}

internal struct BackgroundTaskPendingRequest: Sendable, Equatable {
    let identifier: String
    let earliestBeginDate: Date?
}

internal enum BackgroundTaskSubmission: Sendable, Equatable {
    case submitted
    case preservedExisting(identifier: String)
}

/// All Apple interaction is injectable; the registry and driver run on macOS in
/// tests without importing UIKit or manufacturing BGTask instances.
internal struct BackgroundTaskSchedulerHooks: Sendable {
    var permittedIdentifiers: Set<String>
    var registrationError: BackgroundTaskSchedulerError?
    var register: @Sendable (String, @escaping @MainActor @Sendable (any BackgroundTaskDelivery) -> Void) -> Bool
    var observe: @Sendable (@escaping @MainActor @Sendable (BackgroundTaskLifecycleEvent) -> Void) -> any Sendable
    var pendingRequests: @Sendable () async -> [BackgroundTaskPendingRequest]
    var submit: @Sendable (BackgroundTaskPendingRequest) async throws -> Void
    var beginCleanup: @MainActor @Sendable (@escaping @Sendable () -> Void) -> (any BackgroundTaskCleanupAssertion)?
    var now: @Sendable () -> Date = { Date() }
    var report: @Sendable (String) -> Void = { message in
        #if canImport(os)
        Logger(subsystem: "lattice.io", category: "sync").error("\(message, privacy: .public)")
        #else
        print("[Lattice background sync] \(message)")
        #endif
    }
}

/// Cancellation can arrive on Apple's expiration queue before the Swift task
/// exists. Latch it synchronously and never report completion from this path.
internal final class BackgroundTaskCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var cancelOperation: (@Sendable () -> Void)?

    var isCancelled: Bool { lock.withLock { cancelled } }

    func install(_ operation: @escaping @Sendable () -> Void) {
        let (shouldCancel, retired) = lock.withLock {
            let retired = cancelOperation
            cancelOperation = operation
            return (cancelled, retired)
        }
        withExtendedLifetime(retired) {}
        if shouldCancel { operation() }
    }

    func cancel() {
        let operation = lock.withLock {
            cancelled = true
            return cancelOperation
        }
        operation?()
    }

    func clear() {
        let retired = lock.withLock {
            let retired = cancelOperation
            cancelOperation = nil
            return retired
        }
        withExtendedLifetime(retired) {}
    }
}

/// Serializes read/replace decisions across identifiers, including across await
/// points. A failed submission never removes an already pending opportunity.
internal actor BackgroundTaskSubmitter {
    private let hooks: BackgroundTaskSchedulerHooks
    private var tail: Task<Void, Never>?

    init(hooks: BackgroundTaskSchedulerHooks) { self.hooks = hooks }

    func schedule(identifier: String, minimumInterval: TimeInterval) async throws -> BackgroundTaskSubmission {
        let previous = tail
        let hooks = self.hooks
        let request = BackgroundTaskPendingRequest(
            identifier: identifier, earliestBeginDate: hooks.now().addingTimeInterval(minimumInterval))
        let operation = Task {
            await previous?.value
            let pending = await hooks.pendingRequests()
            // iOS permits only one pending app-refresh request app-wide. Never
            // cancel or displace another owner's request to claim that slot.
            if let other = pending.first(where: { $0.identifier != identifier }) {
                return BackgroundTaskSubmission.preservedExisting(identifier: other.identifier)
            }
            if let existing = pending.first(where: { $0.identifier == identifier }),
               existing.earliestBeginDate == nil ||
                existing.earliestBeginDate! <= request.earliestBeginDate! {
                return BackgroundTaskSubmission.preservedExisting(identifier: identifier)
            }
            try await hooks.submit(request)
            return BackgroundTaskSubmission.submitted
        }
        tail = Task { _ = try? await operation.value }
        return try await operation.value
    }
}

/// The lock protects process registration and binding identity only. It never
/// encloses Apple calls, availability probes, actor hops, or native store work.
internal final class BackgroundTaskScheduler: @unchecked Sendable {
    static let shared = BackgroundTaskScheduler(hooks: .live)

    internal struct Snapshot: Sendable {
        let policy: Lattice.Configuration.BackgroundSync
        let revision: UInt64
        let generation: UInt64
        let binding: BackgroundTaskBinding?
    }

    private enum Registration {
        case registering(Lattice.Configuration.BackgroundSync)
        case registered(Snapshot)
    }

    private let condition = NSCondition()
    private var registrations: [String: Registration] = [:]
    private var nextGeneration: UInt64 = 0
    private let hooks: BackgroundTaskSchedulerHooks
    private let submitter: BackgroundTaskSubmitter
    private let refreshDuration: TimeInterval
    private var observation: (any Sendable)?
    @MainActor private lazy var driver = BackgroundTaskDriver(scheduler: self, hooks: hooks,
                                                             refreshDuration: refreshDuration)

    init(hooks: BackgroundTaskSchedulerHooks, refreshDuration: TimeInterval = 20) {
        self.hooks = hooks
        self.submitter = BackgroundTaskSubmitter(hooks: hooks)
        self.refreshDuration = refreshDuration
        // Install synchronously, before registration or lazy store opening can
        // miss the launch notification. Observation itself never opens a store.
        self.observation = hooks.observe { [weak self] event in self?.driver.observe(event) }
    }

    func register(policy: Lattice.Configuration.BackgroundSync) throws {
        if let error = hooks.registrationError { throw error }
        try policy.validate(permittedIdentifiers: hooks.permittedIdentifiers)
        let identifier = policy.taskIdentifier
        condition.lock()
        while let existing = registrations[identifier] {
            switch existing {
            case let .registered(snapshot):
                condition.unlock()
                guard snapshot.policy == policy else {
                    throw BackgroundTaskSchedulerError.conflictingPolicy(identifier)
                }
                return
            case let .registering(existingPolicy):
                guard existingPolicy == policy else {
                    condition.unlock()
                    throw BackgroundTaskSchedulerError.conflictingPolicy(identifier)
                }
                condition.wait()
            }
        }
        registrations[identifier] = .registering(policy)
        condition.unlock()

        let accepted = hooks.register(identifier) { [weak self] delivery in
            guard let self else { delivery.complete(success: false); return }
            self.driver.receive(delivery)
        }

        condition.lock()
        if accepted {
            nextGeneration &+= 1
            registrations[identifier] = .registered(Snapshot(policy: policy,
                revision: nextGeneration, generation: nextGeneration, binding: nil))
        } else {
            registrations.removeValue(forKey: identifier)
        }
        condition.broadcast()
        condition.unlock()
        guard accepted else { throw BackgroundTaskSchedulerError.registrationRejected(identifier) }
    }

    /// Must run before a successful Lattice initializer returns. Replacing a
    /// binding is allowed for the same native identity, or after its weak group
    /// has no live candidates. The caller supplies that stable candidate group.
    func bind(identifier: String, binding: BackgroundTaskBinding) throws {
        while true {
            condition.lock()
            guard case let .registered(prior) = registrations[identifier] else {
                condition.unlock()
                throw BackgroundTaskSchedulerError.identifierNotRegistered(identifier)
            }
            let revision = nextGeneration
            let peers: [(String, BackgroundTaskBinding)] = registrations.compactMap { key, value in
                guard key != identifier, case let .registered(snapshot) = value,
                      let peer = snapshot.binding, peer.identity == binding.identity else { return nil }
                return (key, peer)
            }
            condition.unlock()
            let priorIsAvailable = prior.binding?.isAvailable() ?? false
            let conflicts = prior.binding.map { $0.identity != binding.identity && priorIsAvailable } ?? false
            let otherOwner = peers.first { $0.1.isAvailable() }?.0
            condition.lock()
            guard case let .registered(current) = registrations[identifier],
                  nextGeneration == revision else {
                condition.unlock()
                continue
            }
            if let otherOwner {
                condition.unlock()
                throw BackgroundTaskSchedulerError.storeAlreadyBound(otherOwner)
            }
            guard !conflicts else {
                condition.unlock()
                throw BackgroundTaskSchedulerError.conflictingStore(identifier)
            }
            nextGeneration &+= 1
            let generation = priorIsAvailable && current.binding?.identity == binding.identity
                ? current.generation : nextGeneration
            registrations[identifier] = .registered(Snapshot(policy: current.policy,
                revision: nextGeneration, generation: generation, binding: binding))
            condition.unlock()
            Task { @MainActor [weak self] in self?.driver.reconcile(identifier) }
            return
        }
    }

    /// Retire synchronously before close/logout. Queued MainActor work reads
    /// the current generation, so it cannot reattach the retired store later.
    func invalidate(identity: Int64) {
        condition.lock()
        var changed: [String] = []
        for (identifier, registration) in registrations {
            guard case let .registered(current) = registration,
                  current.binding?.identity == identity else { continue }
            nextGeneration &+= 1
            registrations[identifier] = .registered(Snapshot(policy: current.policy,
                revision: nextGeneration, generation: nextGeneration, binding: nil))
            changed.append(identifier)
        }
        condition.unlock()
        for identifier in changed {
            Task { @MainActor [weak self] in self?.driver.reconcile(identifier) }
        }
    }

    /// A borrowed native handle joined or left the existing store lineage.
    /// Reapply local lifecycle state without invalidating a live BG delivery.
    func membersDidChange(identity: Int64) {
        condition.lock()
        var changed: [String] = []
        for (identifier, registration) in registrations {
            guard case let .registered(current) = registration,
                  current.binding?.identity == identity else { continue }
            nextGeneration &+= 1
            registrations[identifier] = .registered(Snapshot(policy: current.policy,
                revision: nextGeneration, generation: current.generation, binding: current.binding))
            changed.append(identifier)
        }
        condition.unlock()
        for identifier in changed {
            Task { @MainActor [weak self] in self?.driver.reconcile(identifier) }
        }
    }

    func snapshot(_ identifier: String) -> Snapshot? {
        condition.lock()
        defer { condition.unlock() }
        guard case let .registered(snapshot) = registrations[identifier] else { return nil }
        return snapshot
    }

    func identifiers() -> [String] {
        condition.lock()
        defer { condition.unlock() }
        return registrations.compactMap { key, value in
            if case .registered = value { return key }; return nil
        }
    }

    func schedule(_ identifier: String) async {
        guard let snapshot = snapshot(identifier) else { return }
        do {
            _ = try await submitter.schedule(identifier: identifier,
                                             minimumInterval: snapshot.policy.minimumInterval)
        } catch {
            hooks.report("Could not schedule Lattice background sync '\(identifier)': \(error)")
        }
    }

    // Deterministic seams also used by the Apple notification/launch adapters.
    @MainActor func receive(_ delivery: any BackgroundTaskDelivery) { driver.receive(delivery) }
    @MainActor func observe(_ event: BackgroundTaskLifecycleEvent) { driver.observe(event) }
    @MainActor func settleForTesting() async { await driver.settle() }
}

private extension Lattice.Configuration.BackgroundSync {
    var taskIdentifier: String { switch self { case let .appRefresh(identifier, _): identifier } }
    var minimumInterval: TimeInterval { switch self { case let .appRefresh(_, interval): interval } }
}

@MainActor
private final class BackgroundTaskSession {
    let delivery: any BackgroundTaskDelivery
    let cancellation = BackgroundTaskCancellation()
    private var completed = false

    init(_ delivery: any BackgroundTaskDelivery) {
        self.delivery = delivery
        let cancellation = self.cancellation
        delivery.expirationHandler = { cancellation.cancel() }
    }

    func finish(success: Bool) {
        guard !completed else { return }
        completed = true
        cancellation.clear()
        delivery.expirationHandler = nil
        delivery.complete(success: success && !cancellation.isCancelled)
    }
}

@MainActor
private final class BackgroundTaskDriver {
    private enum Desired { case unknown, foreground, suspended }
    private final class Entry {
        var generation: UInt64?
        var revision: UInt64?
        var applied: Desired?
        var worker: Task<Void, Never>?
        var command: Task<BackgroundTaskOutcome, any Error>?
        var commandKind: BackgroundTaskCommand?
        var session: BackgroundTaskSession?
        var assertion: (any BackgroundTaskCleanupAssertion)?
        var assertionCancellation: BackgroundTaskCancellation?
    }

    private weak var scheduler: BackgroundTaskScheduler?
    private let hooks: BackgroundTaskSchedulerHooks
    private let refreshDuration: TimeInterval
    private var desired = Desired.unknown
    private var protectedDataAvailable = true
    private var entries: [String: Entry] = [:]

    init(scheduler: BackgroundTaskScheduler, hooks: BackgroundTaskSchedulerHooks, refreshDuration: TimeInterval) {
        self.scheduler = scheduler
        self.hooks = hooks
        self.refreshDuration = refreshDuration
    }

    func reconcile(_ identifier: String) {
        guard let scheduler else { return }
        let entry = entries[identifier] ?? Entry()
        entries[identifier] = entry
        let snapshot = scheduler.snapshot(identifier)
        if entry.generation != snapshot?.generation {
            entry.command?.cancel()
            entry.applied = nil
        } else if entry.revision != snapshot?.revision {
            entry.applied = nil
        }
        start(identifier, entry)
    }

    func receive(_ delivery: any BackgroundTaskDelivery) {
        let session = BackgroundTaskSession(delivery)
        guard let scheduler else { session.finish(success: false); return }
        let identifier = delivery.identifier
        Task { await scheduler.schedule(identifier) }
        let entry = entries[identifier] ?? Entry()
        entries[identifier] = entry
        guard entry.session == nil else {
            session.finish(success: false)
            return
        }
        entry.session = session
        start(identifier, entry)
    }

    func observe(_ event: BackgroundTaskLifecycleEvent) {
        guard let scheduler else { return }
        let previous = desired
        switch event {
        case .active: desired = .foreground
        case .background: desired = .suspended
        case .inactive: return // A call, alert, or scene transition is not suspension.
        case .protectedDataAvailable: protectedDataAvailable = true
        case .protectedDataUnavailable: protectedDataAvailable = false
        }
        for identifier in scheduler.identifiers() {
            let entry = entries[identifier] ?? Entry()
            entries[identifier] = entry
            let target: Desired = protectedDataAvailable ? desired : .suspended
            switch entry.commandKind {
            case .refresh where target == .foreground || !protectedDataAvailable:
                entry.command?.cancel()
            case .resume where target != .foreground:
                entry.command?.cancel()
            case .suspend where target == .foreground:
                entry.command?.cancel()
            default:
                break
            }
            if event == .protectedDataAvailable { entry.applied = nil }
            if desired == .suspended, previous != .suspended, entry.session == nil,
               scheduler.snapshot(identifier)?.binding != nil {
                let cancellation = BackgroundTaskCancellation()
                entry.assertionCancellation = cancellation
                entry.assertion = hooks.beginCleanup { cancellation.cancel() }
            }
            if desired == .suspended { Task { await scheduler.schedule(identifier) } }
            start(identifier, entry)
        }
    }

    private func start(_ identifier: String, _ entry: Entry) {
        guard entry.worker == nil else { return }
        entry.worker = Task { await self.run(identifier, entry) }
    }

    private func endAssertion(_ entry: Entry) {
        entry.assertionCancellation?.clear()
        entry.assertionCancellation = nil
        entry.assertion?.end()
        entry.assertion = nil
    }

    private func run(_ identifier: String, _ entry: Entry) async {
        defer { entry.worker = nil }
        guard let scheduler else {
            entry.session?.finish(success: false)
            entry.session = nil
            endAssertion(entry)
            return
        }
        while true {
            let snapshot = scheduler.snapshot(identifier)
            if entry.generation != snapshot?.generation {
                entry.generation = snapshot?.generation
                entry.applied = nil
            }
            if entry.revision != snapshot?.revision {
                entry.revision = snapshot?.revision
                entry.applied = nil
            }
            guard let snapshot, let binding = snapshot.binding, binding.isAvailable() else {
                entry.session?.finish(success: false)
                entry.session = nil
                endAssertion(entry)
                return
            }
            let target: Desired = protectedDataAvailable ? desired : .suspended
            let session = entry.session
            let command: BackgroundTaskCommand
            if let session {
                if session.cancellation.isCancelled || target == .foreground || !protectedDataAvailable {
                    session.finish(success: false)
                    entry.session = nil
                    continue
                }
                command = .refresh(duration: refreshDuration)
            } else if target == .foreground, entry.applied != .foreground {
                endAssertion(entry)
                command = .resume
            } else if target == .suspended, entry.applied != .suspended {
                command = .suspend
            } else {
                endAssertion(entry)
                return
            }

            let task = Task { try await binding.operation(command) }
            entry.command = task
            entry.commandKind = command
            session?.cancellation.install { task.cancel() }
            entry.assertionCancellation?.install { task.cancel() }
            let result: BackgroundTaskOutcome
            do { result = try await task.value }
            catch {
                result = .incomplete
                if !(error is CancellationError) {
                    hooks.report("Lattice background sync '\(identifier)' failed: \(error)")
                }
            }
            entry.command = nil
            entry.commandKind = nil
            let current = scheduler.snapshot(identifier)
            let isCurrent = current?.generation == snapshot.generation
            let hasCurrentMembers = current?.revision == snapshot.revision
            if let session {
                // The binding must finish cleanup on every return/throw path.
                // Expiration merely cancels; only this settled path completes.
                session.finish(success: result == .completed && !task.isCancelled && isCurrent)
                entry.session = nil
            }
            if isCurrent && hasCurrentMembers {
                switch command {
                // Finite work returns only after settlement, including an
                // unconfirmed/budget outcome. Lifecycle failures do not prove
                // their requested state was established.
                case .refresh: entry.applied = .suspended
                case .suspend: entry.applied = result == .incomplete ? nil : .suspended
                case .resume:
                    // A foreground/background/foreground race can cancel an
                    // obsolete resume while foreground is desired again.
                    // Cancellation did not establish that desired state.
                    entry.applied = task.isCancelled || result == .incomplete ? nil : .foreground
                }
            }
            endAssertion(entry)
            if case .refresh = command { continue }
            if isCurrent, hasCurrentMembers, result == .incomplete, !task.isCancelled,
               target == (protectedDataAvailable ? desired : .suspended) {
                // Keep the state unapplied for the next lifecycle/rebind
                // event, without spinning on a persistent setup failure.
                return
            }
        }
    }

    func settle() async {
        while let worker = entries.values.compactMap(\.worker).first { await worker.value }
    }
}

#if os(iOS) && canImport(BackgroundTasks) && canImport(UIKit)
@MainActor
private final class AppleBackgroundTaskDelivery: BackgroundTaskDelivery {
    private let task: BGTask
    init(_ task: BGTask) { self.task = task }
    var identifier: String { task.identifier }
    var expirationHandler: (@Sendable () -> Void)? {
        get { nil }
        set { task.expirationHandler = newValue }
    }
    func complete(success: Bool) { task.setTaskCompleted(success: success) }
}

@MainActor
private final class AppleCleanupAssertion: BackgroundTaskCleanupAssertion {
    private weak var application: UIApplication?
    private var identifier: UIBackgroundTaskIdentifier
    init(application: UIApplication, identifier: UIBackgroundTaskIdentifier) {
        self.application = application
        self.identifier = identifier
    }
    func end() {
        guard identifier != .invalid else { return }
        application?.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

@MainActor
private final class AppleApplicationContext {
    private weak var application: UIApplication?
    nonisolated init() { }

    func observe(application observed: UIApplication?, name: Notification.Name,
                 deliver: @MainActor (BackgroundTaskLifecycleEvent) -> Void) {
        if let observed { application = observed }
        if name == UIApplication.protectedDataDidBecomeAvailableNotification {
            deliver(.protectedDataAvailable)
            return
        }
        if name == UIApplication.protectedDataWillBecomeUnavailableNotification {
            deliver(.protectedDataUnavailable)
            return
        }
        guard let application else { return }
        switch application.applicationState {
        case .active: deliver(.active)
        case .background: deliver(.background)
        case .inactive: deliver(.inactive)
        @unknown default: deliver(.inactive)
        }
    }

    func beginCleanup(expiration: @escaping @Sendable () -> Void) -> (any BackgroundTaskCleanupAssertion)? {
        guard let application else { return nil }
        let identifier = application.beginBackgroundTask(withName: "Lattice sync cleanup", expirationHandler: expiration)
        guard identifier != .invalid else { return nil }
        return AppleCleanupAssertion(application: application, identifier: identifier)
    }
}

private final class AppleLifecycleObservation: @unchecked Sendable {
    private let tokens: [NSObjectProtocol]
    init(context: AppleApplicationContext,
         deliver: @escaping @MainActor @Sendable (BackgroundTaskLifecycleEvent) -> Void) {
        let names: [Notification.Name] = [
            UIApplication.didFinishLaunchingNotification, UIApplication.didBecomeActiveNotification,
            UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
            UIApplication.willEnterForegroundNotification,
            UIApplication.protectedDataDidBecomeAvailableNotification,
            UIApplication.protectedDataWillBecomeUnavailableNotification
        ]
        tokens = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { notification in
                let application = notification.object as? UIApplication
                MainActor.assumeIsolated { context.observe(application: application, name: name, deliver: deliver) }
            }
        }
    }
    deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }
}
#endif

private extension BackgroundTaskSchedulerHooks {
    static var live: Self {
        #if os(iOS) && canImport(BackgroundTasks) && canImport(UIKit)
        let bundle = Bundle.main
        let isExtension = bundle.object(forInfoDictionaryKey: "NSExtension") != nil || bundle.bundleURL.pathExtension == "appex"
        let hasFetch = (bundle.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []).contains("fetch")
        let context = AppleApplicationContext()
        return Self(
            permittedIdentifiers: Set(bundle.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []),
            registrationError: isExtension ? .applicationExtensionUnsupported : (hasFetch ? nil : .backgroundFetchNotEnabled),
            register: { identifier, deliver in
                BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
                    MainActor.assumeIsolated { deliver(AppleBackgroundTaskDelivery(task)) }
                }
            },
            observe: { deliver in AppleLifecycleObservation(context: context, deliver: deliver) },
            pendingRequests: {
                await withCheckedContinuation { continuation in
                    BGTaskScheduler.shared.getPendingTaskRequests { requests in
                        continuation.resume(returning: requests.compactMap { request in
                            guard request is BGAppRefreshTaskRequest else { return nil }
                            return BackgroundTaskPendingRequest(identifier: request.identifier,
                                                                earliestBeginDate: request.earliestBeginDate)
                        })
                    }
                }
            },
            submit: { value in
                // iOS 27 explicitly discourages submission from the main thread.
                // Construct the non-Sendable Apple request on this worker too.
                try await Task.detached {
                    let request = BGAppRefreshTaskRequest(identifier: value.identifier)
                    request.earliestBeginDate = value.earliestBeginDate
                    #if compiler(>=6.4)
                    if #available(iOS 27, *) { try await BGTaskScheduler.shared.submitTaskRequest(request) }
                    else { try BGTaskScheduler.shared.submit(request) }
                    #else
                    // Swift 6.3's Xcode SDK does not declare the iOS 27 method.
                    try BGTaskScheduler.shared.submit(request)
                    #endif
                }.value
            },
            beginCleanup: { expiration in context.beginCleanup(expiration: expiration) })
        #else
        return Self(permittedIdentifiers: [], registrationError: .unsupportedPlatform,
                    register: { _, _ in false }, observe: { _ in false },
                    pendingRequests: { [] }, submit: { _ in throw BackgroundTaskSchedulerError.unsupportedPlatform },
                    beginCleanup: { _ in nil })
        #endif
    }
}
