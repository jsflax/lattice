import Foundation
import Testing
@testable import Lattice

@Model final class ChangeStreamLockOrderObject {
    var value: Int = 0
}

/// LAT-03 — cancelling a `changeHeaders` / `changeStream` consumer while the
/// delivery thread is mid-frame must never deadlock the process.
///
/// The inversion this pins: `lattice.observer-delivery` enters
/// `ChangeStreamState.deliver`, takes the stream's state lock and resolves the
/// batch (one `auditHeader` read per change) before it yields. Yielding to a
/// PARKED consumer resumes that task, and the runtime's resume path
/// (`AsyncTask::flagAsAndEnqueueOnExecutor` → `updateStatusRecord` for the
/// continuation the task is suspended on) has to take the task's status-record
/// lock. Cancelling the consumer (`Task.cancel`, a `.timeLimit`, Orbital's
/// `RoomOrchestrator.stop()`) runs the stream's `onTermination` →
/// `terminate()` WHILE `swift_task_cancel` HOLDS that status-record lock. With
/// `terminate()` waiting on the state lock, both threads parked for good — and
/// the worker is process-wide, so every observer in the process stopped with
/// it (first seen as a wedged test host in Orbital, PR #355).
///
/// Shape, per iteration: the delivery worker is held behind a gate job while a
/// writer commits a run of wide frames (one transaction = one frame = N header
/// reads inside the delivery critical section), so that opening the gate puts
/// the worker inside `deliver` for tens of milliseconds back to back; a plain
/// thread opens the gate and cancels the parked consumer a few milliseconds
/// later. Every verdict is POLLED with a deadline on purpose: a deadlocked
/// `cancel()` sits in a mutex, not an await, so on Darwin `.timeLimit` cannot
/// interrupt it (see CIEnvironment.swift) — the test has to fail by itself
/// instead of parking the lane, and the canceller runs on its own thread so a
/// wedged cancel is never the test task.
@Suite("Change Stream Terminate Lock Order")
final class ChangeStreamTerminateLockOrderTests: BaseTest {

    private let path: String = "\(String.random(length: 32)).sqlite"

    /// Frames per burst and rows per frame. The delivery side pays one
    /// `auditHeader` read per row, so each frame holds the delivery critical
    /// section for milliseconds while the next frame is already queued; the
    /// burst keeps the worker inside `deliver` for the whole cancel window.
    private static let framesPerBurst = 20
    private static let rowsPerFrame = 500
    private static let iterations = 10

    private func poll(until condition: @escaping @Sendable () -> Bool, within limit: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while !condition() && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test(.timeLimit(.minutes(2)))
    func test_changeHeaders_cancelDuringDeliveryNeverDeadlocks() async throws {
        let lattice = try testLattice(path: path, ChangeStreamLockOrderObject.self)
        let fileURL = testTemporaryDirectory.appending(path: path)

        for iteration in 0..<Self.iterations {
            let stream = lattice.changeHeaders
            let frames = LockedBox(0)
            let finished = LockedBox(false)
            // MainActor-isolated like the production consumer: the resume a
            // yield performs targets the main executor, exactly as in Orbital.
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

            // Gate the worker, then queue the burst behind it. The worker is
            // FIFO, so every frame's `deliver` now waits on the gate.
            let gate = DispatchSemaphore(value: 0)
            ObserverDeliveryWorker.shared.enqueue { gate.wait() }

            // The burst: a sibling same-process handle on its own thread, so
            // the SQL never blocks a cooperative-pool thread.
            let writerDone = LockedBox(false)
            let writer = Thread {
                defer { writerDone.withLock { $0 = true } }
                guard let handle = try? Lattice(ChangeStreamLockOrderObject.self,
                                                configuration: .init(fileURL: fileURL)) else { return }
                for _ in 0..<Self.framesPerBurst {
                    try? handle.transaction {
                        for row in 0..<Self.rowsPerFrame {
                            let object = ChangeStreamLockOrderObject()
                            object.value = row
                            try handle.add(object)
                        }
                    }
                }
            }
            writer.start()
            guard await poll(until: { writerDone.withLock { $0 } }, within: .seconds(60)) else {
                Issue.record("iteration \(iteration): the writer thread did not finish its burst within 60 s")
                gate.signal()
                consumer.cancel()
                return
            }

            // Open the gate and cancel a few milliseconds in: the worker is then
            // inside `deliver` with the consumer parked on `next()`.
            let cancelReturned = LockedBox(false)
            let canceller = Thread {
                gate.signal()
                Thread.sleep(forTimeInterval: 0.005)
                consumer.cancel()
                cancelReturned.withLock { $0 = true }
            }
            canceller.start()

            let cancelOK = await poll(until: { cancelReturned.withLock { $0 } }, within: .seconds(5))
            #expect(cancelOK, """
                iteration \(iteration): Task.cancel() on the changeHeaders consumer has not returned after 5 s — \
                ChangeStreamState.terminate() is parked behind the delivery thread's yield (LAT-03 lock-order \
                inversion); the observer-delivery worker is wedged for the rest of this process
                """)
            guard cancelOK else { return }

            let consumerOK = await poll(until: { finished.withLock { $0 } }, within: .seconds(5))
            #expect(consumerOK, "iteration \(iteration): the cancelled consumer did not end within 5 s")
            guard consumerOK else { return }

            // The worker must still be answering once the backlog drains (a
            // probe job queued behind it) before the next iteration begins.
            let workerAlive = LockedBox(false)
            ObserverDeliveryWorker.shared.enqueue { workerAlive.withLock { $0 = true } }
            let workerOK = await poll(until: { workerAlive.withLock { $0 } }, within: .seconds(30))
            #expect(workerOK, "iteration \(iteration): the observer-delivery worker did not run a probe job within 30 s")
            guard workerOK else { return }
        }
    }
}
