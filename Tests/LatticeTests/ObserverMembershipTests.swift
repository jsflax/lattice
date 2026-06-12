import Foundation
import Testing
@testable import Lattice

// MARK: - Filtered observation fires on result-set membership

/// Regression coverage for filtered `observe(where:)`: the observer must fire
/// when a CURRENT MEMBER of the result set mutates — including columns the
/// predicate doesn't reference — and when a row leaves the set. The old
/// implementation matched the predicate against AuditLog.changedFields, which
/// (a) never fired for member rows mutating non-predicate columns (a running
/// job's progress tick froze every observing progress bar), and (b) never
/// fired at all when auditing is disabled (no AuditLog rows to match).
@Suite("Observer Membership")
class ObserverMembershipTests: BaseTest {

    private final class FireCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        func bump() { lock.withLock { _count += 1 } }
    }

    private func waitForFire(_ counter: FireCounter, atLeast n: Int = 1,
                             timeout: Duration = .seconds(3)) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if counter.count >= n { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return counter.count >= n
    }

    @Test func firesWhenMemberRowMutatesNonPredicateColumn() async throws {
        let lattice = try testLattice(Person.self, Dog.self)
        let person = Person()
        person.name = "A"
        person.age = 30
        lattice.add(person)

        let counter = FireCounter()
        // Predicate on `age`; mutate `name` — a member row changing a column
        // the predicate doesn't mention must still re-fire the observer
        // (this is what live progress bars depend on).
        let token = lattice.objects(Person.self)
            .where { $0.age > 0 }
            .observe { _ in counter.bump() }

        person.name = "B"

        let fired = try await waitForFire(counter)
        #expect(fired, "member-row column change did not re-fire the filtered observer")
        token.cancel()
    }

    @Test func firesWhenRowLeavesTheResultSet() async throws {
        let lattice = try testLattice(Person.self, Dog.self)
        let person = Person()
        person.name = "A"
        person.age = 30
        lattice.add(person)

        let counter = FireCounter()
        let token = lattice.objects(Person.self)
            .where { $0.age > 18 }
            .observe { _ in counter.bump() }

        person.age = 10  // leaves the set — observers must hear about it

        let fired = try await waitForFire(counter)
        #expect(fired, "row leaving the result set did not fire the filtered observer")
        token.cancel()
    }

    @Test func firesOnInsertIntoTheResultSet() async throws {
        let lattice = try testLattice(Person.self, Dog.self)

        let counter = FireCounter()
        let token = lattice.objects(Person.self)
            .where { $0.age > 18 }
            .observe { _ in counter.bump() }

        let person = Person()
        person.name = "A"
        person.age = 30
        lattice.add(person)

        let fired = try await waitForFire(counter)
        #expect(fired, "insert of a matching row did not fire the filtered observer")
        token.cancel()
    }
}
