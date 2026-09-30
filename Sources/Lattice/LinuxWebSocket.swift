#if os(Linux)
import Foundation
import Dispatch
import WebSocketKit
import NIOCore
import NIOPosix
import NIOSSL
@_exported import LatticeSwiftCppBridge
@_exported import LatticeSwiftModule

/// NIO callbacks retain only the endpoint for their actual dial attempt.
internal final class NIOWebsocketClient: RetiringSystemTLSPlatformTransportClient, @unchecked Sendable {
    // Passive per-instance test observation; no TLS or callback authority.
    private let onIdentityVerificationFailure: (@Sendable () -> Void)?
    private let onFailureObservation: (@Sendable (PlatformTransportFailureObservation) -> Void)?
    private let retirement: PlatformTransportRetirement?
    private let retirementObservation: PlatformRetirementLifecycleObserver?
    init(retirement: PlatformTransportRetirement? = nil,
         retirementObservation: PlatformRetirementLifecycleObserver? = nil,
         onIdentityVerificationFailure: (@Sendable () -> Void)? = nil,
         onFailureObservation: (@Sendable (PlatformTransportFailureObservation) -> Void)? = nil) {
        self.retirement = retirement
        self.retirementObservation = retirementObservation
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        eventLoopGroup = group
        connector = retirement == nil ? nil : OwnedNIOWebSocketConnector(group: group, observation: retirementObservation)
        self.onIdentityVerificationFailure = onIdentityVerificationFailure
        self.onFailureObservation = onFailureObservation
    }
    private final class Attempt: @unchecked Sendable {
        let callbacks: PlatformTransportCallbacks
        let url: String
        let systemTLS: Bool
        private let socket = UnfairLock(initialState: Optional<WebSocket>.none)
        init(_ callbacks: PlatformTransportCallbacks, url: String, systemTLS: Bool) {
            self.callbacks = callbacks; self.url = url; self.systemTLS = systemTLS
        }
        func verified(url: String) -> Bool {
            guard systemTLS, self.url == url, callbacks.isCurrent else { return false }
            return socket.withLockUnchecked { $0.map { !$0.isClosed } ?? false }
        }
        func install(_ webSocket: WebSocket) -> Bool {
            let accepted = socket.withLockUnchecked { socket in
                guard callbacks.isCurrent, socket == nil else { return false }
                socket = webSocket
                return true
            }
            if !accepted { webSocket.close(code: .normalClosure, promise: nil) }
            return accepted
        }
        func currentSocket() -> WebSocket? { socket.withLockUnchecked { $0 } }
        func close() {
            let previous = socket.withLockUnchecked { socket in
                let previous = socket
                socket = nil
                return previous
            }
            previous?.close(code: .normalClosure, promise: nil)
        }
    }
    private struct State {
        var destroyed = false
        var attempt: Attempt?
    }
    private let state = UnfairLock(initialState: State())
    private let eventLoopGroup: MultiThreadedEventLoopGroup
    private let connector: OwnedNIOWebSocketConnector?

    func createCxxClient() -> UnsafeMutablePointer<lattice.sync_transport>? { makeSystemTLSPlatformTransport(self) }
    func verifiesSystemTLS(url: String, callbacks: PlatformTransportCallbacks) -> Bool {
        let use = retirement?.drain.admit()
        guard retirement == nil || use != nil else { return false }
        defer { withExtendedLifetime(use) {} }
        let attempt = state.withLockUnchecked { $0.destroyed ? nil : $0.attempt }
        guard let attempt, attempt.callbacks.matches(callbacks) else { return false }
        return attempt.verified(url: url)
    }

