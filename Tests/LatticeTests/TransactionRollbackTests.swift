import Foundation
import Lattice
import Testing

@Model final class RollbackItem {
    var name: String
    init(name: String = "") { self.name = name }
}

// 1.0 item G8: a throw inside transaction { } rolls back instead of leaving
// the write transaction open (which blocked the next beginTransaction on the
// busy timeout and killed the process — far more reachable since item B made
// the add family throw).
@Suite("Transaction Rollback Tests", .serialized)
class TransactionRollbackTests: BaseTest {

    struct Boom: Error {}

    @Test func throwInsideTransaction_rollsBackAndStaysUsable() async throws {
        let lattice = try testLattice(RollbackItem.self)

        #expect(throws: Boom.self) {
            try lattice.transaction {
                try lattice.add(RollbackItem(name: "doomed"))
                throw Boom()
            }
        }
        // The doomed write must be gone…
        #expect(lattice.objects(RollbackItem.self).count == 0)

        // …and the connection immediately usable: a fresh transaction commits
        // without hitting a busy-timeout on a leaked open transaction.
        try lattice.transaction {
            try lattice.add(RollbackItem(name: "survivor"))
        }
        #expect(lattice.objects(RollbackItem.self).count == 1)
        #expect(lattice.objects(RollbackItem.self).first?.name == "survivor")
    }

    @Test func throwingAddInsideTransaction_alreadyManaged_rollsBack() async throws {
        let lattice = try testLattice(RollbackItem.self)
        let existing = RollbackItem(name: "managed")
        try lattice.add(existing)

        #expect(throws: LatticeError.self) {
            try lattice.transaction {
                try lattice.add(RollbackItem(name: "first-in-txn"))
                try lattice.add(existing)  // alreadyManaged → throws → rollback
            }
        }
        // first-in-txn rolled back; only the pre-txn row remains.
        #expect(lattice.objects(RollbackItem.self).count == 1)

        try lattice.transaction {
            try lattice.add(RollbackItem(name: "after"))
        }
        #expect(lattice.objects(RollbackItem.self).count == 2)
    }
}
