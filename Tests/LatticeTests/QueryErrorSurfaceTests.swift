import Foundation
import Testing
@testable import Lattice

// The sealed query surface (LatticeCore 1.2.4): C++ exceptions never cross
// the Swift interop boundary — a failed query returns empty/0, stashes the
// reason in a thread-local slot (lastQueryError), and fans out to the
// onQueryError handler. These tests drive a REAL db_error through the seal
// by querying a table that does not exist (prepare failure).

@Model
private class ErrItem {
    var name: String
    init(name: String = "") { self.name = name }
}

@Suite("Sealed query error surface")
final class QueryErrorSurfaceTests: BaseTest {

    @Test func failedQueryReturnsEmptyAndSetsLastQueryError() throws {
        let lattice = try testLattice(ErrItem.self)
        try lattice.add(ErrItem(name: "a"))

        // Nonexistent table → sqlite prepare fails → db_error → sealed.
        let rows = lattice.backend.objects(
            table: "NoSuchTable", where: nil, orderBy: nil,
            limit: nil, offset: nil, groupBy: nil, distinctBy: nil)
        #expect(rows.isEmpty)
        let err = lattice.lastQueryError()
        #expect(err != nil)
        #expect(err?.isEmpty == false)
    }

    @Test func successfulQueryClearsLastQueryError() throws {
        let lattice = try testLattice(ErrItem.self)
        try lattice.add(ErrItem(name: "a"))

        // Fail first (slot set) ...
        _ = lattice.backend.objects(
            table: "NoSuchTable", where: nil, orderBy: nil,
            limit: nil, offset: nil, groupBy: nil, distinctBy: nil)
        #expect(lattice.lastQueryError() != nil)

        // ... then succeed on the same thread — entry-clear must wipe it.
        let rows = lattice.backend.objects(
            table: "ErrItem", where: nil, orderBy: nil,
            limit: nil, offset: nil, groupBy: nil, distinctBy: nil)
        #expect(rows.count == 1)
        #expect(lattice.lastQueryError() == nil)
    }

    @Test func onQueryErrorFiresOnFailureNotOnSuccess() throws {
        let lattice = try testLattice(ErrItem.self)
        try lattice.add(ErrItem(name: "a"))

        let messages = LockedBox<[String]>([])
        lattice.onQueryError { msg in
            messages.withLock { $0.append(msg) }
        }

        _ = lattice.backend.objects(
            table: "ErrItem", where: nil, orderBy: nil,
            limit: nil, offset: nil, groupBy: nil, distinctBy: nil)
        #expect(messages.withLock { $0 }.isEmpty)

        _ = lattice.backend.objects(
            table: "NoSuchTable", where: nil, orderBy: nil,
            limit: nil, offset: nil, groupBy: nil, distinctBy: nil)
        let fired = messages.withLock { $0 }
        #expect(fired.count == 1)
        #expect(fired.first?.isEmpty == false)
    }

    @Test func countFailureReturnsZeroAndReports() throws {
        let lattice = try testLattice(ErrItem.self)
        try lattice.add(ErrItem(name: "a"))

        let n = lattice.backend.count(
            table: "NoSuchTable", where: String?.none,
            groupBy: String?.none, distinctBy: String?.none)
        #expect(n == 0)
        #expect(lattice.lastQueryError() != nil)
    }

    @Test(arguments: [false, true])
    func closedMaterializedSnapshotReportsInsteadOfEmptySuccess(memory: Bool) throws {
        let lattice = try memory
            ? Lattice(ErrItem.self, configuration: .init(storage: .memory()))
            : testLattice(ErrItem.self)
        defer { lattice.close() }
        try lattice.add(ErrItem(name: "retained"))
        let query = lattice.objects(ErrItem.self)
        // Exercise an existing query/generation, not only a fresh backend call.
        #expect(query.materializedSnapshot(limit: 2).count == 1)
        let messages = LockedBox<[String]>([])
        lattice.onQueryError { message in messages.withLock { $0.append(message) } }
        lattice.close()
        let rows = query.materializedSnapshot(limit: 2)
        #expect(rows.isEmpty)
        #expect(lattice.lastQueryError()?.isEmpty == false)
        #expect(messages.withLock { $0.count } == 1)
    }

    @Test(arguments: [false, true])
    func healthyEmptyReadClearsClosedQueryError(memory: Bool) throws {
        let closed = try memory
            ? Lattice(ErrItem.self, configuration: .init(storage: .memory()))
            : testLattice(ErrItem.self)
        let healthy = try memory
            ? Lattice(ErrItem.self, configuration: .init(storage: .memory()))
            : testLattice(ErrItem.self)
        defer { closed.close(); healthy.close() }
        closed.close()
        _ = closed.backend.objects(table: "ErrItem", where: nil, orderBy: nil,
            limit: 2, offset: nil, groupBy: nil, distinctBy: nil)
        #expect(closed.lastQueryError()?.isEmpty == false)
        let messages = LockedBox<[String]>([])
        healthy.onQueryError { message in messages.withLock { $0.append(message) } }
        let rows = healthy.objects(ErrItem.self).materializedSnapshot(limit: 2)
        #expect(rows.isEmpty)
        #expect(healthy.lastQueryError() == nil)
        #expect(messages.withLock { $0.isEmpty })
    }

}
