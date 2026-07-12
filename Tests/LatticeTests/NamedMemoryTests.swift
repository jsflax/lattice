import Foundation
import Lattice
import Testing

@Model final class MemItem {
    var name: String
    init(name: String = "") { self.name = name }
}

// 1.0 item E2: .memory(named:) storage. Same-name handles share ONE
// same-process database; distinct names (including every `.memory()` default)
// are isolated; cross-handle observation delivers exactly once per write.
@Suite("Named Memory Tests", .serialized)
class NamedMemoryTests {

    @Test func sameName_sharesOneDatabase() async throws {
        let name = "shared_\(String.random(length: 16))"
        let a = try Lattice(MemItem.self, configuration: .init(storage: .memory(named: name)))
        let b = try Lattice(MemItem.self, configuration: .init(storage: .memory(named: name)))

        try a.add(MemItem(name: "from-a"))
        #expect(b.objects(MemItem.self).count == 1)
        #expect(b.objects(MemItem.self).first?.name == "from-a")
    }

    @Test func distinctNames_areIsolated() async throws {
        let a = try Lattice(MemItem.self, configuration: .init(storage: .memory(named: "iso_a_\(String.random(length: 8))")))
        let b = try Lattice(MemItem.self, configuration: .init(storage: .memory(named: "iso_b_\(String.random(length: 8))")))

        try a.add(MemItem(name: "only-in-a"))
        #expect(b.objects(MemItem.self).count == 0)
    }

    @Test func anonymousMemory_isPrivatePerConfiguration() async throws {
        // Two `.memory()` configurations mint distinct names — no accidental
        // sharing (the old global-`:memory:` registry-leak class).
        let a = try Lattice(MemItem.self, configuration: .init(storage: .memory()))
        let b = try Lattice(MemItem.self, configuration: .init(storage: .memory()))
        try a.add(MemItem(name: "private"))
        #expect(a.objects(MemItem.self).count == 1)
        #expect(b.objects(MemItem.self).count == 0)
    }

    @Test func sameConfiguration_sharesAcrossCopies() async throws {
        // ONE `.memory()` configuration VALUE reused twice shares the database
        // (the name is minted at construction, not at open).
        let config = Lattice.Configuration(storage: .memory())
        let a = try Lattice(MemItem.self, configuration: config)
        let b = try Lattice(MemItem.self, configuration: config)
        try a.add(MemItem(name: "shared-config"))
        #expect(b.objects(MemItem.self).count == 1)
    }

    /// Same-name handles opened from DIFFERENT isolation contexts (the C++
    /// ref-cache keys on scheduler identity, so this is two shared-cache
    /// connections, not a cache hit — the E1.5 hazard case).
    @Test func sameName_crossActor_twoHandles() async throws {
        let name = "xactor_\(String.random(length: 16))"
        let main = try Lattice(MemItem.self, configuration: .init(storage: .memory(named: name)))
        try main.add(MemItem(name: "from-main"))

        let count = try await Task.detached {
            let bg = try Lattice(MemItem.self, configuration: .init(storage: .memory(named: name)))
            return bg.objects(MemItem.self).count
        }.value
        #expect(count == 1, "cross-isolation same-name handle must see the write")
    }

    @Test func crossHandleObservation_deliversExactlyOnce() async throws {
        let name = "observe_\(String.random(length: 16))"
        let writer = try Lattice(MemItem.self, configuration: .init(storage: .memory(named: name)))
        let observerSide = try Lattice(MemItem.self, configuration: .init(storage: .memory(named: name)))

        let counter = ObservationCounter()
        let token = observerSide.observe(MemItem.self) { _ in
            counter.increment()
        }
        defer { _ = token }

        try writer.add(MemItem(name: "observed"))
        try await waitFor { counter.count >= 1 }
        // Catch late duplicates before asserting exactly-once.
        try await Task.sleep(for: .milliseconds(200))
        #expect(counter.count == 1, "one write must deliver exactly one notification")
    }
}

private final class ObservationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func increment() { lock.withLock { _count += 1 } }
}

private func waitFor(deadline: TimeInterval = 10, _ condition: () -> Bool) async throws {
    let start = Date()
    while !condition() {
        if Date().timeIntervalSince(start) > deadline {
            Issue.record("timed out waiting for condition")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
