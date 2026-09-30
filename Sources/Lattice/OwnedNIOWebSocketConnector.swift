#if os(Linux)
import Foundation
import Dispatch
import Glibc
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import NIOSSL
import WebSocketKit

// Inactive, opt-in Linux adapter support. The caller retains this owner and its
// group, and does not call stopResolution until its admitted connect call has
// returned. Native receipt admission still belongs to the configured factory.
//
// Pipeline/request construction is adapted from vapor/websocket-kit at
// 90bbbdab3ede12c803cfbe91646f291c092517a3, WebSocketClient.swift and
// HTTPUpgradeRequestHandler.swift (MIT; attribution in the companion notice).
// Resolver ordering follows apple/swift-nio at
// 57c0a08a331aaea9f5d7a932ad94ef43be942a95, GetaddrinfoResolver.swift
// (Apache-2.0; attribution in the companion notice). Unlike that resolver, this
// owner observes actual off-loop work completion before allowing group shutdown.
internal final class OwnedNIOWebSocketConnector: @unchecked Sendable {
    private let loop: any EventLoop
    private let observation: PlatformRetirementLifecycleObserver?
    private struct State {
        var claimed = false
        var stopped = false
        var resolver: OwnedNIOResolver?
    }
    private let state = UnfairLock(initialState: State())

    init(group: MultiThreadedEventLoopGroup, observation: PlatformRetirementLifecycleObserver? = nil) {
        self.observation = observation
        // This is the adapter's dedicated one-thread group. Pin both bootstrap
        // and resolver promises to this exact loop, including shutdown ordering.
        loop = group.next()
    }

    func connect(to rawURL: String, headers: HTTPHeaders,
                 configuration: WebSocketClient.Configuration,
                 lifetime: PlatformRetirementDrain.Pending,
                 onUpgrade: @escaping @Sendable (WebSocket) -> Void) -> EventLoopFuture<Void> {
        guard let url = URL(string: rawURL), let scheme = url.scheme,
              scheme == "ws" || scheme == "wss" else {
            return loop.makeFailedFuture(WebSocketClient.Error.invalidURL)
        }
        let host = url.host ?? "localhost"
        let port = url.port ?? (scheme == "wss" ? 443 : 80)
        guard (1...65535).contains(port) else {
            return loop.makeFailedFuture(WebSocketClient.Error.invalidURL)
        }
        let resolver = state.withLockUnchecked { state -> OwnedNIOResolver? in
            guard !state.stopped, !state.claimed else { return nil }
            state.claimed = true
            let resolver = OwnedNIOResolver(loop: loop, host: host, port: port, lifetime: lifetime, observation: observation)
            state.resolver = resolver
            return resolver
        }
        guard let resolver else { return loop.makeFailedFuture(WebSocketClient.Error.alreadyShutdown) }

        let upgrade = loop.makePromise(of: Void.self)
        let bootstrap = ClientBootstrap(group: loop)
            .resolver(resolver)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelInitializer { channel -> EventLoopFuture<Void> in
                let request = OwnedNIOUpgradeRequestHandler(host: host, path: url.path,
                    query: url.query, headers: headers, upgrade: upgrade)
                let requestBox = NIOLoopBound(request, eventLoop: channel.eventLoop)
                let upgrader = NIOWebSocketClientUpgrader(maxFrameSize: configuration.maxFrameSize,
                    automaticErrorHandling: true) { channel, _ in
                        var frames = WebSocket.Configuration()
                        frames.minNonFinalFragmentSize = configuration.minNonFinalFragmentSize
                        frames.maxAccumulatedFrameCount = configuration.maxAccumulatedFrameCount
                        frames.maxAccumulatedFrameSize = configuration.maxAccumulatedFrameSize
                        return WebSocket.client(on: channel, config: frames, onUpgrade: onUpgrade)
                    }
                let upgradeConfiguration: NIOHTTPClientUpgradeConfiguration = (
                    upgraders: [upgrader],
                    completionHandler: { _ in
                        upgrade.succeed(())
                        channel.pipeline.syncOperations.removeHandler(requestBox.value, promise: nil)
                    }
                )
                let upgradeBox = NIOLoopBound(upgradeConfiguration, eventLoop: channel.eventLoop)
                if scheme == "wss" {
                    do {
                        let context = try NIOSSLContext(configuration:
                            configuration.tlsConfiguration ?? .makeClientConfiguration())
                        let tls: NIOSSLClientHandler
                        do { tls = try NIOSSLClientHandler(context: context, serverHostname: host) }
                        catch let error as NIOSSLExtraError where error == .cannotUseIPAddressInSNI {
                            tls = try NIOSSLClientHandler(context: context, serverHostname: nil)
                        }
                        try channel.pipeline.syncOperations.addHandler(tls)
                    } catch {
                        // Preserve the actual failure and settle the future even
                        // when no HTTP request handler could yet be installed.
                        channel.close(promise: nil)
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
                return channel.eventLoop.submit {
                    try channel.pipeline.syncOperations.addHTTPClientHandlers(
                        leftOverBytesStrategy: .forwardBytes, withClientUpgrade: upgradeBox.value)
                    try channel.pipeline.syncOperations.addHandler(requestBox.value)
                }
            }
        let connected = bootstrap.connect(host: host, port: port)
        connected.cascadeFailure(to: upgrade)
        return connected.flatMap { _ in upgrade.futureResult }
    }

    // Exactly one cleanup request belongs to the adapter's once-only drain.
    // This does not join/block a thread. A libc lookup that never returns keeps
    // its actual adapter/resource charge pending; a timeout is not completion.
    func stopResolution(whenDrained completion: @escaping @Sendable () -> Void) {
        let resolver = state.withLockUnchecked { state in
            state.stopped = true
            return state.resolver
        }
        if let resolver { resolver.stop(whenDrained: completion) }
        else { loop.execute(completion) }
    }
}

private final class OwnedNIOResolver: Resolver, @unchecked Sendable {
    private struct Addresses: Sendable {
        var ipv4: [SocketAddress] = []
        var ipv6: [SocketAddress] = []
    }
    private enum LookupError: Swift.Error, Sendable {
        case cancelled, mismatchedQuery, emptyResult, invalidAddress, tooManyAddresses
        case lookupFailed(Int32), unsupportedFamily(Int32)
    }
    // This is an independent SDK result-storage ceiling, not native request
    // authority. Reject an overlarge answer explicitly; never truncate addresses.
    private static let maximumAddresses = 256
    private let loop: any EventLoop
    private let host: String
    private let port: Int
    private let observation: PlatformRetirementLifecycleObserver?
    private let ipv4: EventLoopPromise<[SocketAddress]>
    private let ipv6: EventLoopPromise<[SocketAddress]>
    private let workerQueue = DispatchQueue(label: "lattice.owned-dns")
    // The following state is confined to loop. Dispatch workers only produce a
    // result in their separate locked box; they never touch these fields.
    private var workerStarted = false
    private var workerFinished = false
    private var stopping = false
    private var published = false
    private var publishing = false
    private var drainCompletion: (@Sendable () -> Void)?
    private var resolutionLifetime: PlatformRetirementDrain.Pending?

    init(loop: any EventLoop, host: String, port: Int, lifetime: PlatformRetirementDrain.Pending,
         observation: PlatformRetirementLifecycleObserver?) {
        self.observation = observation
        self.loop = loop; self.host = host; self.port = port
        resolutionLifetime = lifetime
        ipv4 = loop.makePromise(); ipv6 = loop.makePromise()
    }

    func initiateAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        loop.preconditionInEventLoop()
        guard host == self.host, port == self.port else { return loop.makeFailedFuture(LookupError.mismatchedQuery) }
        startIfNeeded()
        return ipv4.futureResult
    }

    func initiateAAAAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        loop.preconditionInEventLoop()
        guard host == self.host, port == self.port else { return loop.makeFailedFuture(LookupError.mismatchedQuery) }
        startIfNeeded()
        return ipv6.futureResult
    }

