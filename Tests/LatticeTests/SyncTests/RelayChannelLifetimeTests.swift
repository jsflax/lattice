import Foundation
import Testing
import NIOConcurrencyHelpers
@testable import LatticeServerKit

@Suite("Relay channel lifetime", .timeLimit(.minutes(1)))
struct RelayChannelLifetimeTests {
    @Test func omittedGatePreservesExplicitRevocation() {
        let flag = RevocationFlag()
        flag.bind(isCurrent: nil)
        #expect(!flag.isRevoked)
        flag.revoke()
        #expect(flag.isRevoked)
    }

    @Test func withdrawnLifetimeIsStickyForTheExistingConnectionFlag() {
        let allowed = NIOLockedValueBox(true)
        let channel = SyncChannel(id: "fixture", userId: UUID(), isCurrent: { allowed.withLockedValue { $0 } })
        let state = ConnectionRelayState()
        state.revocation.bind(isCurrent: channel.isCurrent)
        #expect(!state.revocation.isRevoked)
        allowed.withLockedValue { $0 = false }
        #expect(state.revocation.isRevoked)
        allowed.withLockedValue { $0 = true }
        #expect(state.revocation.isRevoked)
    }

    @Test func callbackRevocationCannotDeadlockOrReturnAStaleAdmission() {
        let flag = RevocationFlag()
        flag.bind(isCurrent: { [weak flag] in flag?.revoke(); return true })
        #expect(flag.isRevoked)
    }

    @Test func originalGateCannotBeReplacedByANewAdmittingGate() {
        let flag = RevocationFlag()
        flag.bind(isCurrent: { true })
        flag.bind(isCurrent: { true })
        #expect(flag.isRevoked)
    }
}