    func performConnect(url urlString: String, headers: lattice.HeadersMap, callbacks: PlatformTransportCallbacks) {
        let use = retirement?.drain.admit()
        guard retirement == nil || use != nil else {
            retirement?.reportAdmissionFailure(callbacks)
            return
        }
        defer { withExtendedLifetime(use) {} }
        guard callbacks.isCurrent else { return }
        // Reject unsupported URLs instead of reaching WebSocketKit's scheme
        // precondition. Keep the existing http(s) compatibility conversion.
        guard var components = URLComponents(string: urlString), components.host != nil else {
            callbacks.error("Invalid WebSocket URL")
            return
        }
        switch components.scheme?.lowercased() {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        case "ws": components.scheme = "ws"
        case "wss": components.scheme = "wss"
        default:
            callbacks.error("Unsupported WebSocket URL scheme")
            return
        }
        guard let url = components.string else { callbacks.error("Invalid WebSocket URL"); return }
        // Only the original wss URL qualifies. https/ws compatibility dials
        // stay legacy even when conversion happens to establish encrypted IO.
        let original = URL(string: urlString).flatMap { PlatformTLSEndpoint($0) }
        let actual = URL(string: url).flatMap { PlatformTLSEndpoint($0) }
        if let retirement, let use, !retirement.drain.claimDial(use) { return }
        let attempt = Attempt(callbacks, url: urlString, systemTLS: original != nil && original == actual)
        let replaced: (Bool, Attempt?) = state.withLockUnchecked { state in
            guard !state.destroyed, callbacks.isCurrent else { return (false, nil) }
            let previous = state.attempt
            state.attempt = attempt
            return (true, previous)
        }
        replaced.1?.close()
        guard replaced.0, callbacks.isCurrent else { return }
        var httpHeaders = NIOHTTP1.HTTPHeaders()
        headers.forEach { pair in httpHeaders.add(name: String(pair.first), value: String(pair.second)) }
        // Fixed system trust for this exact pipeline; no application verifier,
        // TLS override, proxy, or redirect handler can relax its hostname check.
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = .fullVerification
        tls.trustRoots = .default
        let configuration = WebSocketClient.Configuration(tlsConfiguration: tls, maxFrameSize: 1 << 28)
        let pending = use.flatMap { retirement?.drain.pending($0) }
        guard retirement == nil || pending != nil else {
            retirement?.reportAdmissionFailure(callbacks)
            return
        }
        let onUpgrade: @Sendable (WebSocket) -> Void = {
            [weak self, attempt] webSocket in
            guard let self else { webSocket.close(code: .normalClosure, promise: nil); return }
            let current = self.state.withLockUnchecked {
                !$0.destroyed && $0.attempt === attempt && attempt.callbacks.isCurrent
            }
            guard current, attempt.install(webSocket) else { webSocket.close(code: .normalClosure, promise: nil); return }
            webSocket.onText { [weak attempt] _, text in
                guard let attempt, attempt.callbacks.isCurrent else { return }
                attempt.callbacks.message(lattice.transport_message.from_string(std.string(text)))
            }
            webSocket.onBinary { [weak attempt] _, buffer in
                guard let attempt, attempt.callbacks.isCurrent else { return }
                var buffer = buffer
                let data = buffer.readBytes(length: buffer.readableBytes) ?? []
                var bytes = lattice.ByteVector()
                for byte in data { bytes.push_back(byte) }
                attempt.callbacks.message(lattice.transport_message.from_binary(bytes))
            }
            webSocket.onClose.whenComplete { [weak attempt, weak webSocket] _ in
                guard let attempt else { return }
                attempt.callbacks.close(
                    code: Int(webSocket?.closeCode.map { UInt16(webSocketErrorCode: $0) } ?? 1000), reason: "")
                attempt.close()
            }
            attempt.callbacks.open()
        }
        let connected: EventLoopFuture<Void>
        if let connector {
            // The same admitted lifetime covers both final connection delivery
            // and independent DNS work/notification captures. Group shutdown
            // alone cannot prove those off-loop captures have been released.
            guard let pending else { return }
            connected = connector.connect(to: url, headers: httpHeaders,
                configuration: configuration, lifetime: pending, onUpgrade: onUpgrade)
        } else {
            connected = WebSocket.connect(to: url, headers: httpHeaders,
                configuration: configuration, on: eventLoopGroup, onUpgrade: onUpgrade)
        }
        connected.whenComplete { [attempt, pending, observer = onIdentityVerificationFailure, failureObserver = onFailureObservation] result in
            defer { withExtendedLifetime(pending) {} }
            guard case .failure(let error) = result else { return }
            // Pinned NIOSSL emits this typed error after chain validation when
            // the actual peer certificate does not match the requested host/IP.
            if attempt.systemTLS, attempt.callbacks.isCurrent,
               let failure = error as? NIOSSLExtraError, failure == .failedToValidateHostname {
                observer?()
            }
            if attempt.callbacks.isCurrent {
                PlatformTransportFailureObservation.report(failureObserver, phase: .connect, error: error)
            }
            attempt.callbacks.error(error.localizedDescription)
        }
    }

