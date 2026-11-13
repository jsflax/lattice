import Foundation
import Testing
@testable import Lattice

@Model final class ChangeStreamLockOrderObject {
    var value: Int = 0
}

/// Cancellation must not take a lock held while delivery resumes a parked
/// consumer. The consumer's runtime status-record lock and the stream state
/// lock otherwise form an inversion that can park the shared delivery worker.
///
/// Each iteration gates this store's delivery queue, commits wide batches,
/// then cancels during delivery on a separate thread. Bounded polling detects
/// a blocked synchronous cancel without blocking the test task itself. Run a
/// negative-control build in a separate process: a deadlock can leave that
/// process's shared worker parked after this test reports its failure.
@Suite("Change Stream Terminate Lock Order")
final class ChangeStreamTerminateLockOrderTests: BaseTest {

    private let path: String = "\(String.random(length: 32)).sqlite"

    /// Frames per burst and rows per frame. The delivery side pays one
    /// `auditHeader` read per row, so each frame holds the delivery critical
    /// section for milliseconds while the next frame is already queued; the
    /// burst keeps the worker inside `deliver` for the whole cancel window.
    private static let framesPerBurst = 20
    private static let rowsPerFrame = 500
    private static let iterations = 3

    private func poll(until condition: @escaping @Sendable () -> Bool, within limit: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while !condition() && clock.now < deadline {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test(.timeLimit(.minutes(7)))
    func test_changeHeaders_cancelDuringDeliveryNeverDeadlocks() async throws {
        let lattice = try testLattice(path: path, ChangeStreamLockOrderObject.self)
        let fileURL = testTemporaryDirectory.appending(path: path)
        let storeIdentity = lattice.backend.identityHash

        for iteration in 0..<Self.iterations {
            let burstStarted = LockedBox(false)
            let burstBatches = LockedBox(Set<UUID>())
            let terminatedBatches = LockedBox(Set<UUID>())
            let diagnostic = PayloadObserverDiagnostic(observer: "terminationLockOrder") { event in
                guard let batch = event.batch else { return }
                if event.stage == "callback_entry", burstStarted.withLock({ $0 }) {
                    burstBatches.withLock { $0.insert(batch) }
                }
                if event.stage == "headers_yield_terminated" || event.stage == "batch_ignored_after_termination" {
                    terminatedBatches.withLock { $0.insert(batch) }
                }
            }
            let stream = lattice._changeHeaders(diagnostic: diagnostic)
            let frames = LockedBox(0)
            let finished = LockedBox(false)
            // Exercise delivery to a consumer isolated on the main executor.
            let consumer = Task { @MainActor in
                defer { finished.withLock { $0 = true } }
                do {
                    for try await _ in stream { frames.withLock { $0 += 1 } }
                } catch {}
            }

            // One probe row: its frame proves the query handle is open and
            // delivery is live before the worker is gated.
            try lattice.add(ChangeStreamLockOrderObject())
            guard await poll(until: { frames.withLock { $0 } >= 1 }, within: .seconds(20)) else {
                Issue.record("iteration \(iteration): the probe frame never arrived — changeHeaders is not delivering")
                consumer.cancel()
                return
            }

            // Delivery is FIFO per store and rotates between stores. Both
            // gate and probe use the stream's store identity.
            let gate = DispatchSemaphore(value: 0)
            // Scalar receipts only: never log or hold their lock across the wait.
            let points = LockedBox([String: UInt64]())
            let gateID = UUID()
            let probeID = UUID()
            @Sendable func mark(_ event: String) {
                let now = DispatchTime.now().uptimeNanoseconds
                points.withLock { $0[event] = now }
            }
            @Sendable func signalGate(_ reason: String) {
                mark("\(reason)_signal_before")
                let result = gate.signal()
                let now = DispatchTime.now().uptimeNanoseconds
                points.withLock {
                    $0["\(reason)_signal_after"] = now
                    $0["\(reason)_signal_woke_waiter"] = result == 0 ? 0 : 1
                }
            }
            let context = "store_identity=\(storeIdentity) iteration=\(iteration)"
                + " gate_id=\(gateID.uuidString.lowercased()) probe_id=\(probeID.uuidString.lowercased())"
            defer {
                signalGate("scope_exit")
                let copy = points.withLock { $0 }
                let fields = copy.keys.sorted().map { "\($0)=\(copy[$0]!)" }.joined(separator: " ")
                print("DIAGNOSTIC ChangeHeadersGate: stage=snapshot \(context) \(fields)"
                    + " clock=dispatch_uptime late_events_unobserved=true")
            }
            print("DIAGNOSTIC ChangeHeadersGate: stage=context \(context)")
            mark("gate_enqueue_before")
            ObserverDeliveryWorker.shared.enqueue(kind: .headers, table: "TestChangeHeadersGate",
                                                  storeIdentity: storeIdentity, batchID: gateID) {
                mark("wait_enter")
                gate.wait()
                mark("wait_return")
            }
            mark("gate_enqueue_after")

            // The burst: a sibling same-process handle on its own thread, so
            // the SQL never blocks a cooperative-pool thread.
            let writerDone = LockedBox(false)
            let committedFrames = LockedBox(0)
            let writerFailure = LockedBox<String?>(nil)
            let writer = Thread {
                defer {
                    mark("writer_done")
                    writerDone.withLock { $0 = true }
                }
                mark("writer_started")
                do {
                    let handle = try Lattice(ChangeStreamLockOrderObject.self,
                                             configuration: .init(fileURL: fileURL))
                    mark("writer_open_returned")
                    for frame in 0..<Self.framesPerBurst {
                        try handle.withTransaction {
                            for row in 0..<Self.rowsPerFrame {
                                let object = ChangeStreamLockOrderObject()
                                object.value = row
                                try handle.add(object)
                            }
                        }
                        committedFrames.withLock { $0 += 1 }
                        mark("writer_committed_\(frame + 1)")
                    }
                } catch {
                    writerFailure.withLock { $0 = String(describing: error) }
                    mark("writer_failed")
                }
            }
            burstStarted.withLock { $0 = true }
            writer.start()
            guard await poll(until: { writerDone.withLock { $0 } }, within: .seconds(60)) else {
                Issue.record("iteration \(iteration): the writer thread did not finish its burst within 60 s")
                signalGate("writer_timeout")
                consumer.cancel()
                return
            }

            let committed = committedFrames.withLock { $0 }
            let failure = writerFailure.withLock { $0 }
            #expect(committed == Self.framesPerBurst, "iteration \(iteration): committed \(committed) burst frames; writer failure: \(failure ?? "none")")
            guard committed == Self.framesPerBurst else {
                signalGate("writer_incomplete")
                consumer.cancel()
                return
            }

            // Open the gate and cancel a few milliseconds in: the worker is then
            // inside `deliver` with the consumer parked on `next()`.
            let cancelReturned = LockedBox(false)
            let canceller = Thread {
                signalGate("canceller")
                Thread.sleep(forTimeInterval: 0.005)
                mark("cancel_before")
                consumer.cancel()
                mark("cancel_after")
                cancelReturned.withLock { $0 = true }
            }
            canceller.start()

            let cancelOK = await poll(until: { cancelReturned.withLock { $0 } }, within: .seconds(5))
            #expect(cancelOK, """
                iteration \(iteration): Task.cancel() on the changeHeaders consumer has not returned after 5 s — \
                ChangeStreamState.terminate() is parked behind the delivery thread's yield (lock-order \
                inversion); the observer-delivery worker is wedged for the rest of this process
                """)
            guard cancelOK else { return }

            let consumerOK = await poll(until: { finished.withLock { $0 } }, within: .seconds(5))
            #expect(consumerOK, "iteration \(iteration): the cancelled consumer did not end within 5 s")
            guard consumerOK else { return }

            // The worker must still be answering once the backlog drains (a
            // probe job queued behind it) before the next iteration begins.
            let workerAlive = LockedBox(false)
            mark("probe_enqueue_before")
            ObserverDeliveryWorker.shared.enqueue(kind: .headers, table: "TestChangeHeadersProbe",
                                                  storeIdentity: storeIdentity, batchID: probeID) {
                mark("probe_body_done")
                workerAlive.withLock { $0 = true }
            }
            mark("probe_enqueue_after")
            let workerOK = await poll(until: { workerAlive.withLock { $0 } }, within: .seconds(30))
            #expect(workerOK, "iteration \(iteration): the observer-delivery worker did not run a probe job within 30 s")
            guard workerOK else { return }
            let burstIDs = burstBatches.withLock { $0 }
            let terminatedIDs = terminatedBatches.withLock { $0 }
            #expect(!burstIDs.intersection(terminatedIDs).isEmpty,
                    "iteration \(iteration): no committed burst batch reached termination")
        }
    }
}
