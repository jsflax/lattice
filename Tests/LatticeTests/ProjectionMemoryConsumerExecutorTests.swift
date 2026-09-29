import Foundation
import Testing

// No Lattice/native storage fixture is involved in these executor regressions.
// Every created executor is drained even when a requirement throws.
private enum ConsumerFixtureError: Error { case missingAffinity, cancellationNotObserved }

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private func crossNonisolatedSuspension(_ executor: ProjectionMemoryConsumerExecutor) async -> Bool {
    guard executor.isCurrent else { return false }
    let turns = executor.snapshot.completedTurns
    let actuallySuspended = await executor.suspendOneTurnForTesting()
    return actuallySuspended && executor.isCurrent && executor.snapshot.completedTurns > turns
}

@Suite("Projection Memory Consumer Executor")
struct ProjectionMemoryConsumerExecutorTests {
    @Test func preferenceSurvivesNonisolatedSuspensionAndDrainsWorker() async throws {
        if #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) {
            let executor = ProjectionMemoryConsumerExecutor()
            do {
                try await withTaskExecutorPreference(executor) {
                    for _ in 0..<32 {
                        guard await crossNonisolatedSuspension(executor) else {
                            throw ConsumerFixtureError.missingAffinity
                        }
                    }
                }
            } catch {
                await executor.shutdown()
                throw error
            }
            await executor.shutdown()
            let finished = executor.snapshot
            #expect(finished.stopped && finished.liveWorkers == 0)
            #expect(finished.running == 0 && finished.pending == 0)
            #expect(finished.peakPending <= 1 && finished.completedTurns >= 32)
        } else {
            // Unsupported OS still executes its original-body route; no skip.
            let value = try await withProjectionMemoryConsumerExecutor { 32 }
            #expect(value == 32)
        }
    }

    @Test func cancellationRetainsQueuedContinuationAndAllowsShutdown() async throws {
        if #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) {
            let executor = ProjectionMemoryConsumerExecutor()
            let task = Task {
                try await withTaskExecutorPreference(executor) {
                    guard await crossNonisolatedSuspension(executor) else {
                        throw ConsumerFixtureError.missingAffinity
                    }
                    withUnsafeCurrentTask { $0?.cancel() }
                    guard await crossNonisolatedSuspension(executor), Task.isCancelled else {
                        throw ConsumerFixtureError.cancellationNotObserved
                    }
                    try Task.checkCancellation()
                }
            }
            var wasCancelled = false
            do { try await task.value }
            catch is CancellationError { wasCancelled = true }
            catch {
                task.cancel()
                await executor.shutdown()
                throw error
            }
            await executor.shutdown()
            let finished = executor.snapshot
            #expect(wasCancelled)
            #expect(finished.stopped && finished.liveWorkers == 0)
            #expect(finished.running == 0 && finished.pending == 0)
            #expect(finished.peakPending <= 1)
        } else {
            let task = Task {
                try await withProjectionMemoryConsumerExecutor {
                    withUnsafeCurrentTask { $0?.cancel() }
                    try Task.checkCancellation()
                }
            }
            var wasCancelled = false
            do { try await task.value }
            catch is CancellationError { wasCancelled = true }
            #expect(wasCancelled)
        }
    }

    @Test func explicitFallbackRunsOriginalBodyAndPreservesErrors() async throws {
        let value = try await withProjectionMemoryConsumerExecutor(preferExecutor: false) { 47 }
        #expect(value == 47)
        var preserved = false
        do {
            try await withProjectionMemoryConsumerExecutor(preferExecutor: false) {
                throw ConsumerFixtureError.missingAffinity
            }
        } catch ConsumerFixtureError.missingAffinity { preserved = true }
        #expect(preserved)
    }
}


private enum ProjectionConsumerChildFixtureError: Error { case requestedCleanup }

@Suite("Projection consumer inherited child custody")
struct ProjectionConsumerChildCustodyTests {
    @Test func twoInheritedChildrenSuspendAndJoinBeforeConsumerStops() async throws {
        if #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) {
            for failController in [false, true] {
                let executor = ProjectionMemoryConsumerExecutor()
                let crossed = LockedBox(0)
                var sawRequestedCleanup = false
                do {
                    try await withTaskExecutorPreference(executor) {
                        let child: @Sendable (Int) async throws -> Int = { value in
                            guard executor.isCurrent, await crossNonisolatedSuspension(executor) else {
                                throw ConsumerFixtureError.missingAffinity
                            }
                            crossed.withLock { $0 += 1 }
                            try Task.checkCancellation()
                            return value
                        }
                        let first = Task { try await child(1) }
                        let second = Task { try await child(2) }
                        do {
                            guard await crossNonisolatedSuspension(executor) else {
                                throw ConsumerFixtureError.missingAffinity
                            }
                            if failController { throw ProjectionConsumerChildFixtureError.requestedCleanup }
                            #expect(try await first.value == 1)
                            #expect(try await second.value == 2)
                        } catch {
                            first.cancel(); second.cancel()
                            _ = await first.result; _ = await second.result
                            throw error
                        }
                    }
                } catch ProjectionConsumerChildFixtureError.requestedCleanup {
                    sawRequestedCleanup = true
                } catch {
                    await executor.shutdown()
                    throw error
                }
                await executor.shutdown()
                let finished = executor.snapshot
                #expect(sawRequestedCleanup == failController)
                #expect(crossed.withLock { $0 } == 2)
                #expect(finished.stopped && finished.liveWorkers == 0)
                #expect(finished.pending == 0 && finished.running == 0)
                #expect(finished.peakPending <= 3 && finished.completedTurns >= 6)
            }
        } else {
            // The unchanged helper fallback still runs the affected real tests.
            let result = try await withProjectionMemoryConsumerExecutor { 47 }
            #expect(result == 47)
        }
    }
}
