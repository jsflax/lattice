import Foundation
import Logging
import MCP
import Testing
@testable import LatticeMCPTransport

/// Authored UNRUN. The selected Lattice manifest has no transport test target;
/// this file still needs an explicit private test-target/harness composition.
struct SerializedStdioLifetimeTests {
    @Test func readerNormalizesOnlyTheExactEmptyCodexAdvertisement() async throws {
        let underlying = SerializedLifetimeTransport()
        let transport = LatticeSerializedStdioTransport(testingUnderlying: underlying, logger: underlying.logger)
        let original = Data(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"codex/auth-change":{}},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"codex-mcp-client","version":"0.154.0"}}}"#.utf8)
        let ordinary = Data(#" { "jsonrpc":"2.0", "id":17, "method":"tools/call", "params":{"capabilities":{"experimental":{"codex/auth-change":{}}}} } "#.utf8)
        let unsupported = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"codex/auth-change":{},"unknown/object-extension":{}}},"clientInfo":{"name":"codex-mcp-client","version":"0.154.0"}}}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Request<Initialize>.self, from: original) }
        try await transport.connect()
        await underlying.finishIncoming([original, ordinary, unsupported])
        var frames: [Data] = []
        for try await frame in await transport.receive() { frames.append(frame) }
        let joined = await transport.waitForShutdown()
        let readers = await underlying.receiveCount
        #expect(joined && readers == 1)
        #expect(frames.count == 3)
        guard frames.count == 3 else { return }
        let request = try JSONDecoder().decode(Request<Initialize>.self, from: frames[0])
        #expect(request.id == .number(0))
        #expect(request.params.protocolVersion == "2025-06-18")
        #expect(request.params.clientInfo.name == "codex-mcp-client")
        #expect(request.params.capabilities.experimental == nil)
        #expect(frames[1] == ordinary)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Request<Initialize>.self, from: frames[2]) }
    }

    @Test func disconnectWaitsForActualEnteredSendAndRejectsConcurrentSend() async throws {
        let release = SerializedLifetimeGate()
        let underlying = SerializedLifetimeTransport(sendRelease: release)
        let transport = LatticeSerializedStdioTransport(testingUnderlying: underlying, logger: underlying.logger)
        try await transport.connect()
        let first = Task {
            do { try await transport.send(Data("first".utf8)); return false }
            catch { return true }
        }
        await underlying.sendEntered.wait()
        let second = Task {
            do { try await transport.send(Data("second".utf8)); return false }
            catch { return true }
        }
        await transport.closeAdmission()
        let closing = Task { await transport.waitForShutdown() }
        await underlying.disconnectEntered.wait()
        let premature = await transport.isShutdownComplete
        #expect(!premature)
        await release.open()
        let joined = await closing.value
        let firstInterrupted = await first.value
        let secondInterrupted = await second.value
        let active = await underlying.activeSends
        #expect(joined)
        #expect(firstInterrupted && secondInterrupted)
        #expect(active == 0)
    }

    @Test func closeDuringConnectCannotPublishLateReader() async throws {
        let release = SerializedLifetimeGate()
        let underlying = SerializedLifetimeTransport(connectRelease: release)
        let transport = LatticeSerializedStdioTransport(testingUnderlying: underlying, logger: underlying.logger)
        let connecting = Task {
            do { try await transport.connect(); return false }
            catch { return true }
        }
        await underlying.connectEntered.wait()
        await transport.closeAdmission()
        let closing = Task { await transport.waitForShutdown() }
        let premature = await transport.isShutdownComplete
        #expect(!premature)
        await release.open()
        let rejected = await connecting.value
        let joined = await closing.value
        let readers = await underlying.receiveCount
        #expect(rejected && joined)
        #expect(readers == 0)
    }

    @Test func successiveDrainsRetainFrameOrderWithoutConcurrentWrites() async throws {
        let underlying = SerializedLifetimeTransport()
        let transport = LatticeSerializedStdioTransport(testingUnderlying: underlying, logger: underlying.logger)
        try await transport.connect()
        let expected = (0..<300).map { Data("frame-\($0)".utf8) }
        for frame in expected { try await transport.send(frame) }
        let joined = await transport.waitForShutdown()
        let frames = await underlying.frames
        let maximum = await underlying.maximumActiveSends
        #expect(joined)
        #expect(frames == expected)
        #expect(maximum == 1)
    }

    @Test func transportCallbackCanFenceButCannotJoinItsOwnDrain() async throws {
        let underlying = SerializedLifetimeTransport()
        let result = SerializedLifetimeBoolean()
        let transport = LatticeSerializedStdioTransport(testingUnderlying: underlying, logger: underlying.logger)
        await underlying.setOnSend {
            let joined = await transport.waitForShutdown()
            await result.set(joined)
        }
        try await transport.connect()
        let sending = Task {
            do { try await transport.send(Data("callback".utf8)); return false }
            catch { return true }
        }
        await result.ready.wait()
        let callbackJoined = await result.value
        #expect(callbackJoined == false)
        let joined = await transport.waitForShutdown()
        let interrupted = await sending.value
        #expect(joined)
        #expect(interrupted)
    }
}

private actor SerializedLifetimeGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        guard !opened else { return }
        opened = true
        let entered = waiters
        waiters.removeAll()
        for waiter in entered { waiter.resume() }
    }
}

private actor SerializedLifetimeBoolean {
    let ready = SerializedLifetimeGate()
    private(set) var value: Bool?
    func set(_ value: Bool) async {
        self.value = value
        await ready.open()
    }
}

private actor SerializedLifetimeTransport: Transport {
    nonisolated let logger = Logger(label: "private.serialized-lifetime-test", factory: { _ in SwiftLogNoOpLogHandler() })
    let connectEntered = SerializedLifetimeGate()
    let sendEntered = SerializedLifetimeGate()
    let disconnectEntered = SerializedLifetimeGate()
    private let connectRelease: SerializedLifetimeGate?
    private let sendRelease: SerializedLifetimeGate?
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var onSend: (@Sendable () async -> Void)?
    private var closed = false
    private(set) var activeSends = 0
    private(set) var maximumActiveSends = 0
    private(set) var receiveCount = 0
    private(set) var frames: [Data] = []

    init(connectRelease: SerializedLifetimeGate? = nil, sendRelease: SerializedLifetimeGate? = nil) {
        self.connectRelease = connectRelease
        self.sendRelease = sendRelease
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }
    func setOnSend(_ callback: @escaping @Sendable () async -> Void) { onSend = callback }
    func connect() async throws {
        await connectEntered.open()
        if let connectRelease { await connectRelease.wait() }
    }
    func send(_ data: Data) async throws {
        guard !closed else { throw CancellationError() }
        activeSends += 1
        maximumActiveSends = max(maximumActiveSends, activeSends)
        defer { activeSends -= 1 }
        await sendEntered.open()
        if let sendRelease { await sendRelease.wait() }
        if let onSend { await onSend() }
        guard !closed else { throw CancellationError() }
        frames.append(data)
    }
    func finishIncoming(_ messages: [Data]) {
        guard !closed else { return }
        for message in messages { continuation.yield(message) }
        continuation.finish()
    }
    func receive() -> AsyncThrowingStream<Data, Error> {
        receiveCount += 1
        return stream
    }
    func disconnect() async {
        closed = true
        continuation.finish()
        await disconnectEntered.open()
    }
}
