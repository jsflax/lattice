import Foundation
import Testing
@testable import Lattice

/// Verifies the LatticeCore read/write-after-close guard: once a handle is
/// closed (or deleted), every Swift-facing query/mutation short-circuits to
/// empty/no-op instead of dereferencing the null `read_db_`/`db_` that
/// `lattice_db::close()` leaves behind (which previously surfaced as an
/// unhandled C++ exception, e.g. the staff app crash on login).
@Suite("Close guard")
final class CloseGuardTests: BaseTest {

    private func seed(_ lattice: Lattice, _ names: [String]) {
        for name in names {
            let p = Person()
            p.name = name
            p.age = 30
            lattice.add(p)
        }
    }

    @Test func test_ReadsAfterClose_ReturnEmpty_NoCrash() throws {
        let lattice = try testLattice(path: "\(String.random(length: 32)).sqlite", Person.self)
        seed(lattice, ["John", "Jane", "Tim"])
        #expect(lattice.objects(Person.self).count == 3)

        lattice.close()

        // Every read funnel must short-circuit, not crash.
        #expect(lattice.objects(Person.self).count == 0)
        #expect(lattice.objects(Person.self).snapshot().isEmpty)
        #expect(lattice.objects(Person.self).where { $0.name == "John" }.count == 0)
        var iterated = 0
        for _ in lattice.objects(Person.self) { iterated += 1 }
        #expect(iterated == 0)
    }

    /// The real-world shape of the staff bug: materialize objects + hold a live
    /// results handle, delete the lattice out from under them (as logout does),
    /// then keep using all of it. Must not crash.
    @Test func test_UseObjectsFromDeletedLattice_NoCrash() throws {
        let path = "\(String.random(length: 32)).sqlite"
        let config = Lattice.Configuration(fileURL: FileManager.default.temporaryDirectory.appending(path: path))
        let lattice = try Lattice(Person.self, configuration: config)
        seed(lattice, ["Alice", "Bob", "Carol"])

        let results = lattice.objects(Person.self)   // live handle, held across delete
        let people = results.snapshot()               // materialized objects, held across delete
        #expect(people.count == 3)

        try Lattice.delete(for: config)               // delete while lattice/results/people are alive

        // Use everything from the deleted lattice — must not crash.
        for p in people { _ = p.name; _ = p.age }
        #expect(results.snapshot().isEmpty)
        #expect(lattice.objects(Person.self).count == 0)
    }

    /// Exact shape of the StaffSettingsView crash: `query.first?.prop` on a
    /// deleted lattice. `.first` → Collection.endIndex → cxxLattice.count, which
    /// threw an unhandled C++ exception before the guard.
    @Test func test_FirstAndCountAfterDelete_NoThrow() throws {
        let path = "\(String.random(length: 32)).sqlite"
        let config = Lattice.Configuration(fileURL: FileManager.default.temporaryDirectory.appending(path: path))
        let lattice = try Lattice(Person.self, configuration: config)
        seed(lattice, ["Alice"])
        let results = lattice.objects(Person.self)
        #expect(results.first != nil)

        try Lattice.delete(for: config)

        // Each of these went through count()/endIndex and crashed before the fix.
        #expect(results.endIndex == 0)
        #expect(results.first == nil)
        #expect(results.first?.name == nil)
        #expect(lattice.objects(Person.self).first?.name == nil)
    }

    @Test func test_ReadsAfterDelete_ReturnEmpty_NoCrash() throws {
        let path = "\(String.random(length: 32)).sqlite"
        let config = Lattice.Configuration(fileURL: FileManager.default.temporaryDirectory.appending(path: path))
        let lattice = try Lattice(Person.self, configuration: config)
        seed(lattice, ["John", "Jane"])
        #expect(lattice.objects(Person.self).count == 2)

        // delete() closes + evicts + unlinks. The captured `lattice` struct still
        // holds the (now closed) shared handle; reads on it must return empty.
        try Lattice.delete(for: config)

        #expect(lattice.objects(Person.self).count == 0)
        #expect(lattice.objects(Person.self).snapshot().isEmpty)
    }

    @Test func test_WriteAfterClose_NoCrash() throws {
        let lattice = try testLattice(path: "\(String.random(length: 32)).sqlite", Person.self)
        seed(lattice, ["John"])
        lattice.close()

        // Writes after close must be no-ops, not UB on the null write connection.
        let p = Person()
        p.name = "ShouldNotPersist"
        p.age = 1
        lattice.add(p)            // guarded → no-op, no crash
        #expect(lattice.objects(Person.self).count == 0)
    }

    /// Hammer reads on a background thread while the owning thread closes the
    /// handle. The close() refcount drain must let any in-flight read finish on
    /// a live connection before `db_`/`read_db_` are reset — no SIGSEGV.
    @Test(.timeLimit(.minutes(1)))
    func test_ConcurrentReadsDuringClose_NoCrash() throws {
        // Deliberately shared across reader threads — the close-during-read
        // race IS the subject under test (Linux 6.3 enforces the Sendable
        // capture; Darwin's toolchain lets it slide).
        nonisolated(unsafe) let lattice = try testLattice(path: "\(String.random(length: 32)).sqlite", Person.self)
        seed(lattice, (0..<200).map { "P\($0)" })

        let stop = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let q = DispatchQueue(label: "close-guard.readers", attributes: .concurrent)
        for _ in 0..<4 {
            q.async {
                while stop.wait(timeout: .now()) == .timedOut {
                    // Returns real rows before close, empty after — never crashes.
                    _ = lattice.objects(Person.self).snapshot()
                    _ = lattice.objects(Person.self).count
                }
                done.signal()
            }
        }
        // Let readers spin up, then close concurrently.
        Thread.sleep(forTimeInterval: 0.05)
        lattice.close()
        for _ in 0..<4 { stop.signal() }
        for _ in 0..<4 { done.wait() }

        #expect(lattice.objects(Person.self).count == 0)
    }
}
