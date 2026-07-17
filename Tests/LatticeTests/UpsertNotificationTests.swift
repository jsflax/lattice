import Testing
import Foundation
@testable import Lattice

// Model with an upsert key plus a separate, mutable value column so that an
// upsert on an existing key forces a real UPDATE (not DO NOTHING).
@Model final class UpsertNotify {
    @Unique(allowsUpsert: true) var key: String = ""
    var value: Int = 0
}

@Suite("Upsert Notification Tests")
final class UpsertNotificationTests: BaseTest {

    /// An upsert that resolves to an UPDATE of an existing row must surface a
    /// notification (AuditLog UPDATE entry) on `changeStream`, exactly like a
    /// plain `update` would — that's what drives `@LatticeQuery` refreshes.
    @Test func test_upsertUpdate_firesNotification() async throws {
        let lattice = try testLattice(UpsertNotify.self)

        // Seed an initial row.
        let first = UpsertNotify()
        first.key = "a"
        first.value = 1
        try lattice.add(first)
        #expect(lattice.objects(UpsertNotify.self).count == 1)

        // Wire a changeStream observer that returns as soon as it sees an
        // UPDATE audit entry for our table.
        let latticeRef = lattice.sendableReference
        let observation: Task<String?, any Error> = Task.detached {
            guard let l = latticeRef.resolve() else { return nil }
            for try await refs in l.changeStream {
                let resolved = refs.compactMap { $0.resolve(on: l) }
                if let hit = resolved.first(where: {
                    $0.tableName == "UpsertNotify" && $0.operation == .update
                }) {
                    return hit.operation.rawValue
                }
            }
            return nil
        }
        // Yield so the observer is wired before the triggering write.
        await Task.yield()

        // Upsert: same key, new value — resolves to an UPDATE of the existing row.
        let second = UpsertNotify()
        second.key = "a"
        second.value = 2
        try lattice.add(second)

        let op = try await observation.value

        // Data reflects the upsert...
        #expect(lattice.objects(UpsertNotify.self).count == 1)
        #expect(lattice.objects(UpsertNotify.self).first?.value == 2)
        // ...and the notification fired.
        #expect(op == "UPDATE",
                "Upsert that performed an UPDATE did not surface a notification on changeStream")
    }

    /// A live, managed object backing the row that an upsert conflicts with must
    /// be refreshed: its per-instance observers must fire and its value must
    /// reflect the upserted data. This is the `@Bindable var x: Model` SwiftUI
    /// case — the view bound to `first` should re-render.
    ///
    /// We wait directly on the object observer (not changeStream): the
    /// continuation resumes inside `first.observe`, so when `await` returns the
    /// observer has definitively fired — no cross-signal ordering race.
    @Test func test_upsertUpdate_refreshesLiveObject() async throws {
        let lattice = try testLattice(UpsertNotify.self)

        // Seed and keep a live managed handle to the row (registers an observer).
        let first = UpsertNotify()
        first.key = "a"
        first.value = 1
        try lattice.add(first)

        nonisolated(unsafe) var continuation: CheckedContinuation<Void, Never>?
        let token = first.observe { _ in
            continuation?.resume()
            continuation = nil
        }

        // Upsert onto the same key — UPDATEs the row that `first` represents.
        let second = UpsertNotify()
        second.key = "a"
        second.value = 2

        await withCheckedContinuation { c in
            continuation = c
            try! lattice.add(second)
        }
        token.cancel()

        // Observer fired (we got here) and the live object reflects the upsert.
        #expect(first.value == 2,
                "Live object did not refresh its value after an upsert UPDATE (read \(first.value))")
    }

    /// Same as above but via a bulk `add(contentsOf:)` upsert. The live object
    /// must be the pre-registered `first` (bulk-added transients aren't
    /// registered for observation), and the colliding batch UPDATEs its row.
    @Test func test_bulkUpsert_refreshesLiveObject() async throws {
        let lattice = try testLattice(UpsertNotify.self)

        let first = UpsertNotify()
        first.key = "a"
        first.value = 1
        try lattice.add(first)

        nonisolated(unsafe) var continuation: CheckedContinuation<Void, Never>?
        let token = first.observe { _ in
            continuation?.resume()
            continuation = nil
        }

        // Bulk batch colliding on key "a" plus a fresh row.
        let collide = UpsertNotify()
        collide.key = "a"
        collide.value = 2
        let fresh = UpsertNotify()
        fresh.key = "b"
        fresh.value = 9

        await withCheckedContinuation { c in
            continuation = c
            try! lattice.add(contentsOf: [collide, fresh])
        }
        token.cancel()

        #expect(first.value == 2,
                "Live object did not refresh after a bulk upsert UPDATE (read \(first.value))")
        #expect(lattice.objects(UpsertNotify.self).count == 2)
    }
}
