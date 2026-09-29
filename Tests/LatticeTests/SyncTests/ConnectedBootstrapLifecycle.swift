// Copied lifecycle facts for one fixture bootstrap attempt. A failed upgrade is
// not a physical close receipt; only the separately owned event-loop join can
// retire an attempt that never supplied a WebSocket.
struct ConnectedBootstrapLifecycle: Sendable {
    private(set) var attached = false
    private(set) var closed = false
    private(set) var failedWithoutWebSocket = false
    private var closeRequested = false

    mutating func connectFailed() {
        if !attached { failedWithoutWebSocket = true }
    }

    mutating func didAttach() -> Bool {
        attached = true
        closed = false
        return closeRequested || failedWithoutWebSocket
    }

    mutating func didClose() {
        if attached { closed = true }
    }

    mutating func requestClose() { closeRequested = true }

    func cleanupRetired(ownedGroupJoined: Bool) -> Bool {
        ownedGroupJoined && (closed || (!attached && failedWithoutWebSocket))
    }
}
