import Foundation
import NIOConcurrencyHelpers
import Testing
import _Concurrency

/// Placement is evidence, not a fallback success assertion. Only the available
/// branch owns an executor; the older-platform branch reports unavailable.
enum AutomaticSetupConsumerPlacement: Sendable {
    case preferred(@Sendable () -> Bool)
    case unavailable

    func expectCurrent() {
        if case .preferred(let isCurrent) = self {
            #expect(isCurrent(), "automatic setup consumer must resume on its scoped executor")
        }
    }
}

/// One structured consumer only. Callers must not retain the placement closure
/// or launch tasks that explicitly use this executor beyond the awaited body.
func withAutomaticSetupConsumer(
    _ body: @escaping @Sendable (AutomaticSetupConsumerPlacement) async throws -> Void
) async throws {
    if #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) {
        try await withAutomaticSetupPreferredConsumer(RelayApplyFixtureExecutor(), body)
    } else {
        print("AUTOMATIC_SETUP_CONSUMER placement=unavailable")
        try await body(.unavailable)
    }
}

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private func withAutomaticSetupPreferredConsumer(
    _ executor: RelayApplyFixtureExecutor,
    _ body: @escaping @Sendable (AutomaticSetupConsumerPlacement) async throws -> Void
) async throws {
    var primary: (any Error)?
    do {
        try await withTaskExecutorPreference(executor) {
            let placement = AutomaticSetupConsumerPlacement.preferred { executor.isCurrent }
            placement.expectCurrent()
            try await body(placement)
            placement.expectCurrent()
        }
    } catch { primary = error }
    // Preference has ended, and the sole structured operation (including its
    // cleanup) has returned or thrown. No detached shutdown custodian is used.
    await executor.shutdown()
    let final = executor.snapshot
    #expect(final.stopped && final.liveWorkers == 0 && final.pending == 0 && final.running == 0)
    if let primary { throw primary }
}

private final class AutomaticSetupConsumerSentinel: Error {}

@Suite(.timeLimit(.minutes(1)))
struct AutomaticSetupConsumerExecutorTests {
    @Test func realSuspensionAndSentinelErrorJoinTheScopedConsumer() async throws {
        if #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) {
            let executor = RelayApplyFixtureExecutor()
            let sentinel = AutomaticSetupConsumerSentinel()
            let returnedFromSuspension = NIOLockedValueBox(false)
            do {
                try await withAutomaticSetupPreferredConsumer(executor) { placement in
                    placement.expectCurrent()
                    let before = executor.snapshot.completedTurns
                    let resumed = await executor.suspendOneTurnForTesting()
                    placement.expectCurrent()
                    #expect(resumed)
                    #expect(executor.snapshot.completedTurns > before)
                    returnedFromSuspension.withLockedValue { $0 = true }
                    throw sentinel
                }
                Issue.record("the scoped consumer lost its original sentinel error")
            } catch {
                let sameError = (error as? AutomaticSetupConsumerSentinel) === sentinel
                #expect(sameError)
            }
            #expect(returnedFromSuspension.withLockedValue { $0 })
            let final = executor.snapshot
            #expect(final.stopped && final.liveWorkers == 0 && final.pending == 0 && final.running == 0)
            #expect(final.completedTurns >= 2)
        } else {
            print("AUTOMATIC_SETUP_CONSUMER_SUSPENSION placement=unavailable")
        }
    }
}
