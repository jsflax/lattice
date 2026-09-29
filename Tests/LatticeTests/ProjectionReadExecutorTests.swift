import Foundation
import Dispatch
import Testing
@testable import Lattice
#if canImport(Darwin)
import Darwin
#endif

private enum ProjectionExecutorTestError: Error, Equatable { case gateTimedOut, expected }

private final class ProjectionExecutorTestGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func open() { semaphore.signal() }
    func wait(timeout: TimeInterval = 5) throws {
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw ProjectionExecutorTestError.gateTimedOut
        }
    }
}

@Suite("Bounded native projection executor", .serialized)
struct ProjectionReadExecutorTests {
    private func waitUntil(_ phase: String = "executor state", failureContext: @Sendable () -> String = { "" },
                           _ predicate: @escaping @Sendable () -> Bool) async throws {
        let end = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while !predicate() {
            let withinDeadline = DispatchTime.now().uptimeNanoseconds < end
            let detail = withinDeadline ? "" : failureContext()
            try #require(withinDeadline, "\(phase) did not settle \(detail)")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func expectFailure<Value>(_ result: Result<Value, any Error>,
                                      _ expected: ProjectionReadExecutorError) {
        switch result {
        case .success: Issue.record("Expected \(expected), received a successful result")
        case .failure(let error): #expect(error as? ProjectionReadExecutorError == expected)
        }
    }

    private func expectCancellation<Value>(_ result: Result<Value, any Error>) {
        switch result {
        case .success: Issue.record("Expected task cancellation, received a successful result")
        case .failure(let error): #expect(error is CancellationError)
        }
    }

    @Test func secondNativeWorkerProgressesWhileFirstIsBlocked() async throws {
        let executor = ProjectionReadExecutor(workerCount: 2, maxPendingJobs: 2)
        let gate = ProjectionExecutorTestGate()
        let firstStarted = ProjectionExecutorTestGate()
        defer { gate.open(); firstStarted.open() }
        async let first = executor.submit {
            firstStarted.open()
            try gate.wait()
            return 11
        }
        async let second = executor.submit {
            // Establish the overlap and release the first worker here. An
            // unrelated delay resuming this test on the cooperative executor
            // must not consume the native worker's unchanged five-second gate.
            defer { gate.open() }
            try firstStarted.wait(timeout: 3)
            let state = executor.snapshot
            #if canImport(Darwin)
            let stack = Int(pthread_get_stacksize_np(pthread_self()))
            #else
            let stack = Thread.current.stackSize
            #endif
            return (stack: stack, main: Thread.isMainThread,
                    otherJobsRunning: state.running - 1, verifiedWorkers: state.verifiedWorkers)
        }
        let probe = try await second
        #expect(!probe.main)
        #if canImport(Darwin)
        #expect(probe.stack >= ProjectionReadExecutor.requiredStackSize,
                "Native reads must not use the cooperative pool's small stack")
        #endif
        #expect(probe.otherJobsRunning == 1)
        #expect(probe.verifiedWorkers == 2)
        #expect(try await first == 11)
        await executor.shutdown()
        #expect(executor.snapshot.liveWorkers == 0)
    }

    @Test func queueFullRejectsWithoutStartingAnOperation() async throws {
        try await withProjectionMemoryConsumerExecutor {
            try await Self().queueFullRejectsWithoutStartingAnOperationBody()
        }
    }

