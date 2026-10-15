import Foundation
import Dispatch
import Testing
@testable import Lattice

private enum CatalogExecutorFixtureError: Error { case timedOut }

private final class CatalogExecutorGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var entered = false
    func open() { semaphore.signal() }
    func hold() throws {
        lock.lock(); entered = true; lock.unlock()
        guard semaphore.wait(timeout: .now() + 10) == .success else { throw CatalogExecutorFixtureError.timedOut }
    }
    private var hasEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    func waitUntilEntered() async throws {
        let end = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while !hasEntered {
            guard DispatchTime.now().uptimeNanoseconds < end else { throw CatalogExecutorFixtureError.timedOut }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

/// Executor orchestration cases only. These do not simulate or prove native
/// statement/transaction cleanup. All are UNCOMPILED and UNRUN at freeze.
@Suite("Catalog cleanup failure executor precedence", .serialized)
struct OwnedCatalogExecutorPrecedenceTests {
    @Test func observedCleanupFailureSurvivesCancellationAfterOperationAndSignalReturn() async throws {
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 1)
        let gate = CatalogExecutorGate()
        let failure = OwnedCatalogCleanupError(finalizeCode: 10, transactionCode: -1, rollbackCode: 5)
        let task = Task {
            try await executor.submit(onCancel: { gate.open() },
                preservingFailureOnStop: { $0 is OwnedCatalogCleanupError }) { () throws -> Int in
                    try gate.hold()
                    throw failure
                }
        }
        do { try await gate.waitUntilEntered() }
        catch {
            task.cancel(); gate.open(); _ = await task.result
            await executor.shutdown()
            throw error
        }
        task.cancel()
        switch await task.result {
        case .success: Issue.record("A cleanup failure returned a value")
        case .failure(let error):
            let observed = error as? OwnedCatalogCleanupError
            #expect(observed?.finalizeCode == 10 && observed?.transactionCode == -1 && observed?.rollbackCode == 5)
        }
        await executor.shutdown()
        #expect(executor.snapshot.liveWorkers == 0 && executor.snapshot.running == 0)
    }

    @Test func defaultPredicatePreservesExistingProjectionCancellationPrecedence() async throws {
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 1)
        let gate = CatalogExecutorGate()
        let task = Task {
            try await executor.submit(onCancel: { gate.open() }) { () throws -> Int in
                try gate.hold()
                throw OwnedCatalogCleanupError(finalizeCode: 10, transactionCode: -1, rollbackCode: 5)
            }
        }
        do { try await gate.waitUntilEntered() }
        catch {
            task.cancel(); gate.open(); _ = await task.result
            await executor.shutdown()
            throw error
        }
        task.cancel()
        switch await task.result {
        case .success: Issue.record("Cancelled projection returned a value")
        case .failure(let error): #expect(error is CancellationError)
        }
        await executor.shutdown()
        #expect(executor.snapshot.liveWorkers == 0 && executor.snapshot.running == 0)
    }

    @Test func preservedCleanupFailureAlsoSurvivesAlreadyExpiredPublication() async throws {
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 1)
        let gate = CatalogExecutorGate()
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        let task = Task {
            try await executor.submit(deadline: deadline, onCancel: { gate.open() },
                preservingFailureOnStop: { $0 is OwnedCatalogCleanupError }) { () throws -> Int in
                    try gate.hold()
                    throw OwnedCatalogCleanupError(finalizeCode: 10, transactionCode: -1, rollbackCode: 5)
                }
        }
        do { try await gate.waitUntilEntered() }
        catch {
            task.cancel(); gate.open(); _ = await task.result
            await executor.shutdown()
            throw error
        }
        // The original executor deadline signals the held operation. It then
        // returns its observed cleanup error before the continuation resumes.
        switch await task.result {
        case .success: Issue.record("Expired cleanup failure returned a value")
        case .failure(let error): #expect(error is OwnedCatalogCleanupError)
        }
        await executor.shutdown()
        #expect(executor.snapshot.liveWorkers == 0 && executor.snapshot.running == 0)
    }
}
