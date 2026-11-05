import Foundation
import MCP
import Logging

/// A single drain serializes entire frames, including awaits under pipe
/// backpressure. Actor isolation alone permits interleaved partial writes.
public actor LatticeSerializedStdioTransport: Transport {
    public nonisolated let logger: Logger
    private let underlying: any Transport
    private let lifetimeID = UUID()
    @TaskLocal private static var enteredLifetimeIDs: Set<UUID> = []
    private struct PendingSend {
        let data: Data
        let continuation: CheckedContinuation<Void, Error>
    }
    private var pending: [PendingSend] = []
    private var drainTask: Task<Void, Never>?
    private var drainFinished = true
    private var readerTask: Task<Void, Never>?
    private var connectTask: Task<Void, Error>?
    private var shutdownTask: Task<Void, Never>?
    private let messages: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var connected = false
    private var closed = false
    public private(set) var isShutdownComplete = false

    public init(underlying: StdioTransport = StdioTransport()) {
        self.underlying = underlying
        self.logger = underlying.logger
        let stream = AsyncThrowingStream<Data, Error>.makeStream()
        messages = stream.stream
        continuation = stream.continuation
    }

    /// Pure regression seam. Production retains the concrete StdioTransport
    /// initializer above, whose selected private disconnect joins its I/O.
    init(testingUnderlying underlying: any Transport, logger: Logger) {
        self.underlying = underlying
        self.logger = logger
        let stream = AsyncThrowingStream<Data, Error>.makeStream()
        messages = stream.stream
        continuation = stream.continuation
    }

    public func connect() async throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        if connected { return }
        if let connectTask {
            try await connectTask.value
            guard !closed else { throw CancellationError() }
            return
        }
        let connector = Task {
            try await Self.$enteredLifetimeIDs.withValue(Self.enteredLifetimeIDs.union([lifetimeID])) {
                try Task.checkCancellation()
                try await self.connectOwned()
            }
        }
        connectTask = connector
        try await connector.value
        guard !closed else { throw CancellationError() }
    }

    private func connectOwned() async throws {
        try await underlying.connect()
        guard !closed, !Task.isCancelled else { throw CancellationError() }
        connected = true
        readerTask = Task {
            await Self.$enteredLifetimeIDs.withValue(Self.enteredLifetimeIDs.union([lifetimeID])) {
                do {
                    for try await message in await underlying.receive() {
                        guard !closed, !Task.isCancelled else { break }
                        continuation.yield(Self.compatibleCodexInitialize(message))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Experimental capabilities retain the selected MCP SDK's JSON value semantics.
    /// Codex advertises an optional empty auth-change capability that this server
    /// does not implement. Omit only that exact advertisement, as our existing
    /// Codex compatibility relay does; every other shape keeps native validation.
    public nonisolated static func compatibleCodexInitialize(_ data: Data) -> Data {
        guard var message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              message["method"] as? String == "initialize",
              var params = message["params"] as? [String: Any],
              var capabilities = params["capabilities"] as? [String: Any],
              var experimental = capabilities["experimental"] as? [String: Any],
              let advertisement = experimental["codex/auth-change"] as? [String: Any],
              advertisement.isEmpty else { return data }
        experimental.removeValue(forKey: "codex/auth-change")
        if experimental.isEmpty { capabilities.removeValue(forKey: "experimental") }
        else { capabilities["experimental"] = experimental }
        params["capabilities"] = capabilities
        message["params"] = params
        return (try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])) ?? data
    }

    public func send(_ data: Data) async throws {
        guard connected, !closed else { throw CancellationError() }
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { continuation in
            pending.append(.init(data: data, continuation: continuation))
            if drainFinished {
                let predecessor = drainTask
                drainFinished = false
                drainTask = Task {
                    await predecessor?.value
                    await Self.$enteredLifetimeIDs.withValue(Self.enteredLifetimeIDs.union([lifetimeID])) {
                        await self.drain()
                    }
                }
            }
        }
    }

    private func drain() async {
        while !pending.isEmpty, !closed, !Task.isCancelled {
            let item = pending.removeFirst()
            do {
                try Task.checkCancellation()
                try await underlying.send(item.data)
                try Task.checkCancellation()
                guard !closed else { throw CancellationError() }
                item.continuation.resume()
            } catch {
                item.continuation.resume(throwing: error)
                closeAdmission()
                break
            }
        }
        // Keep this exact handle. A successor joins it before beginning, and
        // closure joins the final handle before releasing the ownership chain.
        drainFinished = true
    }

    private func failPending(_ error: Error) {
        let abandoned = pending
        pending.removeAll()
        for item in abandoned { item.continuation.resume(throwing: error) }
    }

    public func receive() -> AsyncThrowingStream<Data, Error> { messages }

    public func closeAdmission() {
        closed = true
        connected = false
        connectTask?.cancel()
        drainTask?.cancel()
        readerTask?.cancel()
        continuation.finish()
        failPending(CancellationError())
    }

    /// True proves this wrapper's connect/reader/drain tasks have returned.
    /// The production underlying StdioTransport's disconnect also joins its
    /// reader/writes; neither layer closes inherited descriptors or exits a process.
    @discardableResult public func waitForShutdown() async -> Bool {
        closeAdmission()
        guard !Self.enteredLifetimeIDs.contains(lifetimeID) else { return false }
        if shutdownTask == nil {
            shutdownTask = Task {
                await Self.$enteredLifetimeIDs.withValue(Self.enteredLifetimeIDs.union([lifetimeID])) {
                    await self.joinOwnedTasks()
                }
            }
        }
        await shutdownTask?.value
        return isShutdownComplete
    }

    private func joinOwnedTasks() async {
        let connector = connectTask
        _ = await connector?.result
        // No reader may be installed after this joined connection: connect()
        // rechecks closed before publishing its reader.
        let reader = readerTask
        let drain = drainTask
        await underlying.disconnect()
        await reader?.value
        await drain?.value
        connectTask = nil
        readerTask = nil
        drainTask = nil
        isShutdownComplete = true
    }

    /// Protocol compatibility. An entered transport descendant only requests
    /// closure; external owners use waitForShutdown and require true.
    public func disconnect() async {
        _ = await waitForShutdown()
    }
}
