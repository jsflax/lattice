import Foundation
import Lattice
import Testing

@Model final class OrderedItem {
    var seq: Int
    init(seq: Int = 0) { self.seq = seq }
}

// 1.0 item F2: the delivery-ordering contract.
//
// CONTRACT (1.0): payload-bearing change streams — the AuditLog observer and
// table/collection observers — deliver events in COMMIT ORDER: within a batch
// the callback walks rows in commit order synchronously, and batches are
// delivered in the order their transactions committed. Property-change
// signals (objectWillChange / @Observable triggers) are wakeup signals with
// no payload: they are dispatched via unstructured Tasks, may arrive in any
// order, and may effectively coalesce — the only observable state is the row
// itself, which always reads latest-committed. Consumers needing ordered
// per-event data must use the payload-bearing streams.
@Suite("Observation Ordering Tests", .serialized)
class ObservationOrderingTests: BaseTest {

    @Test func auditLogDelivery_isInCommitOrder() async throws {
        let lattice = try testLattice(OrderedItem.self)

        let collector = OrderCollector()
        let token = lattice.observe { (logs: [AuditLog]) in
            collector.append(contentsOf: logs.compactMap { $0.primaryKey })
        }
        defer { token.cancel() }

        let writes = 25
        for i in 0..<writes {
            lattice.add(OrderedItem(seq: i))
        }

        try await waitUntil { collector.snapshot().count >= writes }
        let ids = collector.snapshot()
        #expect(ids.count >= writes)
        #expect(ids == ids.sorted(), "AuditLog events must arrive in commit order, got \(ids)")
        #expect(Set(ids).count == ids.count, "no duplicate deliveries")
    }

    @Test func collectionChanges_areInCommitOrder() async throws {
        let lattice = try testLattice(OrderedItem.self)

        let collector = OrderCollector()
        let token = lattice.observe(OrderedItem.self) { change in
            if case .insert(let rowId) = change {
                collector.append(contentsOf: [rowId])
            }
        }
        defer { token.cancel() }

        let writes = 25
        for i in 0..<writes {
            lattice.add(OrderedItem(seq: i))
        }

        try await waitUntil { collector.snapshot().count >= writes }
        let rowIds = collector.snapshot()
        #expect(rowIds.count == writes)
        #expect(rowIds == rowIds.sorted(), "insert events must arrive in commit order, got \(rowIds)")
    }

    /// Cross-handle: a SECOND lattice over the same file must also see events
    /// in commit order (delivery rides the same-path instance registry).
    @Test func crossHandleDelivery_isInCommitOrder() async throws {
        let path = "ordering_\(String.random(length: 16)).sqlite"
        let writer = try testLattice(path: path, OrderedItem.self)
        let observerSide = try testLattice(path: path, OrderedItem.self)

        let collector = OrderCollector()
        let token = observerSide.observe(OrderedItem.self) { change in
            if case .insert(let rowId) = change {
                collector.append(contentsOf: [rowId])
            }
        }
        defer { token.cancel() }

        let writes = 25
        for i in 0..<writes {
            writer.add(OrderedItem(seq: i))
        }

        try await waitUntil { collector.snapshot().count >= writes }
        let rowIds = collector.snapshot()
        #expect(rowIds.count == writes)
        #expect(rowIds == rowIds.sorted(), "cross-handle events must arrive in commit order, got \(rowIds)")
    }
}

private final class OrderCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []
    func append(contentsOf new: [Int64]) { lock.withLock { values.append(contentsOf: new) } }
    func snapshot() -> [Int64] { lock.withLock { values } }
}

private func waitUntil(deadline: TimeInterval = 15, _ condition: () -> Bool) async throws {
    let start = Date()
    while !condition() {
        if Date().timeIntervalSince(start) > deadline { return }
        try await Task.sleep(for: .milliseconds(10))
    }
}
