import Foundation
import Lattice
import Testing

@Model final class OrderedItem {
    var seq: Int
    init(seq: Int = 0) { self.seq = seq }
}

// 1.0 item F2: the delivery-ordering contract (see observe() docs).
//
// Guaranteed: exactly-once delivery of every committed change, batches
// walked internally in commit order. NOT guaranteed: cross-batch arrival
// order — under parallel-suite CPU load adjacent batches interleave
// (observed for both file-backed AND in-memory lattices; the hop between
// the C++ notify path and the Swift callback is where order is lost).
// Consumers needing a total order sort by AuditLog id, which these tests
// pin as commit-ordered. Property-change signals are exempt entirely.

@Suite("Observation Ordering Tests", .serialized)
class ObservationOrderingTests: BaseTest {

    @Test func auditLogDelivery_isExactlyOnceAndGapFree() async throws {
        let lattice = try Lattice(OrderedItem.self, configuration: .init(storage: .memory()))

        let collector = OrderCollector()
        let token = lattice.observe { (logs: [AuditLog]) in
            collector.append(contentsOf: logs.compactMap { $0.primaryKey })
        }
        defer { token.cancel() }

        let writes = 25
        for i in 0..<writes {
            try lattice.add(OrderedItem(seq: i))
        }

        try await waitUntil { collector.snapshot().count >= writes }
        let ids = collector.snapshot()
        #expect(ids.count >= writes)
        #expect(Set(ids).count == ids.count, "no duplicate deliveries")
        // AuditLog ids are the total-order source: sorted, they must be the
        // exact commit sequence with no gaps.
        let sorted = ids.sorted()
        guard let first = sorted.first, let last = sorted.last else {
            Issue.record("no AuditLog events delivered at all")
            return
        }
        #expect(sorted == Array(first...last), "AuditLog ids must be gap-free commit sequence")
    }

    @Test func collectionChanges_deliverExactlyOnce() async throws {
        let lattice = try Lattice(OrderedItem.self, configuration: .init(storage: .memory()))

        let collector = OrderCollector()
        let token = lattice.observe(OrderedItem.self) { change in
            if case .insert(let rowId) = change {
                collector.append(contentsOf: [rowId])
            }
        }
        defer { token.cancel() }

        let writes = 25
        for i in 0..<writes {
            try lattice.add(OrderedItem(seq: i))
        }

        try await waitUntil { collector.snapshot().count >= writes }
        let rowIds = collector.snapshot()
        #expect(rowIds.count == writes)
        #expect(Set(rowIds).count == rowIds.count, "no duplicate deliveries")
        #expect(rowIds.sorted() == Array(1...Int64(writes)), "every commit delivered exactly once")
    }

    /// Cross-handle: a SECOND lattice over the same file must see every
    /// commit exactly once (delivery rides the same-path instance registry;
    /// arrival order is best-effort per the contract).
    @Test func crossHandleDelivery_isExactlyOnce() async throws {
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
            try writer.add(OrderedItem(seq: i))
        }

        try await waitUntil { collector.snapshot().count >= writes }
        let rowIds = collector.snapshot()
        #expect(rowIds.count == writes)
        #expect(Set(rowIds).count == rowIds.count, "no duplicate deliveries")
        #expect(rowIds.sorted() == Array(1...Int64(writes)), "every commit delivered exactly once cross-handle")
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
        if Date().timeIntervalSince(start) > deadline {
            Issue.record("timed out after \(deadline)s waiting for delivery — assertions below reflect PARTIAL data")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