    // Happy Eyeballs cancellation is a request, not proof that libc returned.
    // Close query admission, but never discard worker custody or claim drained.
    func cancelQueries() {
        loop.preconditionInEventLoop()
        stopping = true
        if !workerStarted { cancelUnstartedReservation() }
        finishDrainIfPossible()
    }

    func stop(whenDrained completion: @escaping @Sendable () -> Void) {
        loop.execute { [self] in
            // The adapter only registers once; do not replace retained custody
            // with a second callback while actual work is still outstanding.
            guard drainCompletion == nil else { return }
            drainCompletion = completion
            stopping = true
            if !workerStarted { cancelUnstartedReservation() }
            finishDrainIfPossible()
        }
    }

    private func startIfNeeded() {
        loop.preconditionInEventLoop()
        if stopping { cancelUnstartedReservation(); return }
        guard !workerStarted else { return }
        // Transfer the reservation into each actual work/delivery closure.
        // Keeping it on this retained resolver would make retirement cyclic.
        guard let lifetime = resolutionLifetime else {
            stopping = true
            publish(.failure(.cancelled))
            return
        }
        resolutionLifetime = nil
        workerStarted = true
        let result = UnfairLock(initialState: Optional<Result<Addresses, LookupError>>.none)
        let host = host, port = port, observation = observation
        let work = DispatchWorkItem { [lifetime] in
            defer { withExtendedLifetime(lifetime) {} }
            let resolved = Self.resolve(host: host, port: port)
            observation?(.dnsWorkReturned)
            result.withLockUnchecked { $0 = resolved }
        }
        // notify is registered before dispatch and fires after the actual work
        // item returns, including freeaddrinfo and its local result construction.
        // The shared Pending also spans the separate notification closure: it
        // may outlive publication/group shutdown after enqueueing onto loop.
        work.notify(queue: .global()) { [self, lifetime] in
            defer { withExtendedLifetime(lifetime) {} }
            let resolved = result.withLockUnchecked { $0! }
            loop.execute { [self, lifetime] in
                defer { withExtendedLifetime(lifetime) {} }
                workerFinished = true
                publish(stopping ? .failure(.cancelled) : resolved)
                observation?(.dnsQueriesPublished)
                finishDrainIfPossible()
            }
            observation?(.dnsNotifyEnqueued)
        }
        workerQueue.async(execute: work)
    }

