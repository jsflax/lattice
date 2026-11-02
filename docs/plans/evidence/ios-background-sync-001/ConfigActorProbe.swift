import Foundation
@preconcurrency import BackgroundTasks
import UIKit

// This file is a compiler/API proof only. It deliberately does not open SQLite.
struct ProbeLattice {
    struct Configuration: Sendable, Equatable, Hashable {
        enum BackgroundSync: Sendable, Equatable, Hashable {
            case appRefresh(identifier: String, minimumInterval: TimeInterval = 15 * 60)
        }
        var fileURL: URL
        var backgroundSync: BackgroundSync?
    }

    private let store: Store
    let configuration: Configuration

    init(isolation: isolated (any Actor)? = #isolation,
         configuration: Configuration) throws {
        // Runtime registration is independent of store opening and binding.
        try Self.registerBackgroundTasks(configuration: configuration)
        let store = Store() // Real implementation opens the configured backend here.
        self.store = store
        self.configuration = configuration
        if let policy = configuration.backgroundSync {
            let binding = Binding(identity: UUID()) { [weak store] command in
                // Preserve the original optional isolated parameter, not a copy.
                _ = isolation
                guard let store else { throw RegistrationError.storeReleased }
                try await store.perform(command)
            }
            Registry.shared.attach(policy: policy, binding: binding)
        }
    }

    static func registerBackgroundTasks(configuration: Configuration) throws {
        guard let policy = configuration.backgroundSync else { return }
        try Registry.shared.register(policy: policy)
    }

    func syncOnce(isolation: isolated (any Actor)? = #isolation) async throws {
        try await store.perform(.syncOnce)
    }
}

// Intentionally non-Sendable, as the public Lattice facade is non-Sendable.
private final class Store {
    var calls = 0
    func perform(_ command: Command, isolation: isolated (any Actor)? = #isolation) async throws {
        calls += 1
    }
}

private enum Command: Sendable { case resume, suspend, syncOnce }

private struct Binding: Sendable {
    let identity: UUID
    let operation: @Sendable @isolated(any) (Command) async throws -> Void

    init(identity: UUID,
         @_inheritActorContext operation: @escaping @Sendable @isolated(any) (Command) async throws -> Void) {
        self.identity = identity
        self.operation = operation
    }
}

private enum RegistrationError: Error {
    case invalidInterval
    case conflictingPolicy
    case notPermitted
    case storeReleased
}

// unchecked applies only to lock-protected registration state, never the facade.
private final class Registry: @unchecked Sendable {
    static let shared = Registry()
    private let lock = NSLock()
    private var registered: [String: ProbeLattice.Configuration.BackgroundSync] = [:]

    func register(policy: ProbeLattice.Configuration.BackgroundSync) throws {
        let identifier: String
        switch policy {
        case let .appRefresh(id, interval):
            guard interval.isFinite && interval > 0 else { throw RegistrationError.invalidInterval }
            identifier = id
        }
        lock.lock()
        defer { lock.unlock() }
        if let existing = registered[identifier] {
            guard existing == policy else { throw RegistrationError.conflictingPolicy }
            return
        }
        let accepted = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated {
                Driver.shared.deliver(task)
            }
        }
        guard accepted else { throw RegistrationError.notPermitted }
        registered[identifier] = policy
    }

    func attach(policy: ProbeLattice.Configuration.BackgroundSync, binding: Binding) {
        Task { @MainActor in
            Driver.shared.attach(policy: policy, binding: binding)
        }
    }
}

@MainActor
private final class Driver {
    static let shared = Driver()
    private var bindings: [String: Binding] = [:]

    func attach(policy: ProbeLattice.Configuration.BackgroundSync, binding: Binding) {
        switch policy {
        case let .appRefresh(identifier, _): bindings[identifier] = binding
        }
    }

    func deliver(_ task: BGTask) {
        // Not a complete task lifecycle implementation. This verifies actor hops.
        guard let binding = bindings[task.identifier] else {
            task.setTaskCompleted(success: false)
            return
        }
        Task { @MainActor in
            do {
                try await binding.operation(.syncOnce)
                task.setTaskCompleted(success: true)
            } catch {
                task.setTaskCompleted(success: false)
            }
        }
    }

    func suspend(_ identifier: String) async throws {
        guard let binding = bindings[identifier] else { return }
        try await binding.operation(.suspend)
    }
}

actor AppStore {
    private var lattice: ProbeLattice?
    func open(configuration: ProbeLattice.Configuration) throws {
        lattice = try ProbeLattice(configuration: configuration)
    }
    func refresh() async throws {
        try await lattice?.syncOnce()
    }
}

@MainActor
func eagerMainActorCaller(configuration: ProbeLattice.Configuration) throws {
    _ = try ProbeLattice(configuration: configuration)
}

@MainActor
func lazyActorCaller(configuration: ProbeLattice.Configuration, store: AppStore) throws -> Task<Void, any Error> {
    // Executes during app launch, before any asynchronous opening starts.
    try ProbeLattice.registerBackgroundTasks(configuration: configuration)
    return Task { try await store.open(configuration: configuration) }
}

private enum Submission {
    static func schedule(identifier: String, earliestBegin: Date) async throws {
        try await Task.detached {
            let request = BGAppRefreshTaskRequest(identifier: identifier)
            request.earliestBeginDate = earliestBegin
            if #available(iOS 27, *) {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
            } else {
                try BGTaskScheduler.shared.submit(request)
            }
        }.value
    }
}

@MainActor
private func installLifecycleObserver() -> NSObjectProtocol {
    NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                           object: nil, queue: .main) { _ in
        Task { @MainActor in
            _ = UIApplication.shared.applicationState
        }
    }
}
