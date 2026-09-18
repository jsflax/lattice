import Foundation
import Testing

@Suite("Socket readiness cancellation")
struct SocketStoreCancellationTests {
    @Test func cancellationBeforeRegistrationDoesNotParkOrRetainAWaiter() async {
        let store = SocketStore(label: "cancel-before-ready")
        let cancelled = await Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await store.waitForCountOrCancellation(1)
                return false
            } catch is CancellationError {
                return true
            } catch {
                Issue.record("Unexpected readiness error: \(error)")
                return false
            }
        }.value
        #expect(cancelled)
        #expect(store.cancellableCountWaitersForTesting == 0)
    }

    @Test(arguments: [0, 1])
    func cancellationAfterReadySelectionOrQueueRegistrationResumesOnce(target: Int) async {
        let store = SocketStore(label: "cancel-after-registration")
        let cancelled = await Task { () -> Bool in
            do {
                try await store.waitForCountOrCancellation(target, afterRegistrationForTesting: {
                    #expect(store.cancellableCountWaitersForTesting == (target == 0 ? 0 : 1))
                    // target0: ready has selected success but not resumed it.
                    // target1: the continuation is queued. Exercise both sides
                    // of exactly-once completion without a sleep or OS wait.
                    withUnsafeCurrentTask { $0?.cancel() }
                })
                return false
            } catch is CancellationError {
                return true
            } catch {
                Issue.record("Unexpected readiness error: \(error)")
                return false
            }
        }.value
        #expect(cancelled)
        #expect(store.cancellableCountWaitersForTesting == 0)
    }

    @Test func alreadyReadyReturnsWithoutRetainingAWaiter() async throws {
        let store = SocketStore(label: "already-ready")
        try await store.waitForCountOrCancellation(0)
        #expect(store.cancellableCountWaitersForTesting == 0)
    }
}
