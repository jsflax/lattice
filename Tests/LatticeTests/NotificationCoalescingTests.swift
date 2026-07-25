import Foundation
import Testing
@testable import Lattice

/// Pins the coalesced cross-instance notification path (issue #4): bulk row
/// updates must NOT spawn one Task per (property-change × live observer).
/// A single drainer walks the pending buffer in commit order; per-burst
/// (instance, property) merges are lossless because observers read current
/// state at delivery time.
@Suite("Notification coalescing (issue #4)", .serialized)
struct NotificationCoalescingTests {

    @Model final class CoalescePerson {
        var name: String = ""
        var age: Int = 0
        init() {}
    }

    /// The headline pin: a bulk update across many live-observed rows
    /// schedules a bounded number of drain tasks — not one Task per
    /// notification. Before the fix this shape spawned rows × observers
    /// Tasks (tens of thousands in the field repro).
    @Test(.timeLimit(.minutes(2)))
    @MainActor
    func bulkUpdate_boundedDrainTasks_allObserversDeliver() async throws {
        let dbName = "coalesce_bulk_\(UUID().uuidString).sqlite"
        let fileURL = FileManager.default.temporaryDirectory.appending(path: dbName)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        // MainActor-created lattice: its models carry MainActor isolation, so
        // deliveries take the coalesced-drainer path (the field shape —
        // @LatticeQuery models live on the main actor).
        let lattice = try Lattice(CoalescePerson.self, configuration: .init(fileURL: fileURL))
        var writers: [CoalescePerson] = []
        for i in 0..<200 {
            let p = CoalescePerson()
            p.name = "p\(i)"
            p.age = i
            try lattice.add(p)
            writers.append(p)
        }

        // Distinct Swift instances for the same rows are the observation
        // targets — the "rows the UI is showing" side.
        let fired = FiredBox()
        var observed: [CoalescePerson] = []
        var cancellables: [Any] = []
        for writer in writers {
            let pk = writer.primaryKey!
            let twin = lattice.object(CoalescePerson.self, primaryKey: pk)!
            #expect(twin !== writer)
            cancellables.append(twin.observe { _ in fired.insert(Int(pk)) })
            observed.append(twin)
        }

        let baseline = ModelInstanceRegistry.shared._drainTasksScheduledForTesting

        try lattice.transaction {
            for writer in writers {
                writer.age += 1000
            }
        }

        // All 200 observed twins must hear about their row.
        let deadline = ContinuousClock.now + .seconds(30)
        while fired.count < 200 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(fired.count == 200, "every live twin's observer fires (got \(fired.count))")

        // The pin: 200 row updates → a handful of drain tasks, not hundreds.
        // No lower bound: under parallel suites another burst's drainer may
        // already be live, in which case these entries ride it and ZERO new
        // tasks are scheduled — that's the design working, not a miss.
        let drains = ModelInstanceRegistry.shared._drainTasksScheduledForTesting - baseline
        #expect(drains <= 20, "coalescer scheduled \(drains) drain tasks for 200 notifications")

        withExtendedLifetime(observed) {}
        withExtendedLifetime(cancellables) {}
    }

    /// Non-isolated targets still deliver asynchronously — notifyChange can
    /// fire from inside the C++ commit hook where the writing setter's
    /// exclusive-access scope is live, so a synchronous send is an
    /// exclusivity violation. But they ride the SAME single drainer: the
    /// delivery arrives, and no per-notification Task is spawned.
    @Test(.timeLimit(.minutes(2)))
    func nilIsolation_deliversViaDrainerWithoutTaskStorm() async throws {
        let dbName = "coalesce_sync_\(UUID().uuidString).sqlite"
        let fileURL = FileManager.default.temporaryDirectory.appending(path: dbName)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        // Handle created off-actor: isolation is nil.
        let lattice = try Lattice(CoalescePerson.self, configuration: .init(fileURL: fileURL))
        let p1 = CoalescePerson()
        p1.name = "sync"
        try lattice.add(p1)

        let p2 = lattice.object(CoalescePerson.self, primaryKey: p1.primaryKey!)!
        #expect(p1 !== p2)

        let fired = FiredBox()
        let c = p2.observe { _ in fired.insert(0) }
        let baseline = ModelInstanceRegistry.shared._drainTasksScheduledForTesting

        p1.age = 41

        let deadline = ContinuousClock.now + .seconds(30)
        while fired.count < 1 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(fired.count == 1, "nil-isolation delivery arrives via the drainer")
        let drains = ModelInstanceRegistry.shared._drainTasksScheduledForTesting - baseline
        #expect(drains <= 2, "one write → at most a couple of drain tasks (got \(drains))")
        withExtendedLifetime(c) {}
    }

    /// A merged delivery is lossless: rapid writes to the same property may
    /// coalesce into fewer callbacks, but the observer always reads the
    /// LATEST committed value when it fires.
    @Test(.timeLimit(.minutes(2)))
    @MainActor
    func coalescedDelivery_readsLatestState() async throws {
        let dbName = "coalesce_latest_\(UUID().uuidString).sqlite"
        let fileURL = FileManager.default.temporaryDirectory.appending(path: dbName)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let lattice = try Lattice(CoalescePerson.self, configuration: .init(fileURL: fileURL))
        let writer = CoalescePerson()
        writer.name = "latest"
        try lattice.add(writer)

        let twin = lattice.object(CoalescePerson.self, primaryKey: writer.primaryKey!)!
        #expect(twin !== writer)

        let lastSeen = FiredBox()
        let c = twin.observe { [weak twin] _ in
            lastSeen.insert(twin?.age ?? -1)
        }

        for value in 1...50 {
            writer.age = value
        }

        let deadline = ContinuousClock.now + .seconds(30)
        while lastSeen.count == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        // Give any trailing coalesced deliveries a beat to land, then check
        // the final observation reflects the final write.
        try await Task.sleep(for: .milliseconds(500))
        #expect(lastSeen.last == 50, "final delivery observes the latest committed value (saw \(String(describing: lastSeen.last)))")
        withExtendedLifetime(c) {}
        withExtendedLifetime(twin) {}
    }
}

/// Thread-safe accumulator for observer callbacks (they fire on arbitrary
/// isolation).
private final class FiredBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    private var unique: Set<Int> = []

    func insert(_ v: Int) {
        lock.lock()
        values.append(v)
        unique.insert(v)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return unique.count
    }

    var last: Int? {
        lock.lock()
        defer { lock.unlock() }
        return values.last
    }
}
