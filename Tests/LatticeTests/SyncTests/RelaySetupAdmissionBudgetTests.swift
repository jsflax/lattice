import Foundation
import Testing
import NIOConcurrencyHelpers
@testable import LatticeServerKit

@Suite("Bounded source setup admission bookkeeping")
struct RelaySetupAdmissionBudgetTests {
    @Test func exactThirtyTwoAttemptsCannotBecomeAnUnboundedBusyLoop() {
        var budget = RelaySetupAdmissionBudget(now: 1_000)
        let originalDeadline = budget.deadline
        var now: UInt64 = 1_000
        for attempt in 1...32 {
            let admitted = budget.beginAttempt(now: now)
            #expect(admitted)
            #expect(budget.attempts == attempt)
            let duplicate = budget.beginAttempt(now: now)
            #expect(!duplicate)
            let next = budget.busyReturned(now: now)
            if attempt < 32 {
                #expect(next == now + 100_000_000)
                let early = budget.beginAttempt(now: now + 99_999_999)
                #expect(!early)
            } else { #expect(next == nil) }
            #expect(budget.deadline == originalDeadline)
            now += 100_000_000
        }
        let beyond = budget.beginAttempt(now: now)
        #expect(!beyond)
        #expect(budget.attempts == 32)
        #expect(now - budget.startedAt == 3_200_000_000)
    }

    @Test func QueueDelayCountsAndDeadlineIsExclusive() {
        var atBoundary = RelaySetupAdmissionBudget(now: 200)
        let admitted = atBoundary.beginAttempt(now: atBoundary.deadline)
        #expect(!admitted)
        #expect(atBoundary.attempts == 0)
        var justBefore = RelaySetupAdmissionBudget(now: 200)
        let inside = justBefore.beginAttempt(now: justBefore.deadline - 1)
        #expect(inside)
        // Last admissible attempt may cross the deadline before busy returns.
        let after = justBefore.busyReturned(now: justBefore.deadline)
        #expect(after == nil)
    }

    @Test func delayedBusyCannotExtendTheOriginalAbsoluteBound() {
        var budget = RelaySetupAdmissionBudget(now: 100)
        let first = budget.beginAttempt(now: 100)
        #expect(first)
        let next = budget.busyReturned(now: budget.deadline - 1)
        #expect(next == budget.deadline)
        let late = budget.beginAttempt(now: next!)
        #expect(!late)
        #expect(budget.attempts == 1)
        #expect(budget.deadline == 5_000_000_100)
    }

    @Test func duplicateBusyAndEarlyClockValuesCannotMintAttempts() {
        var budget = RelaySetupAdmissionBudget(now: 100)
        let before = budget.beginAttempt(now: 99)
        let invented = budget.busyReturned(now: 100)
        #expect(!before); #expect(invented == nil)
        let actual = budget.beginAttempt(now: 100)
        #expect(actual)
        let next = budget.busyReturned(now: 100)
        let duplicate = budget.busyReturned(now: 100)
        #expect(next == 100_000_100); #expect(duplicate == nil)
        #expect(budget.attempts == 1)
    }

    @Test func cancellationAndCompletionNeverResetTheEpisode() {
        var stopped = RelaySetupAdmissionBudget(now: 100)
        stopped.cancel()
        let admitted = stopped.beginAttempt(now: 101)
        #expect(!admitted); #expect(!stopped.admissible(now: 101))
        var complete = RelaySetupAdmissionBudget(now: 100)
        let first = complete.beginAttempt(now: 100)
        #expect(first)
        complete.complete()
        let next = complete.busyReturned(now: 101)
        let again = complete.beginAttempt(now: 101)
        #expect(next == nil); #expect(!again)
        #expect(complete.attempts == 1)
    }

    @Test func finalPermittedAttemptStillPassesPreEffectVeto() {
        var budget = RelaySetupAdmissionBudget(now: 0)
        for index in 0..<32 {
            let now = UInt64(index) * 100_000_000
            let admitted = budget.beginAttempt(now: now)
            #expect(admitted)
            // A cap check in admissible would reject the actual 32nd attempt.
            #expect(budget.admissible(now: now))
            if index < 31 { _ = budget.busyReturned(now: now) }
        }
        #expect(budget.attempts == 32)
    }

    @Test func saturatedClockAdditionNeverWrapsToAnImmediateOldDeadline() {
        var budget = RelaySetupAdmissionBudget(now: UInt64.max - 10)
        #expect(budget.deadline == UInt64.max)
        let first = budget.beginAttempt(now: UInt64.max - 10)
        #expect(first)
        let next = budget.busyReturned(now: UInt64.max - 9)
        #expect(next == UInt64.max)
        let expired = budget.beginAttempt(now: UInt64.max)
        #expect(!expired)
    }

    @Test func stopObservationIsOnceAndInvokedOffLifetimeLeaf() {
        let lifetime = RecoveryRelayLifetime()
        let calls = NIOLockedValueBox(0)
        let observer = RecoveryRelaySetupStopObservation {
            // This acquires the same lifetime lock; invocation must be off it.
            #expect(lifetime.isStopped)
            calls.withLockedValue { $0 += 1 }
        }
        lifetime.observeSetupStop(observer)
        lifetime.stop(); lifetime.stop()
        lifetime.removeSetupStop(observer)
        #expect(calls.withLockedValue { $0 } == 1)
    }

    @Test func alreadyStoppedRegistrationCannotLoseCancellation() {
        let lifetime = RecoveryRelayLifetime()
        lifetime.stop()
        let calls = NIOLockedValueBox(0)
        let observer = RecoveryRelaySetupStopObservation { calls.withLockedValue { $0 += 1 } }
        lifetime.observeSetupStop(observer)
        lifetime.removeSetupStop(observer)
        #expect(calls.withLockedValue { $0 } == 1)
    }

    @Test func removedObservationDoesNotCancelAnAuthorizedLifetime() {
        let lifetime = RecoveryRelayLifetime()
        let calls = NIOLockedValueBox(0)
        let observer = RecoveryRelaySetupStopObservation { calls.withLockedValue { $0 += 1 } }
        lifetime.observeSetupStop(observer)
        lifetime.removeSetupStop(observer)
        lifetime.stop()
        #expect(calls.withLockedValue { $0 } == 0)
    }
}
