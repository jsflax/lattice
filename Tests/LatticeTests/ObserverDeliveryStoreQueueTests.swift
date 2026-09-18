import Foundation
import Testing
@testable import Lattice

private final class ObserverQueueProbe: @unchecked Sendable {
    let id: Int
    let onRelease: @Sendable () -> Void
    init(id: Int, onRelease: @escaping @Sendable () -> Void) {
        self.id = id; self.onRelease = onRelease
    }
    deinit { onRelease() }
}

@Suite("Observer store rotation")
struct ObserverDeliveryStoreQueueTests {
    @Test func queuedBurstYieldsToAnotherStoreWithoutDroppingOrReordering() {
        var queue = ObserverDeliveryStoreQueue()
        let delivered = NIOLockedValueBoxCompat<[Int]>([])
        for i in 0..<200 {
            queue.append(storeIdentity: 1, enqueueOrdinal: UInt64(i + 1)) {
                delivered.withLocked { $0.append(i) }
            }
        }
        // This first turn stands in for the worker's admitted body. A new
        // store arrives while A still has a burst queued.
        let admitted = queue.popFirst()!
        queue.append(storeIdentity: 2, enqueueOrdinal: 201) {
            delivered.withLocked { $0.append(1000) }
        }
        admitted.operation()
        queue.popFirst()!.operation()
        #expect(queue.oldestEnqueueOrdinal == 3)
        let otherStore = queue.popFirst()!
        #expect(otherStore.enqueueOrdinal == 201)
        otherStore.operation()
        #expect(queue.oldestEnqueueOrdinal == 3)
        while let job = queue.popFirst() { job.operation() }
        let values = delivered.withLocked { $0 }
        #expect(values.prefix(3) == [0, 1, 1000])
        #expect(values.filter { $0 != 1000 } == Array(0..<200))
        #expect(values.count == 201)
        #expect(queue.isEmpty && queue.count == 0)
        #expect(queue.oldestEnqueueOrdinal == nil)
    }

    @Test func multipleStoresRotateAndAnEmptiedIdentityCanRejoin() {
        var queue = ObserverDeliveryStoreQueue()
        let delivered = NIOLockedValueBoxCompat<[Int]>([])
        var ordinal: UInt64 = 0
        for round in 0..<3 {
            for store in 1...3 {
                for item in 0..<160 {
                    ordinal += 1
                    queue.append(storeIdentity: Int64(store), enqueueOrdinal: ordinal) {
                        delivered.withLocked { $0.append(round * 10000 + item * 10 + store) }
                    }
                }
            }
            while let job = queue.popFirst() { job.operation() }
            #expect(queue.count == 0)
        }
        let expected = (0..<3).flatMap { round in
            (0..<160).flatMap { item in (1...3).map { round * 10000 + item * 10 + $0 } }
        }
        #expect(delivered.withLocked { $0 } == expected)
    }

    @Test func poppedClosureRetainsItsCaptureUntilReleaseOutsideTheOwnerLock() {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var queue = ObserverDeliveryStoreQueue()
            func enqueue(_ operation: @escaping @Sendable () -> Void) {
                lock.lock()
                queue.append(storeIdentity: 1, enqueueOrdinal: 2, operation: operation)
                lock.unlock()
            }
        }
        let box = Box()
        let released = NIOLockedValueBoxCompat(false)
        let ownerLockAvailable = NIOLockedValueBoxCompat(false)
        let invoked = NIOLockedValueBoxCompat<[Int]>([])
        var probe: ObserverQueueProbe? = ObserverQueueProbe(id: 7) {
            // Detect a red lock-lifetime regression without deadlocking
            // the entire test process. Enqueue recursively only if safe.
            let available = box.lock.try()
            ownerLockAvailable.withLocked { $0 = available }
            if available {
                box.lock.unlock()
                box.enqueue { invoked.withLocked { $0.append(8) } }
            }
            released.withLocked { $0 = true }
        }
        box.lock.lock()
        box.queue.append(storeIdentity: 1, enqueueOrdinal: 1) { [probe = probe!] in
            invoked.withLocked { $0.append(probe.id) }
        }
        probe = nil
        var admitted = box.queue.popFirst()
        #expect(!released.withLocked { $0 })
        box.lock.unlock()
        admitted?.operation()
        admitted = nil
        #expect(released.withLocked { $0 })
        #expect(ownerLockAvailable.withLocked { $0 })
        box.lock.lock()
        let recursive = box.queue.popFirst()
        box.lock.unlock()
        recursive?.operation()
        #expect(invoked.withLocked { $0 } == [7, 8])
    }
}
