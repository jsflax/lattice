import Foundation
@_exported import LatticeSwiftCppBridge
@_exported import LatticeSwiftModule

// Owns a native callback cell, never a pointer to a transport or synchronizer.
// This proves only the connect attempt's lifetime, not TLS/source authority.
// TLS verification is obtained separately from the actual system adapter.
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

// Internal Swift SDK adapter boundary. The companion C++ factory is callable
// by a trusted native host and accepts its verifier callbacks; it is not a
// cryptographic boundary against malicious in-process code replacing the SDK.
// App expectation strings and the generic legacy factory never install TLS
// evidence. Native retains verification context across late endpoint calls.
internal protocol SystemTLSPlatformTransportClient: PlatformTransportClient {
    func verifiesSystemTLS(url: String, callbacks: PlatformTransportCallbacks) -> Bool
}
private final class SystemTLSVerificationOwner {
    let client: any SystemTLSPlatformTransportClient
    init(_ client: any SystemTLSPlatformTransportClient) { self.client = client }
}
internal func makeSystemTLSPlatformTransport(_ client: any SystemTLSPlatformTransportClient) -> UnsafeMutablePointer<lattice.sync_transport>? {
    let retained = Unmanaged.passRetained(PlatformTransportOwner(client)).toOpaque()
    let verification = Unmanaged.passRetained(SystemTLSVerificationOwner(client)).toOpaque()
    return lattice.make_system_tls_platform_sync_transport(
        retained,
        { pointer, url, headers, callbacks in
            guard let pointer, let url, let headers, let callbacks else { return }
            let owner = Unmanaged<PlatformTransportOwner>.fromOpaque(pointer).takeUnretainedValue()
            owner.client.performConnect(url: String(url.assumingMemoryBound(to: std.string.self).pointee),
                headers: headers.assumingMemoryBound(to: lattice.HeadersMap.self).pointee,
                callbacks: PlatformTransportCallbacks(callbacks))
        },
        { pointer in
            guard let pointer else { return }
            Unmanaged<PlatformTransportOwner>.fromOpaque(pointer).takeUnretainedValue().client.performDisconnect()
        },
        { pointer, message, callbacks in
            guard let pointer, let message, let callbacks else { return }
            Unmanaged<PlatformTransportOwner>.fromOpaque(pointer).takeUnretainedValue().client.performSend(
                message.assumingMemoryBound(to: lattice.transport_message.self).pointee,
                callbacks: PlatformTransportCallbacks(callbacks))
        },
        { pointer in
            guard let pointer else { return }
            let owner = Unmanaged<PlatformTransportOwner>.fromOpaque(pointer).takeRetainedValue()
            owner.client.destroy()
        }, verification,
        { pointer, callbacks, url in
            guard let pointer, let callbacks, let url else { return 0 }
            let owner = Unmanaged<SystemTLSVerificationOwner>.fromOpaque(pointer).takeUnretainedValue()
            return owner.client.verifiesSystemTLS(
                url: String(url.assumingMemoryBound(to: std.string.self).pointee),
                callbacks: PlatformTransportCallbacks(callbacks)) ? 1 : 0
        },
        { pointer in
            guard let pointer else { return }
            let owner = Unmanaged<SystemTLSVerificationOwner>.fromOpaque(pointer).takeRetainedValue()
            withExtendedLifetime(owner) {}
        })
}
// Pure origin/endpoint comparison, never a TLS verifier. Callers must separately
// prove the actual system handshake. HTTP(S) aliases cannot make a legacy dial
// authoritative; only an original wss request is eligible.
internal struct PlatformTLSEndpoint: Equatable, Sendable {
    let host: String
    let port: Int
    let path: String
    let query: String?
    init?(_ url: URL, actualTask: Bool = false) {
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = value.scheme?.lowercased(), scheme == "wss" || (actualTask && scheme == "https"),
              let host = value.host?.lowercased(), !host.isEmpty,
              value.user == nil, value.password == nil, value.fragment == nil else { return nil }
        self.host = host; port = value.port ?? 443
        guard (1...65535).contains(port) else { return nil }
        path = value.percentEncodedPath.isEmpty ? "/" : value.percentEncodedPath
        query = value.percentEncodedQuery
    }
}