    func performDisconnect() {
        let use = retirement?.drain.admit()
        guard retirement == nil || use != nil else { return }
        defer { withExtendedLifetime(use) {} }
        let previous = state.withLockUnchecked { state in
            let previous = state.attempt
            state.attempt = nil
            return previous
        }
        previous?.close()
    }

    func performSend(_ message: lattice.transport_message, callbacks: PlatformTransportCallbacks) {
        let use = retirement?.drain.admit()
        guard retirement == nil || use != nil else {
            retirement?.reportAdmissionFailure(callbacks)
            return
        }
        defer { withExtendedLifetime(use) {} }
        let attempt = state.withLockUnchecked { $0.attempt }
        guard let attempt, attempt.callbacks.matches(callbacks), callbacks.isCurrent,
              let socket = attempt.currentSocket() else { return }
        if message.msg_type == .text {
            socket.send(String(message.as_string()))
        } else {
            // Avoid the affected aarch64 CxxConvertibleToCollection path.
            let vector = message.data
            var bytes = [UInt8]()
            bytes.reserveCapacity(vector.size())
            var index = 0
            while index < vector.size() { bytes.append(vector[index]); index += 1 }
            socket.send(bytes)
        }
    }

    @discardableResult
    func requestRetirement(_ receipt: lattice.platform_retirement_receipt) -> Bool {
        guard let retirement, retirement.request(receipt) else { return false }
        destroy()
        return true
    }

    func destroy() {
        // Capture resource owners, never an escaping self from deinit. Stop
        // refuses new bridge uses and lets previously admitted calls enqueue
        // their IO before shutdown. Its platform completion is not a timeout.
        let cleanup: PlatformRetirementDrain.Cleanup = { [state, eventLoopGroup, connector, retirementObservation] done in
            let retired: (Bool, Attempt?) = state.withLockUnchecked { state in
                guard !state.destroyed else { return (false, nil) }
                state.destroyed = true
                let previous = state.attempt
                state.attempt = nil
                return (true, previous)
            }
            guard retired.0 else { return }
            retired.1?.close()
            // This callback is delivered after the group's actual shutdown;
            // never synchronously join this group's own callback thread.
            let shutdown: @Sendable () -> Void = {
                eventLoopGroup.shutdownGracefully(queue: .global()) { error in
                    let code: Int32 = error == nil ? 0 : 1
                    retirementObservation?(.nioGroupShutdown(code))
                    done(code) // SDK code 1: NIO group shutdown failed.
                }
            }
            // The stock resolver can outlive a failed connect future. Keep
            // the group alive until the owned resolver's actual worker returns
            // and its query promises have been published on that live loop.
            if let connector { connector.stopResolution(whenDrained: shutdown) }
            else { shutdown() }
        }
        if let retirement { retirement.drain.stop(cleanup) }
        else { cleanup { _ in } }
    }

    deinit { destroy() }
}
#endif
