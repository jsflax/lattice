import Foundation
import Testing
import Lattice

@Model final class Widget {
    var value: Int
}

/// Stress tests for ModelInstanceRegistry to verify no deadlock occurs when
/// concurrent observer callbacks trigger rapid register/deregister cycles.
///
/// Background: A deadlock was found where `deregister()` held an NSLock while
/// calling `removeAll { ref.instance == nil }`. Accessing a weak var creates a
/// temporary strong ref; if that temporary is the last strong ref (because another
/// thread released its reference in the race window), destroying the temporary
/// triggers Model.deinit → recursive deregister → deadlock on the same lock.
///
/// The fix moves weak var access outside the locked section using a
/// take-out-process-put-back pattern.
@Suite("Instance Registry Tests")
class InstanceRegistryTests: BaseTest {

    /// Reproduces the deadlock pattern from the stack trace:
    /// notify_change → observer callback → object(primaryKey:) → register →
    /// old temporary dropped → deinit → deregister → removeAll checks other
    /// refs → recursive deregister → deadlock.
    ///
    /// Multiple concurrent tasks fetch and drop instances of the same rows
    /// while observers create additional instances in their callbacks.
    /// This maximizes contention on ModelInstanceRegistry's lock and the
    /// probability of hitting the race window.
    @Test(.timeLimit(.minutes(5)))
    func test_ConcurrentRegisterDeregisterNoDeadlock() async throws {
        let lattice = try Lattice(Widget.self, configuration: .init(fileURL: FileManager.default.temporaryDirectory.appending(path: "\(String.random(length: 32)).sqlite")))

        // Create several rows to spread observer traffic across multiple InstanceKeys
        let rowCount = 20
        for i in 0..<rowCount {
            let w = Widget()
            w.value = i
            try lattice.add(w)
        }

        // Set up multiple observers — each callback fetches an object by primary key,
        // which registers a new instance in ModelInstanceRegistry. The temporary is
        // immediately dropped, triggering deregister. With multiple observers, multiple
        // instances share the same InstanceKey (dbPath + tableName + primaryKey), which
        // is the precondition for the deadlock.
        let observerCount = 8
        var cancellables: [AnyCancellable] = []
        for _ in 0..<observerCount {
            let c = lattice.objects(Widget.self).observe { change in
                switch change {
                case .insert(let id), .update(let id):
                    // Creates a new instance (register), then drops it (deregister).
                    // Multiple observers doing this concurrently for the same rowId
                    // creates the exact contention pattern from the deadlock.
                    let _ = lattice.object(Widget.self, primaryKey: id)
                case .delete:
                    break
                }
            }
            cancellables.append(c)
        }

        // Rapidly mutate all rows from concurrent tasks.
        // Each mutation fires notify_change → all observer callbacks → concurrent
        // register/deregister on the same InstanceKeys.
        let iterations = 50
        let box = _UncheckedSendable(lattice)
        await withTaskGroup(of: Void.self) { group in
            for rowIdx in 1...rowCount {
                group.addTask {
                    let db = box.value
                    for i in 0..<iterations {
                        autoreleasepool {
                            if let w = db.object(Widget.self, primaryKey: Int64(rowIdx)) {
                                w.value = i * 1000 + rowIdx
                            }
                        }
                    }
                }
            }
        }

        // Let queued observer callbacks drain
        try await Task.sleep(for: .milliseconds(500))

        for c in cancellables { c.cancel() }
        // Reaching here means no deadlock occurred
    }

    /// Simpler variant: rapid create-fetch-drop cycles for the same row on multiple
    /// tasks without observers. Tests that concurrent register/deregister for
    /// overlapping InstanceKeys doesn't deadlock or corrupt state.
    @Test(.timeLimit(.minutes(5)))
    func test_ConcurrentFetchDropNoDeadlock() async throws {
        let lattice = try Lattice(Widget.self, configuration: .init(fileURL: FileManager.default.temporaryDirectory.appending(path: "\(String.random(length: 32)).sqlite")))

        let w = Widget()
        w.value = 42
        try lattice.add(w)
        let pk = w.primaryKey!

        // Many concurrent tasks all fetching (register) and immediately dropping
        // (deregister) instances of the same row. This creates maximum contention
        // on the same InstanceKey bucket in ModelInstanceRegistry.
        let box = _UncheckedSendable(lattice)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    let db = box.value
                    for _ in 0..<500 {
                        let _ = db.object(Widget.self, primaryKey: pk)
                    }
                }
            }
        }

        // Verify the row is still intact after the storm
        let final_ = lattice.object(Widget.self, primaryKey: pk)
        #expect(final_?.value == 42)
    }
}
