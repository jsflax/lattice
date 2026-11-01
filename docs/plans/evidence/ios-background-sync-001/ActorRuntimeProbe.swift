import Foundation

private final class Store {
    var calls = 0
    func sync() { calls += 1 }
}
private enum ProbeError: Error { case storeReleased }

private struct Binding: Sendable {
    let run: @Sendable @isolated(any) () async throws -> Void
    init(@_inheritActorContext run: @escaping @Sendable @isolated(any) () async throws -> Void) {
        self.run = run
    }
}

private func bind(isolation: isolated (any Actor)? = #isolation, store: Store) -> Binding {
    Binding {
        _ = isolation
        isolation?.preconditionIsolated()
        store.sync()
    }
}

private actor AppStore {
    let store = Store()
    func makeBinding() -> Binding { bind(store: store) }
    func calls() -> Int { store.calls }
}

private struct WeakBinding: Sendable {
    let run: @Sendable @isolated(any) () async throws -> Void
    init(@_inheritActorContext run: @escaping @Sendable @isolated(any) () async throws -> Void) {
        self.run = run
    }
}

private func weakBind(isolation: isolated (any Actor)? = #isolation, store: Store) -> WeakBinding {
    WeakBinding { [weak store] in
        _ = isolation
        isolation?.preconditionIsolated()
        guard let store else { throw ProbeError.storeReleased }
        store.sync()
    }
}

private actor LifetimeOwner {
    var store: Store? = Store()
    func binding() -> WeakBinding { weakBind(store: store!) }
    func releaseStore() { store = nil }
    func calls() -> Int { store!.calls }
}

@main
private enum Probe {
    static func main() async throws {
        let first = AppStore()
        let second = AppStore()
        let firstBinding = await first.makeBinding()
        let secondBinding = await second.makeBinding()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<1000 {
                group.addTask { try await firstBinding.run() }
                group.addTask { try await secondBinding.run() }
            }
            try await group.waitForAll()
        }
        let firstCalls = await first.calls()
        let secondCalls = await second.calls()
        precondition(firstCalls == 1000 && secondCalls == 1000)
        let owner = LifetimeOwner()
        let weakBinding = await owner.binding()
        try await weakBinding.run()
        let weakCalls = await owner.calls()
        precondition(weakCalls == 1)
        await owner.releaseStore()
        do {
            try await weakBinding.run()
            fatalError("Expected released-store error")
        } catch ProbeError.storeReleased { }
        print("PASS actor isolation: 2,000 concurrent calls across two owning actors; exact 1,000 calls each")
        print("PASS weak binding: one call before release, rejected after release; no facade transfer or unchecked Sendable")
    }
}
