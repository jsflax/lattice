import Foundation
import Testing
@testable import Lattice

// These exercise ordering in the SDK drain only. They cannot issue a native
// receipt, stand in for a real URLSession/NIO shutdown, or qualify recovery.
@Suite struct PlatformRetirementDrainTests {
    @Test func admittedBridgeCallDefersCleanupAndRejectsNewCalls() {
        let drain = PlatformRetirementDrain()
        let observed = UnfairLock(initialState: [String]())
        var use = drain.admit()
        #expect(use != nil)
        #expect(drain.request { _ in observed.withLockUnchecked { $0.append("complete") } })
        drain.stop { done in
            observed.withLockUnchecked { $0.append("cleanup") }
            done(0)
            // Inline platform completion must not run the native signal while
            // the cleanup initiation is still on the stack.
            #expect(observed.withLockUnchecked { $0 } == ["cleanup"])
        }
        #expect(drain.admit() == nil)
        #expect(observed.withLockUnchecked { $0.isEmpty })
        withExtendedLifetime(use) {}
        use = nil
        #expect(observed.withLockUnchecked { $0 } == ["cleanup", "complete"])
    }

    @Test func asyncCallbackLifetimeOutlastsBridgeAndPlatformCompletion() throws {
        let drain = PlatformRetirementDrain()
        let completions = UnfairLock(initialState: [Int32]())
        var use: PlatformRetirementDrain.Use? = try #require(drain.admit())
        var pending = drain.pending(try #require(use))
        #expect(pending != nil)
        #expect(drain.request { error in completions.withLockUnchecked { $0.append(error) } })
        use = nil
        drain.stop { $0(0) }
        #expect(completions.withLockUnchecked { $0.isEmpty })
        withExtendedLifetime(pending) {}
        pending = nil
        #expect(completions.withLockUnchecked { $0 } == [0])
    }

    @Test func missingPlatformCompletionNeverBecomesSuccess() {
        let drain = PlatformRetirementDrain()
        let completions = UnfairLock(initialState: [Int32]())
        #expect(drain.request { error in completions.withLockUnchecked { $0.append(error) } })
        drain.stop { _ in }
        #expect(completions.withLockUnchecked { $0.isEmpty })
        #expect(drain.admit() == nil)
    }

    @Test func platformCompletionBeforeRequestIsRetainedWithoutSynthesizingARequest() {
        let drain = PlatformRetirementDrain()
        let completions = UnfairLock(initialState: [Int32]())
        drain.stop { $0(2) }
        #expect(completions.withLockUnchecked { $0.isEmpty })
        #expect(drain.request { error in completions.withLockUnchecked { $0.append(error) } })
        #expect(completions.withLockUnchecked { $0 } == [2])
    }

    @Test func duplicateCleanupAndDuplicatePlatformSignalsKeepFirstResult() {
        let drain = PlatformRetirementDrain()
        let completions = UnfairLock(initialState: [Int32]())
        let cleanupCount = UnfairLock(initialState: 0)
        #expect(drain.request { error in completions.withLockUnchecked { $0.append(error) } })
        drain.stop { done in
            cleanupCount.withLockUnchecked { $0 += 1 }
            done(1)
            done(0)
        }
        drain.stop { done in cleanupCount.withLockUnchecked { $0 += 1 }; done(0) }
        #expect(!drain.request { _ in completions.withLockUnchecked { $0.append(99) } })
        #expect(cleanupCount.withLockUnchecked { $0 } == 1)
        #expect(completions.withLockUnchecked { $0 } == [1])
    }

    @Test func onlyTheActualAdmittedCallCanClaimOneDialAndPendingWork() throws {
        let drain = PlatformRetirementDrain()
        let other = PlatformRetirementDrain()
        let use = try #require(drain.admit())
        let foreign = try #require(other.admit())
        #expect(!drain.claimDial(foreign))
        #expect(drain.pending(foreign) == nil)
        #expect(drain.claimDial(use))
        #expect(!drain.claimDial(use))
    }

    @Test func alreadyAdmittedCallCanRegisterLateAsyncWorkAfterStop() throws {
        let drain = PlatformRetirementDrain()
        let completions = UnfairLock(initialState: [Int32]())
        var use: PlatformRetirementDrain.Use? = try #require(drain.admit())
        #expect(drain.request { error in completions.withLockUnchecked { $0.append(error) } })
        drain.stop { $0(0) }
        var pending = drain.pending(try #require(use))
        #expect(pending != nil)
        use = nil
        #expect(completions.withLockUnchecked { $0.isEmpty })
        withExtendedLifetime(pending) {}
        pending = nil
        #expect(completions.withLockUnchecked { $0 } == [0])
    }

    @Test func completionCanReenterWithoutLeafLockOrSecondSignal() {
        let drain = PlatformRetirementDrain()
        let count = UnfairLock(initialState: 0)
        let accepted = drain.request { _ in
            #expect(drain.admit() == nil)
            #expect(!drain.request { _ in count.withLockUnchecked { $0 += 100 } })
            drain.stop { $0(99) }
            count.withLockUnchecked { $0 += 1 }
        }
        #expect(accepted)
        drain.stop { $0(0) }
        #expect(count.withLockUnchecked { $0 } == 1)
    }

    @Test func bridgeCapacityFailureRetainsAllAdmittedUsesAndSignalsOnceAfterCleanup() throws {
        let drain = PlatformRetirementDrain()
        let completions = UnfairLock(initialState: [Int32]())
        var uses: [PlatformRetirementDrain.Use] = []
        for _ in 0..<PlatformRetirementDrain.maximumUses {
            uses.append(try #require(drain.admit()))
        }
        #expect(drain.admit() == nil)
        #expect(drain.admissionFailure == PlatformRetirementDrain.capacityError)
        var notification: PlatformRetirementDrain.Use? = try #require(drain.takeAdmissionFailureNotification())
        #expect(drain.takeAdmissionFailureNotification() == nil)
        #expect(!drain.claimDial(try #require(notification)))
        #expect(drain.pending(try #require(notification)) == nil)
        #expect(drain.request { error in completions.withLockUnchecked { $0.append(error) } })
        drain.stop { $0(0) }
        #expect(completions.withLockUnchecked { $0.isEmpty })
        uses.removeAll()
        #expect(completions.withLockUnchecked { $0.isEmpty })
        withExtendedLifetime(notification) {}
        notification = nil
        #expect(completions.withLockUnchecked { $0 } == [PlatformRetirementDrain.capacityError])
        #expect(drain.admit() == nil)
    }

    @Test func pendingCapacityFailureNeverEvictsAnOutstandingCallback() throws {
        let drain = PlatformRetirementDrain()
        let completions = UnfairLock(initialState: [Int32]())
        var use: PlatformRetirementDrain.Use? = try #require(drain.admit())
        var pending: [PlatformRetirementDrain.Pending] = []
        for _ in 0..<PlatformRetirementDrain.maximumPending {
            let admitted = try #require(use)
            let callback = try #require(drain.pending(admitted))
            pending.append(callback)
        }
        #expect(drain.pending(try #require(use)) == nil)
        #expect(drain.admit() == nil)
        #expect(drain.request { error in completions.withLockUnchecked { $0.append(error) } })
        use = nil
        drain.stop { $0(0) }
        #expect(completions.withLockUnchecked { $0.isEmpty })
        pending.removeAll()
        #expect(completions.withLockUnchecked { $0 } == [PlatformRetirementDrain.capacityError])
        #expect(drain.takeAdmissionFailureNotification() == nil)
    }
}
