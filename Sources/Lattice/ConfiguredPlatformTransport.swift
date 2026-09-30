import Foundation
import LatticeSwiftCppBridge

// Per-call observation at real construction boundaries. The ordinary factory
// uses nil; observers can hold a boundary but cannot supply a cleanup result.
internal enum ConfiguredPlatformConstructionEvent: Sendable, Equatable {
    case registrationFinished(Bool)
    case constructionAdmitted
    case clientCreated
    case constructionFinished
}
internal typealias ConfiguredPlatformConstructionObserver = @Sendable (ConfiguredPlatformConstructionEvent) -> Void

// The native bridge admits and retains a use before reading this opaque box.
// The stock client's own drain separately protects its platform work. A box
// can be requested before it has a client, but cannot declare empty cleanup
// until its one synchronous construction has finished.
private final class ConfiguredPlatformBuilder: @unchecked Sendable {
    private struct State {
        var client: (any RetiringSystemTLSPlatformTransportClient)?
        var constructionFinished = false
        var stopping = false
    }
    let retirement: PlatformTransportRetirement
    private let state = UnfairLock(initialState: State())

    init(_ retirement: PlatformTransportRetirement) { self.retirement = retirement }

    var mayConstruct: Bool {
        state.withLockUnchecked { !$0.stopping && !$0.constructionFinished && $0.client == nil }
    }

    func attach(_ client: any RetiringSystemTLSPlatformTransportClient) {
        let stop = state.withLockUnchecked { state in
            precondition(!state.constructionFinished && state.client == nil)
            state.client = client
            return state.stopping
        }
        // A request can race actual platform construction. The already-held
        // construction Use prevents cleanup from running until attachment and
        // this synchronous factory call have both finished.
        if stop { client.destroy() }
    }

    func finishConstruction() {
        let action: (Bool, (any RetiringSystemTLSPlatformTransportClient)?) = state.withLockUnchecked { state in
            precondition(!state.constructionFinished)
            state.constructionFinished = true
            return (state.stopping, state.client)
        }
        if action.0 { stopActualClientOrEmpty(action.1) }
    }

    private func stopActualClientOrEmpty(_ client: (any RetiringSystemTLSPlatformTransportClient)?) {
        if let client { client.destroy() }
        else {
            // Called only after construction finished without allocating a
            // client. No session, resolver or event-loop group ever existed.
            retirement.drain.stop { done in done(0) }
        }
    }

    func stop() {
        let action: (Bool, (any RetiringSystemTLSPlatformTransportClient)?) = state.withLockUnchecked { state in
            state.stopping = true
            return (state.constructionFinished || state.client != nil, state.client)
        }
        if action.0 { stopActualClientOrEmpty(action.1) }
    }

    func request(_ receipt: lattice.platform_retirement_receipt) -> Bool {
        guard retirement.request(receipt) else { return false }
        stop()
        return true
    }

    private func admittedClient() -> (any RetiringSystemTLSPlatformTransportClient)? {
        state.withLockUnchecked { $0.stopping ? nil : $0.client }
    }

    func connect(url: String, headers: lattice.HeadersMap, callbacks: PlatformTransportCallbacks) {
        guard let client = admittedClient() else {
            // This is the already-admitted native bridge call, still charged
            // through return. The owned endpoint rejects a retired generation;
            // no new platform work or SDK cleanup admission is acquired here.
            callbacks.error("Configured platform connection retired before dial")
            return
        }
        client.performConnect(url: url, headers: headers, callbacks: callbacks)
    }

    func disconnect() { admittedClient()?.performDisconnect() }

    func send(_ message: lattice.transport_message, callbacks: PlatformTransportCallbacks) {
        guard let client = admittedClient() else {
            callbacks.error("Configured platform connection retired before send")
            return
        }
        client.performSend(message, callbacks: callbacks)
    }

    func verifies(url: String, callbacks: PlatformTransportCallbacks) -> Bool {
        admittedClient()?.verifiesSystemTLS(url: url, callbacks: callbacks) ?? false
    }

    deinit { stop() }
}

// Only the typed configured factory calls this function. The receipt was
// reserved by the native logical owner before the factory call. There is one
// builder, one potential client and one native adapter construction claim.
internal func makeConfiguredPlatformTransport(
    _ receipt: lattice.platform_retirement_receipt,
    constructionObservation: ConfiguredPlatformConstructionObserver? = nil,
    retirementObservation: PlatformRetirementLifecycleObserver? = nil
) -> UnsafeMutablePointer<lattice.sync_transport>? {
    guard let retirement = PlatformTransportRetirement(receipt),
          let construction = retirement.drain.admit() else { return nil }
    let builder = ConfiguredPlatformBuilder(retirement)
    defer {
        builder.finishConstruction()
        constructionObservation?(.constructionFinished)
        withExtendedLifetime(construction) {}
    }
    let owned = Unmanaged.passRetained(builder).toOpaque()
    // Native consumes this ONE retain on every path. No client exists before
    // registration, and construction custody precedes a possible request.
    let registration = lattice.register_configured_system_tls_platform_transport(
        receipt, owned,
        { pointer, url, headers, callbacks in
            guard let pointer, let url, let headers, let callbacks else { return }
            let builder = Unmanaged<ConfiguredPlatformBuilder>.fromOpaque(pointer).takeUnretainedValue()
            builder.connect(url: String(url.assumingMemoryBound(to: std.string.self).pointee),
                headers: headers.assumingMemoryBound(to: lattice.HeadersMap.self).pointee,
                callbacks: PlatformTransportCallbacks(callbacks))
        },
        { pointer in
            guard let pointer else { return }
            Unmanaged<ConfiguredPlatformBuilder>.fromOpaque(pointer).takeUnretainedValue().disconnect()
        },
        { pointer, message, callbacks in
            guard let pointer, let message, let callbacks else { return }
            Unmanaged<ConfiguredPlatformBuilder>.fromOpaque(pointer).takeUnretainedValue().send(
                message.assumingMemoryBound(to: lattice.transport_message.self).pointee,
                callbacks: PlatformTransportCallbacks(callbacks))
        },
        { pointer in
            guard let pointer else { return }
            let builder = Unmanaged<ConfiguredPlatformBuilder>.fromOpaque(pointer).takeRetainedValue()
            builder.stop()
        },
        { pointer, callbacks, url in
            guard let pointer, let callbacks, let url else { return 0 }
            return Unmanaged<ConfiguredPlatformBuilder>.fromOpaque(pointer).takeUnretainedValue().verifies(
                url: String(url.assumingMemoryBound(to: std.string.self).pointee),
                callbacks: PlatformTransportCallbacks(callbacks)) ? 1 : 0
        },
        { pointer, requested in
            guard let pointer, let requested else { return false }
            return Unmanaged<ConfiguredPlatformBuilder>.fromOpaque(pointer).takeUnretainedValue().request(
                requested.assumingMemoryBound(to: lattice.platform_retirement_receipt.self).pointee)
        })
    let registered = registration.valid()
    constructionObservation?(.registrationFinished(registered))
    guard registered, builder.mayConstruct else {
        builder.stop()
        return nil
    }
    constructionObservation?(.constructionAdmitted)
    #if os(Linux)
    let client = NIOWebsocketClient(retirement: retirement, retirementObservation: retirementObservation)
    #else
    let client = Lattice.WebsocketClient(retirement: retirement, retirementObservation: retirementObservation)
    #endif
    constructionObservation?(.clientCreated)
    builder.attach(client)
    let transport = lattice.make_configured_system_tls_platform_sync_transport(registration)
    if transport == nil { builder.stop() }
    return transport
}
