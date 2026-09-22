#if os(Linux)
import Foundation
import Dispatch
import WebSocketKit
import NIOCore
import NIOPosix
@_exported import LatticeSwiftCppBridge
@_exported import LatticeSwiftModule

/// NIO callbacks retain only the endpoint for their actual dial attempt.
internal final class NIOWebsocketClient: PlatformTransportClient, @unchecked Sendable {
    private final class Attempt: @unchecked Sendable {
        let callbacks: PlatformTransportCallbacks
        private let socket = UnfairLock(initialState: Optional<WebSocket>.none)
        init(_ callbacks: PlatformTransportCallbacks) { self.callbacks = callbacks }
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
    private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    func createCxxClient() -> UnsafeMutablePointer<lattice.sync_transport>? { makePlatformTransport(self) }

    func performConnect(url urlString: String, headers: lattice.HeadersMap, callbacks: PlatformTransportCallbacks) {
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
        let attempt = Attempt(callbacks)
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
        let configuration = WebSocketClient.Configuration(maxFrameSize: 1 << 28)
        WebSocket.connect(to: url, headers: httpHeaders, configuration: configuration, on: eventLoopGroup) {
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
        }.whenFailure { [attempt] error in
            attempt.callbacks.error(error.localizedDescription)
        }
    }

    func performDisconnect() {
        let previous = state.withLockUnchecked { state in
            let previous = state.attempt
            state.attempt = nil
            return previous
        }
        previous?.close()
    }

    func performSend(_ message: lattice.transport_message, callbacks: PlatformTransportCallbacks) {
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

    func destroy() {
        let retired: (Bool, Attempt?) = state.withLockUnchecked { state in
            guard !state.destroyed else { return (false, nil) }
            state.destroyed = true
            let previous = state.attempt
            state.attempt = nil
            return (true, previous)
        }
        guard retired.0 else { return }
        retired.1?.close()
        // Native deletion can happen on this group's own callback thread.
        // Asynchronous shutdown avoids joining that thread from itself.
        eventLoopGroup.shutdownGracefully(queue: .global()) { _ in }
    }

    deinit { destroy() }
}
#endif