    private func cancelUnstartedReservation() {
        loop.preconditionInEventLoop()
        guard !workerStarted else { return }
        let lifetime = resolutionLifetime
        resolutionLifetime = nil
        defer { withExtendedLifetime(lifetime) {} }
        publish(.failure(.cancelled))
    }

    private static func resolve(host: String, port: Int) -> Result<Addresses, LookupError> {
        var hint = addrinfo()
        hint.ai_socktype = Int32(SOCK_STREAM.rawValue)
        hint.ai_protocol = Int32(IPPROTO_TCP)
        var info: UnsafeMutablePointer<addrinfo>?
        let code = getaddrinfo(host, String(port), &hint, &info)
        guard code == 0 else { return .failure(.lookupFailed(code)) }
        guard let info else { return .failure(.emptyResult) }
        defer { freeaddrinfo(info) }
        var addresses = Addresses()
        var current: UnsafeMutablePointer<addrinfo>? = info
        var count = 0
        while let item = current {
            guard count < maximumAddresses else { return .failure(.tooManyAddresses) }
            count += 1
            guard let bytes = item.pointee.ai_addr else { return .failure(.invalidAddress) }
            switch item.pointee.ai_family {
            case AF_INET:
                guard Int(item.pointee.ai_addrlen) >= MemoryLayout<sockaddr_in>.size else { return .failure(.invalidAddress) }
                addresses.ipv4.append(SocketAddress(UnsafeRawPointer(bytes).load(as: sockaddr_in.self), host: host))
            case AF_INET6:
                guard Int(item.pointee.ai_addrlen) >= MemoryLayout<sockaddr_in6>.size else { return .failure(.invalidAddress) }
                addresses.ipv6.append(SocketAddress(UnsafeRawPointer(bytes).load(as: sockaddr_in6.self), host: host))
            default: return .failure(.unsupportedFamily(item.pointee.ai_family))
            }
            current = item.pointee.ai_next
        }
        return .success(addresses)
    }

    private func publish(_ result: Result<Addresses, LookupError>) {
        loop.preconditionInEventLoop()
        guard !published, !publishing else { return }
        publishing = true
        // Match the pinned resolver's same-tick AAAA-before-A publication.
        switch result {
        case .success(let addresses):
            ipv6.succeed(addresses.ipv6); ipv4.succeed(addresses.ipv4)
        case .failure(let error):
            ipv6.fail(error); ipv4.fail(error)
        }
        publishing = false
        published = true
    }

    private func finishDrainIfPossible() {
        loop.preconditionInEventLoop()
        guard stopping, published, !workerStarted || workerFinished,
              let completion = drainCompletion else { return }
        drainCompletion = nil
        // Both query promises have been settled on this live loop. The caller
        // may now initiate group shutdown, which joins remaining loop callbacks.
        completion()
    }
}

// The no-proxy HTTP upgrade path from the pinned WebSocketKit client. An actual
// premature channel close also fails the upgrade promise: it cannot strand the
// retained connect-completion lease when retirement closes an upgrading socket.
private final class OwnedNIOUpgradeRequestHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart
    private let host: String
    private let path: String
    private let query: String?
    private let headers: HTTPHeaders
    private let upgrade: EventLoopPromise<Void>
    private var requestSent = false

    init(host: String, path: String, query: String?, headers: HTTPHeaders, upgrade: EventLoopPromise<Void>) {
        self.host = host; self.path = path; self.query = query; self.headers = headers; self.upgrade = upgrade
    }
    func channelActive(context: ChannelHandlerContext) {
        sendRequest(context: context); context.fireChannelActive()
    }
    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive { sendRequest(context: context) }
    }
    private func sendRequest(context: ChannelHandlerContext) {
        guard !requestSent else { return }
        requestSent = true
        var headers = headers
        headers.add(name: "Host", value: host)
        var uri = path.hasPrefix("/") || path.hasPrefix("ws://") || path.hasPrefix("wss://") ? path : "/" + path
        if let query { uri += "?\(query)" }
        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: uri, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        let empty = context.channel.allocator.buffer(capacity: 0)
        context.write(wrapOutboundOut(.body(.byteBuffer(empty))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): upgrade.fail(WebSocketClient.Error.invalidResponseStatus(head))
        case .body: break
        case .end: context.close(promise: nil)
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: any Swift.Error) {
        upgrade.fail(error); context.close(promise: nil)
    }
    func channelInactive(context: ChannelHandlerContext) {
        upgrade.fail(ChannelError.eof)
        context.fireChannelInactive()
    }
}
#endif
