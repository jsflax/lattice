import Testing

struct ConnectedBootstrapLifecycleTests {
    @Test func failedUpgradeRequiresActualOwnedGroupJoin() {
        var value = ConnectedBootstrapLifecycle()
        value.connectFailed()
        #expect(value.failedWithoutWebSocket)
        #expect(!value.closed)
        #expect(!value.cleanupRetired(ownedGroupJoined: false))
        #expect(value.cleanupRetired(ownedGroupJoined: true))
    }

    @Test func successfulFutureBeforeUpgradeIsStillPending() {
        var value = ConnectedBootstrapLifecycle()
        value.requestClose()
        #expect(!value.closed)
        #expect(!value.cleanupRetired(ownedGroupJoined: true))
        #expect(value.didAttach())
        #expect(!value.cleanupRetired(ownedGroupJoined: true))
        value.didClose()
        #expect(value.closed)
        #expect(value.cleanupRetired(ownedGroupJoined: true))
    }

    @Test func attachedSocketRequiresOnCloseEvenAfterConnectFailure() {
        var value = ConnectedBootstrapLifecycle()
        #expect(!value.didAttach())
        value.connectFailed()
        value.requestClose()
        #expect(!value.failedWithoutWebSocket)
        #expect(!value.closed)
        #expect(!value.cleanupRetired(ownedGroupJoined: true))
        value.didClose()
        #expect(!value.cleanupRetired(ownedGroupJoined: false))
        #expect(value.cleanupRetired(ownedGroupJoined: true))
    }

    @Test func lateAttachmentRevokesFailedUnattachedCompletion() {
        var value = ConnectedBootstrapLifecycle()
        value.connectFailed()
        #expect(value.didAttach()) // The real caller closes this late socket.
        #expect(!value.closed)
        #expect(!value.cleanupRetired(ownedGroupJoined: true))
        value.didClose()
        #expect(value.cleanupRetired(ownedGroupJoined: true))
    }

    @Test func unobservedCloseCannotInventAnAttachedSocket() {
        var value = ConnectedBootstrapLifecycle()
        value.didClose()
        #expect(!value.attached)
        #expect(!value.closed)
        #expect(!value.cleanupRetired(ownedGroupJoined: true))
    }
}
