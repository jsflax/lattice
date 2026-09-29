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
        let closeAfterAttach = value.didAttach()
        #expect(closeAfterAttach)
        #expect(!value.cleanupRetired(ownedGroupJoined: true))
        value.didClose()
        #expect(value.closed)
        #expect(value.cleanupRetired(ownedGroupJoined: true))
    }

    @Test func attachedSocketRequiresOnCloseEvenAfterConnectFailure() {
        var value = ConnectedBootstrapLifecycle()
        let closeAfterAttach = value.didAttach()
        #expect(!closeAfterAttach)
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
        let closeAfterAttach = value.didAttach() // The real caller closes this late socket.
        #expect(closeAfterAttach)
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
