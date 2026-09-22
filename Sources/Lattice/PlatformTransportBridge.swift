import Foundation
@_exported import LatticeSwiftCppBridge
@_exported import LatticeSwiftModule

// Owns a native callback cell, never a pointer to a transport or synchronizer.
// This proves only the connect attempt's lifetime, not TLS/source authority.
internal final class PlatformTransportCallbacks: @unchecked Sendable {
    private let endpoint: lattice.platform_transport_callbacks
    init(_ pointer: UnsafeRawPointer) {
        endpoint = pointer.assumingMemoryBound(to: lattice.platform_transport_callbacks.self).pointee
    }
    var isCurrent: Bool { endpoint.is_current() }
    func matches(_ other: PlatformTransportCallbacks) -> Bool { endpoint.matches(other.endpoint) }
    @discardableResult func open() -> Bool { endpoint.trigger_on_open() }
    @discardableResult func message(_ message: lattice.transport_message) -> Bool {
        endpoint.trigger_on_message(message)
    }
    @discardableResult func error(_ error: String) -> Bool {
        endpoint.trigger_on_error(std.string(error))
    }
    @discardableResult func close(code: Int, reason: String) -> Bool {
        endpoint.trigger_on_close(Int32(code), std.string(reason))
    }
}

internal protocol PlatformTransportClient: AnyObject {
    func performConnect(url: String, headers: lattice.HeadersMap, callbacks: PlatformTransportCallbacks)
    func performDisconnect()
    func performSend(_ message: lattice.transport_message, callbacks: PlatformTransportCallbacks)
    // Nonblocking, idempotent; may run on a platform callback thread.
    func destroy()
}

private final class PlatformTransportOwner {
    let client: any PlatformTransportClient
    init(_ client: any PlatformTransportClient) { self.client = client }
}

internal func makePlatformTransport(_ client: any PlatformTransportClient) -> UnsafeMutablePointer<lattice.sync_transport>? {
    let retained = Unmanaged.passRetained(PlatformTransportOwner(client)).toOpaque()
    // Native factory consumes retained even if its allocation fails. It owns
    // the C++ allocation and releases the Swift owner on native destruction.
    return lattice.make_owned_platform_sync_transport(
        retained,
        { pointer, url, headers, callbacks in
            guard let pointer, let url, let headers, let callbacks else { return }
            let owner = Unmanaged<PlatformTransportOwner>.fromOpaque(pointer).takeUnretainedValue()
            owner.client.performConnect(
                url: String(url.assumingMemoryBound(to: std.string.self).pointee),
                headers: headers.assumingMemoryBound(to: lattice.HeadersMap.self).pointee,
                callbacks: PlatformTransportCallbacks(callbacks))
        },
        { pointer in
            guard let pointer else { return }
            Unmanaged<PlatformTransportOwner>.fromOpaque(pointer).takeUnretainedValue().client.performDisconnect()
        },
        { pointer, message, callbacks in
            guard let pointer, let message, let callbacks else { return }
            let owner = Unmanaged<PlatformTransportOwner>.fromOpaque(pointer).takeUnretainedValue()
            owner.client.performSend(
                message.assumingMemoryBound(to: lattice.transport_message.self).pointee,
                callbacks: PlatformTransportCallbacks(callbacks))
        },
        { pointer in
            guard let pointer else { return }
            let owner = Unmanaged<PlatformTransportOwner>.fromOpaque(pointer).takeRetainedValue()
            owner.client.destroy()
        })
}
