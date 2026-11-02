#if os(Linux)
import Foundation
import WebSocketKit
import NIOCore
import NIOPosix
@_exported import LatticeSwiftCppBridge
@_exported import LatticeSwiftModule

/// NIO-backed WebSocket client for Linux, bridging to C++ generic_websocket_client.
internal final class NIOWebsocketClient: @unchecked Sendable {
    private var ws: WebSocket?
    private var currentState: lattice.transport_state = .closed
    private let stateLock = NSRecursiveLock()
    private var generation: UInt64 = 0
    private func withState<T>(_ body: () -> T) -> T {
        stateLock.lock(); defer { stateLock.unlock() }; return body()
    }
    private func withCurrent(_ attempt: UInt64, _ body: () -> Void) {
        withState { if generation == attempt && cxxClientPtr != nil { body() } }
    }
    private let eventLoopGroup: MultiThreadedEventLoopGroup

    // Pointer to the C++ generic_websocket_client for triggering callbacks
    private var cxxClientPtr: UnsafeMutableRawPointer?

    init() {
        eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    func createCxxClient() -> UnsafeMutableRawPointer {
        let clientPtr = Unmanaged.passRetained(self).toOpaque()

        let cxxClient = lattice.generic_sync_transport(
            clientPtr,
            // connect_fn
            { ptr, urlPtr, headersPtr in
                guard let ptr = ptr, let urlPtr = urlPtr, let headersPtr = headersPtr else { return }
                let client = Unmanaged<NIOWebsocketClient>.fromOpaque(ptr).takeUnretainedValue()
                let url = String(urlPtr.assumingMemoryBound(to: std.string.self).pointee)
                let headers = headersPtr.assumingMemoryBound(to: lattice.HeadersMap.self).pointee
                client.performConnect(url: url, headers: headers)
            },
            // disconnect_fn
            { ptr in
                guard let ptr = ptr else { return }
                let client = Unmanaged<NIOWebsocketClient>.fromOpaque(ptr).takeUnretainedValue()
                client.performDisconnect()
            },
            // state_fn
            { ptr in
                guard let ptr = ptr else { return .closed }
                let client = Unmanaged<NIOWebsocketClient>.fromOpaque(ptr).takeUnretainedValue()
                return client.withState { client.currentState }
            },
            // send_fn
            { ptr, messagePtr in
                guard let ptr = ptr, let messagePtr = messagePtr else { return }
                let client = Unmanaged<NIOWebsocketClient>.fromOpaque(ptr).takeUnretainedValue()
                let message = messagePtr.assumingMemoryBound(to: lattice.transport_message.self).pointee
                client.performSend(message)
            }
        )

        let cxxPtr = UnsafeMutablePointer<lattice.generic_sync_transport>.allocate(capacity: 1)
        cxxPtr.initialize(to: cxxClient)
        self.cxxClientPtr = UnsafeMutableRawPointer(cxxPtr)
        cxxPtr.pointee.set_destroy_callback { ptr in
            guard let ptr else { return }
            let client = Unmanaged<NIOWebsocketClient>.fromOpaque(ptr).takeRetainedValue()
            client.withState {
                client.performDisconnect()
                client.cxxClientPtr = nil
            }
        }

        return UnsafeMutableRawPointer(cxxPtr)
    }

    private func performConnect(url urlString: String, headers: lattice.HeadersMap) {
        stateLock.lock(); defer { stateLock.unlock() }
        generation &+= 1
        let attempt = generation
        _ = ws?.close(code: .normalClosure)
        ws = nil
        currentState = .connecting

        // WebSocketKit asserts ws:// or wss:// schemes; convert http(s) URLs
        let wsURL: String
        if urlString.hasPrefix("http://") {
            wsURL = "ws://" + urlString.dropFirst("http://".count)
        } else if urlString.hasPrefix("https://") {
            wsURL = "wss://" + urlString.dropFirst("https://".count)
        } else {
            wsURL = urlString
        }

        var httpHeaders = NIOHTTP1.HTTPHeaders()
        headers.forEach { keyValuePair in
            httpHeaders.add(name: String(keyValuePair.first), value: String(keyValuePair.second))
        }

        let wsConfig = WebSocketClient.Configuration(maxFrameSize: 1 << 28) // 256 MB
        WebSocket.connect(to: wsURL, headers: httpHeaders, configuration: wsConfig, on: eventLoopGroup) { [weak self] ws in
            guard let self else { _ = ws.close(code: .normalClosure); return }
            self.withState {
                guard self.generation == attempt, self.cxxClientPtr != nil else {
                    _ = ws.close(code: .normalClosure); return
                }
                self.ws = ws
                self.currentState = .open
                self.triggerOpen()

                ws.onText { [weak self] _, text in
                    self?.withCurrent(attempt) {
                        self?.triggerMessage(lattice.transport_message.from_string(std.string(text)))
                    }
                }
                ws.onBinary { [weak self] _, buffer in
                    self?.withCurrent(attempt) {
                        var buf = buffer
                        let data = buf.readBytes(length: buf.readableBytes) ?? []
                        var vec = lattice.ByteVector()
                        for byte in data { vec.push_back(byte) }
                        self?.triggerMessage(lattice.transport_message.from_binary(vec))
                    }
                }
                ws.onClose.whenComplete { [weak self] _ in
                    self?.withCurrent(attempt) {
                        self?.currentState = .closed
                        self?.ws = nil
                        self?.triggerClose(code: Int(ws.closeCode.map { UInt16(webSocketErrorCode: $0) } ?? 1000), reason: "")
                    }
                }
            }
        }.whenFailure { [weak self] error in
            self?.withCurrent(attempt) {
                self?.currentState = .closed
                self?.triggerError(error.localizedDescription)
            }
        }
    }

    private func performDisconnect() {
        stateLock.lock(); defer { stateLock.unlock() }
        generation &+= 1
        currentState = .closed
        _ = ws?.close(code: .normalClosure)
        ws = nil
        // Keep the bridge through pause/resume; destruction retires it.
    }

    private func performSend(_ message: lattice.transport_message) {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let ws = ws else { return }

        if message.msg_type == .text {
            ws.send(String(message.as_string()))
        } else {
            // Index loop, NOT Array(...): the CxxConvertibleToCollection
            // conformance for std.vector jumps through a null witness on
            // aarch64 Linux — see CxxBackend.receiveSyncData.
            let vec = message.data
            var bytes = [UInt8]()
            bytes.reserveCapacity(vec.size())
            var i = 0
            while i < vec.size() {
                bytes.append(vec[i])
                i += 1
            }
            ws.send(bytes)
        }
    }

    // MARK: - C++ trigger methods

    private func triggerOpen() {
        guard let ptr = cxxClientPtr else { return }
        ptr.assumingMemoryBound(to: lattice.generic_sync_transport.self).pointee.trigger_on_open()
    }

    private func triggerMessage(_ message: lattice.transport_message) {
        guard let ptr = cxxClientPtr else { return }
        ptr.assumingMemoryBound(to: lattice.generic_sync_transport.self).pointee.trigger_on_message(message)
    }

    private func triggerError(_ error: String) {
        guard let ptr = cxxClientPtr else { return }
        ptr.assumingMemoryBound(to: lattice.generic_sync_transport.self).pointee.trigger_on_error(std.string(error))
    }

    private func triggerClose(code: Int, reason: String) {
        guard let ptr = cxxClientPtr else { return }
        ptr.assumingMemoryBound(to: lattice.generic_sync_transport.self).pointee.trigger_on_close(Int32(code), std.string(reason))
    }

    deinit {
        // The final callback may release this object on its own event loop.
        // Asynchronous shutdown avoids joining that same thread.
        eventLoopGroup.shutdownGracefully(queue: .global()) { _ in }
    }
}
#endif