    private func queueFullRejectsWithoutStartingAnOperationBody() async throws {
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 1)
        let gate = ProjectionExecutorTestGate()
        defer { gate.open() }
        let entered = LockedBox(false)
        let rejectedRuns = LockedBox(0)
        let gateExpired = LockedBox(false)
        let queuedSubmissionEntered = LockedBox(false)
        // Structured children inherit the scoped consumer preference (SE-0417).
        // Results retain each child's identity without depending on completion order.
        let outcome: Result<Void, any Error> = await withTaskGroup(
            of: (slot: Int, result: Result<Int, any Error>).self
        ) { group in
            group.addTask {
                do {
                    let value = try await executor.submit {
                        entered.withLock { $0 = true }
                        do { try gate.wait() }
                        catch { gateExpired.withLock { $0 = true }; throw error }
                        return 1
                    }
                    return (0, .success(value))
                } catch { return (0, .failure(error)) }
            }
            do {
                try await waitUntil("queue-full first operation start") { entered.withLock { $0 } }
                group.addTask {
                    queuedSubmissionEntered.withLock { $0 = true }
                    do { return (1, .success(try await executor.submit { 2 })) }
                    catch { return (1, .failure(error)) }
                }
                try await waitUntil("queue-full pending admission", failureContext: {
                    let state = executor.snapshot
                    return "pending=\(state.pending) running=\(state.running) queuedAdmissions=\(state.queuedAdmissions) queuedSubmissionEntered=\(queuedSubmissionEntered.withLock { $0 }) gateExpired=\(gateExpired.withLock { $0 })"
                }) { executor.snapshot.pending == 1 }
                do {
                    _ = try await executor.submit {
                        rejectedRuns.withLock { $0 += 1 }
                        return 3
                    }
                    Issue.record("A full queue must reject admission")
                } catch {
                    #expect(error as? ProjectionReadExecutorError == .queueFull)
                }
                #expect(rejectedRuns.withLock { $0 } == 0)
                #expect(executor.snapshot.pending == 1)
                gate.open()
                var completed: [Result<Int, any Error>?] = [nil, nil]
                for await child in group { completed[child.slot] = child.result }
                let running = try #require(completed[0])
                let submitted = try #require(completed[1])
                #expect(try running.get() == 1)
                #expect(try submitted.get() == 2)
                return .success(())
            } catch {
                // Release the native operation before waiting for either child.
                gate.open()
                group.cancelAll()
                await group.waitForAll()
                return .failure(error)
            }
        }
        // Both child tasks are joined before native shutdown; the outer helper
        // stops the consumer only after this body returns or rethrows.
        await executor.shutdown()
        try outcome.get()
    }

    @Test func cancellationBeforeAdmissionAndExpiredAdmissionNeverStart() async throws {
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 1)
        let runs = LockedBox(0)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await executor.submit {
                runs.withLock { $0 += 1 }
                return 1
            }
        }
        expectCancellation(await cancelled.result)
        do {
            _ = try await executor.submit(deadline: 0) {
                runs.withLock { $0 += 1 }
                return 2
            }
            Issue.record("An already expired job must be rejected")
        } catch {
            #expect(error as? ProjectionReadExecutorError == .deadlineExceeded)
        }
        #expect(runs.withLock { $0 } == 0)
        #expect(executor.snapshot.pending == 0)
        await executor.shutdown()
    }

    @Test func queuedCancellationResumesAndReleasesCapacityBeforeWorkerIsFree() async throws {
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 1)
        let gate = ProjectionExecutorTestGate()
        defer { gate.open() }
        let entered = LockedBox(false)
        let queuedRuns = LockedBox(0)
        let interrupts = LockedBox(0)
        let returned = LockedBox(false)
        let running = Task {
            try await executor.submit {
                entered.withLock { $0 = true }
                try gate.wait()
                return 1
            }
        }
        try await waitUntil { entered.withLock { $0 } }
        let queued = Task {
            defer { returned.withLock { $0 = true } }
            return try await executor.submit(onCancel: { interrupts.withLock { $0 += 1 } }) {
                queuedRuns.withLock { $0 += 1 }
                return 2
            }
        }
        try await waitUntil { executor.snapshot.pending == 1 }
        queued.cancel()
        queued.cancel()
        try await waitUntil { returned.withLock { $0 } }
        expectCancellation(await queued.result)
        #expect(executor.snapshot.pending == 0)
        #expect(executor.snapshot.running == 1)
        #expect(queuedRuns.withLock { $0 } == 0)
        #expect(interrupts.withLock { $0 } == 0, "An operation that never started needs no native interrupt")

        let replacement = Task { try await executor.submit { 3 } }
        try await waitUntil { executor.snapshot.pending == 1 }
        gate.open()
        #expect(try await running.value == 1)
        #expect(try await replacement.value == 3)
        await executor.shutdown()
    }

    @Test func queuedDeadlineExpiresWhileAllWorkersAreBlocked() async throws {
        try await withProjectionMemoryConsumerExecutor {
            try await Self().queuedDeadlineExpiresWhileAllWorkersAreBlockedBody()
        }
    }

    private func queuedDeadlineExpiresWhileAllWorkersAreBlockedBody() async throws {
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 1)
        let gate = ProjectionExecutorTestGate()
        defer { gate.open() }
        let entered = LockedBox(false)
        let queuedRuns = LockedBox(0)
        let outcome: Result<Void, any Error> = await withTaskGroup(
            of: (slot: Int, result: Result<Int, any Error>).self
        ) { group in
            group.addTask {
                do {
                    let value = try await executor.submit {
                        entered.withLock { $0 = true }
                        try gate.wait()
                        return 1
                    }
                    return (0, .success(value))
                } catch { return (0, .failure(error)) }
            }
            do {
                try await waitUntil { entered.withLock { $0 } }
                let before = executor.snapshot
                group.addTask {
                    let deadline = DispatchTime.now().uptimeNanoseconds + 200_000_000
                    do {
                        let value = try await executor.submit(deadline: deadline) {
                            queuedRuns.withLock { $0 += 1 }
                            return 2
                        }
                        return (1, .success(value))
                    } catch { return (1, .failure(error)) }
                }
                let submitted = try #require(await group.next())
                try #require(submitted.slot == 1, "The queued deadline must finish while the first operation remains blocked")
                expectFailure(submitted.result, .deadlineExceeded)
                // Retained transition counts prove actual queued expiry, rather than
                // accepting an already-expired admission or sampling transient state.
                let after = executor.snapshot
                #expect(after.queuedAdmissions &- before.queuedAdmissions == 1)
                #expect(after.queuedDeadlineExpirations &- before.queuedDeadlineExpirations == 1)
                #expect(executor.snapshot.running == 1)
                #expect(executor.snapshot.pending == 0)
                #expect(queuedRuns.withLock { $0 } == 0)
                gate.open()
                let running = try #require(await group.next())
                try #require(running.slot == 0)
                #expect(try running.result.get() == 1)
                return .success(())
            } catch {
                gate.open()
                group.cancelAll()
                await group.waitForAll()
                return .failure(error)
            }
        }
        await executor.shutdown()
        try outcome.get()
    }

    @Test func runningCancellationSignalsOnceAndWaitsForCleanup() async throws {
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 1)
        let interrupted = ProjectionExecutorTestGate()
        let cleanup = ProjectionExecutorTestGate()
        defer { interrupted.open(); cleanup.open() }
        let entered = LockedBox(false)
        let cleaning = LockedBox(false)
        let cleaned = LockedBox(false)
        let returned = LockedBox(false)
        let interrupts = LockedBox(0)
        let running = Task {
            defer { returned.withLock { $0 = true } }
            return try await executor.submit(onCancel: {
                // Reentrant state inspection proves callbacks run off-lock.
                _ = executor.snapshot
                interrupts.withLock { $0 += 1 }
                interrupted.open()
            }) {
                entered.withLock { $0 = true }
                try interrupted.wait()
                cleaning.withLock { $0 = true }
                try cleanup.wait()
                cleaned.withLock { $0 = true }
                return 7
            }
        }
        try await waitUntil { entered.withLock { $0 } }
        running.cancel()
        running.cancel()
        try await waitUntil { cleaning.withLock { $0 } }
        #expect(!returned.withLock { $0 })
        #expect(!cleaned.withLock { $0 })
        cleanup.open()
        expectCancellation(await running.result)
        #expect(cleaned.withLock { $0 })
        #expect(interrupts.withLock { $0 } == 1)
        await executor.shutdown()
    }

    @Test func runningDeadlineDiscardsLateSuccessAfterCleanup() async throws {
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 1)
        let interrupted = ProjectionExecutorTestGate()
        let cleanup = ProjectionExecutorTestGate()
        defer { interrupted.open(); cleanup.open() }
        let cleaning = LockedBox(false)
        let returned = LockedBox(false)
        let interrupts = LockedBox(0)
        let running = Task {
            defer { returned.withLock { $0 = true } }
            return try await executor.submit(
                deadline: DispatchTime.now().uptimeNanoseconds + 200_000_000,
                onCancel: { interrupts.withLock { $0 += 1 }; interrupted.open() }
            ) {
                try interrupted.wait()
                cleaning.withLock { $0 = true }
                try cleanup.wait()
                return 99 // Native cleanup completed, but the result is late.
            }
        }
        try await waitUntil { executor.snapshot.running == 1 }
        try await waitUntil { cleaning.withLock { $0 } }
        #expect(!returned.withLock { $0 })
        cleanup.open()
        expectFailure(await running.result, .deadlineExceeded)
        #expect(interrupts.withLock { $0 } == 1)
        await executor.shutdown()
    }

    @Test func shutdownRejectsQueuedWorkAndAwaitsRunningCleanupAndWorkerExit() async throws {
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 2)
        let interrupted = ProjectionExecutorTestGate()
        let cleanup = ProjectionExecutorTestGate()
        defer { interrupted.open(); cleanup.open() }
        let entered = LockedBox(false)
        let cleaning = LockedBox(false)
        let stopped = LockedBox(false)
        let queuedRuns = LockedBox(0)
        let interrupts = LockedBox(0)
        let running = Task {
            try await executor.submit(onCancel: {
                _ = executor.snapshot
                interrupts.withLock { $0 += 1 }
                interrupted.open()
            }) {
                entered.withLock { $0 = true }
                try interrupted.wait()
                cleaning.withLock { $0 = true }
                try cleanup.wait()
                return 1
            }
        }
        try await waitUntil { entered.withLock { $0 } }
        let queued = Task {
            try await executor.submit { queuedRuns.withLock { $0 += 1 }; return 2 }
        }
        try await waitUntil { executor.snapshot.pending == 1 }
        let shutdown = Task { await executor.shutdown(); stopped.withLock { $0 = true } }
        try await waitUntil { cleaning.withLock { $0 } }
        expectFailure(await queued.result, .shutdown)
        #expect(queuedRuns.withLock { $0 } == 0)
        #expect(!stopped.withLock { $0 })
        // Additional signals must not resume either continuation a second time.
        queued.cancel()
        running.cancel()
        do {
            _ = try await executor.submit { 3 }
            Issue.record("Shutdown must reject new work")
        } catch {
            #expect(error as? ProjectionReadExecutorError == .shutdown)
        }
        cleanup.open()
        expectFailure(await running.result, .shutdown)
        await shutdown.value
        await executor.shutdown() // Repeated shutdown is safe and already settled.
        #expect(stopped.withLock { $0 })
        #expect(executor.snapshot.liveWorkers == 0)
        #expect(executor.snapshot.running == 0)
        #expect(executor.snapshot.pending == 0)
        #expect(interrupts.withLock { $0 } == 1)
    }

    @Test func operationFailureDoesNotPoisonTheNextJob() async throws {
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 1)
        do {
            let _: Int = try await executor.submit { throw ProjectionExecutorTestError.expected }
            Issue.record("Expected the operation's error")
        } catch {
            #expect(error as? ProjectionExecutorTestError == .expected)
        }
        #expect(try await executor.submit { 42 } == 42)
        await executor.shutdown()
    }
}
