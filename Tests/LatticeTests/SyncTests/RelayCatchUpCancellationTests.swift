import Foundation
import Testing
import Vapor
import NIOConcurrencyHelpers
@testable import Lattice
@testable import LatticeServerKit

@Model final class CatchUpCancellationRecord {
    var value: Int
    init(value: Int) { self.value = value }
}

private actor CatchUpProbe {
    private(set) var offsets: [Int] = []
    private(set) var activations = 0
    private(set) var finished = false
    private var blocked: CheckedContinuation<Void, Never>?
    private var released = false
    private let pauseOffset: Int

    init(pauseOffset: Int = 0) { self.pauseOffset = pauseOffset }

    func observe(_ event: CatchUpObservation) async {
        switch event {
        case .pageRead(let offset):
            offsets.append(offset)
            if offset == pauseOffset, !released {
                await withCheckedContinuation { blocked = $0 }
            }
        case .activated: activations += 1
        case .finished: finished = true
        }
    }

    func release() {
        released = true
        blocked?.resume()
        blocked = nil
    }
}

private final class CatchUpClient: @unchecked Sendable {
    private struct State {
        var socket: WebSocket?
        var frames: [Data] = []
    }
    private let state = NIOLockedValueBox(State())
    var socket: WebSocket? { state.withLockedValue { $0.socket } }
    var frames: [Data] { state.withLockedValue { $0.frames } }
    func attach(_ socket: WebSocket) {
        state.withLockedValue { $0.socket = socket }
        socket.onBinary { [weak self] _, buffer in
            self?.state.withLockedValue { $0.frames.append(Data(buffer: buffer)) }
        }
    }
    func pageIDs(allowFloorReset: Bool = false) throws -> [[UUID]] {
        try frames.compactMap { bytes in
            let event = try JSONDecoder().decode(ServerSentEvent.self, from: bytes)
            if allowFloorReset, case .floorReset = event { return nil }
            guard case .auditLog(let entries) = event else {
                throw Abort(.internalServerError, reason: "Unexpected non-audit frame")
            }
            return try entries.map { try #require($0.globalId) }
        }
    }
}

private final class CatchUpFixture: @unchecked Sendable {
    let app: Application
    let handle: SyncRelayHandle
    let root: URL
    let channel: String
    let expected: [UUID]
    let port: Int

    private init(app: Application, handle: SyncRelayHandle, root: URL,
                 channel: String, expected: [UUID], port: Int) {
        self.app = app; self.handle = handle; self.root = root
        self.channel = channel; self.expected = expected; self.port = port
    }

    static func make(pageSize: Int, excludeAll: Bool = false) async throws -> CatchUpFixture {
        let root = testTemporaryDirectory
            .appending(path: "relay-catch-up-\(UUID().uuidString)", directoryHint: .isDirectory)
        let channel = UUID().uuidString.lowercased()
        let user = UUID()
        var application: Application?
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let expected: [UUID] = try {
                let store = try Lattice(CatchUpCancellationRecord.self,
                    configuration: .init(fileURL: root.appending(path: channel + ".sqlite")))
                defer { store.close() }
                try store.transaction {
                    for value in 0..<9 { try store.add(CatchUpCancellationRecord(value: value)) }
                }
                return try store.eventsAfter(globalId: nil).snapshot().map { try #require($0.globalId) }
            }()
            try #require(expected.count > pageSize)
            var environment = try Environment.detect()
            environment.arguments = ["vapor"]
            let app = try await Application.make(environment)
            application = app
            app.http.server.configuration.port = 0
            app.http.server.configuration.shutdownTimeout = testHTTPServerShutdownTimeout
            let handle = Lattice.configureSyncRelay(on: app.routes, for: [CatchUpCancellationRecord.self],
                storageURL: root, observerPush: SyncObserverPush(reconcileInterval: nil),
                initialCatchUpPageSize: pageSize,
                downloadExcludedTables: excludeAll ? ["catchupcancellationrecord"] : []) { _ in
                    SyncChannel(id: channel, userId: user)
                }
            try await app.startup()
            let port = try #require(app.http.server.shared.localAddress?.port)
            return CatchUpFixture(app: app, handle: handle, root: root,
                channel: channel, expected: expected, port: port)
        } catch {
            if let application { try? await application.asyncShutdown() }
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func connect(after cursor: UUID? = nil) async throws -> CatchUpClient {
        let client = CatchUpClient()
        let suffix = cursor.map { "?last-event-id=" + $0.uuidString.lowercased() } ?? ""
        try await WebSocket.connect(to: "ws://127.0.0.1:\(port)/sync" + suffix,
            on: app.eventLoopGroup) { client.attach($0) }.get()
        try #require(await eventually { client.socket != nil })
        return client
    }

    func shutdown() async {
        await handle.disconnectAll(channelId: channel)
        _ = await eventually { await self.handle.connectionCount(channelId: self.channel) == 0 }
        try? await app.asyncShutdown()
        try? FileManager.default.removeItem(at: root)
    }
}

private func eventually(_ predicate: @escaping @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while ContinuousClock.now < deadline {
        if await predicate() { return true }
        do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
    }
    return await predicate()
}

@Suite("Relay catch-up cancellation", .serialized, .timeLimit(.minutes(1)))
struct RelayCatchUpCancellationTests {
    @Test("Normal socket close stops remaining SQL pages and never activates parked push",
          arguments: [1, 2], [false, true])
    func closeDuringCatchUpStopsPageReads(pageSize: Int, excludeAll: Bool) async throws {
        let fixture = try await CatchUpFixture.make(pageSize: pageSize, excludeAll: excludeAll)
        let probe = CatchUpProbe()
        _catchUpObservationForTesting.withLockedValue { $0 = { channel, event in
            if channel == fixture.channel { await probe.observe(event) }
        } }
        do {
            let client = try await fixture.connect()
            try #require(await eventually { await probe.offsets == [0] })
            // The first bounded page is paused before send. This is an
            // ordinary peer close, not a revocation kick or an artificial flag.
            let socket = try #require(client.socket)
            try await socket.close(code: .goingAway)
            try #require(await eventually { await fixture.handle.connectionCount(channelId: fixture.channel) == 0 })
            await probe.release()
            try #require(await eventually { await probe.finished })
            #expect(await probe.offsets == [0])
            #expect(await probe.activations == 0)
            #expect(client.frames.isEmpty)
            let manager = try #require(fixture.handle.pushManager)
            let file = fixture.root.appending(path: fixture.channel + ".sqlite")
            try #require(await eventually { !(await manager.hasGroup(forFile: file)) })
            _catchUpObservationForTesting.withLockedValue { $0 = nil }

            // Closing has not changed the durable history or resume floor.
            if !excludeAll {
                let cursor = fixture.expected[pageSize - 1]
                let expected = Array(fixture.expected.dropFirst(pageSize))
                let resumed = try await fixture.connect(after: cursor)
                let count = (expected.count + pageSize - 1) / pageSize
                try #require(await eventually { resumed.frames.count >= count })
                let pages = try resumed.pageIDs()
                #expect(pages.flatMap { $0 } == expected)
                #expect(pages.allSatisfy { !$0.isEmpty && $0.count <= pageSize })
            }
            await fixture.shutdown()
        } catch {
            await probe.release()
            _catchUpObservationForTesting.withLockedValue { $0 = nil }
            await fixture.shutdown()
            throw error
        }
    }

    @Test("An open socket still receives every page in order", arguments: [1, 2])
    func openCatchUpPreservesAllPages(pageSize: Int) async throws {
        let fixture = try await CatchUpFixture.make(pageSize: pageSize)
        do {
            let client = try await fixture.connect()
            let count = (fixture.expected.count + pageSize - 1) / pageSize
            try #require(await eventually { client.frames.count >= count })
            let pages = try client.pageIDs()
            #expect(pages.count == count)
            #expect(pages.flatMap { $0 } == fixture.expected)
            #expect(pages.allSatisfy { !$0.isEmpty && $0.count <= pageSize })
            await fixture.shutdown()
        } catch {
            await fixture.shutdown()
            throw error
        }
    }

    @Test("Catch-up survives generation retirement and delivered-prefix pruning without gaps",
          arguments: [false, true])
    func catchUpUsesAuditIDsAcrossChurn(unknownFloor: Bool) async throws {
        let pageSize = 2
        let fixture = try await CatchUpFixture.make(pageSize: pageSize)
        // Pause the second page: the first page must already be delivered,
        // while the second page's bytes are prepared and later pages unread.
        let probe = CatchUpProbe(pauseOffset: pageSize)
        _catchUpObservationForTesting.withLockedValue { $0 = { channel, event in
            if channel == fixture.channel { await probe.observe(event) }
        } }
        var writer: Lattice?
        do {
            let client = try await fixture.connect(after: unknownFloor ? UUID() : nil)
            try #require(await eventually { await probe.offsets == [0, pageSize] })
            try #require(await eventually {
                (try? client.pageIDs(allowFloorReset: true).flatMap { $0 }.count) == pageSize
            })
            let firstFrames = try client.frames.map { try JSONDecoder().decode(ServerSentEvent.self, from: $0) }
            let floorNotices = firstFrames.filter { if case .floorReset = $0 { true } else { false } }
            #expect(floorNotices.count == (unknownFloor ? 1 : 0))
            if unknownFloor {
                guard case .floorReset(let head, _) = try #require(firstFrames.first) else {
                    Issue.record("Unknown floor must be announced before audit pages")
                    throw Abort(.internalServerError)
                }
                #expect(head == fixture.expected.last)
            }

            // Match the relay configuration/core identity and retire any
            // read generation before changing the audit history.
            let file = fixture.root.appending(path: fixture.channel + ".sqlite")
            let store = try Lattice(CatchUpCancellationRecord.self,
                configuration: SyncRelayApplyPolicy.configuration(fileURL: file, storeConfiguration: nil))
            writer = store
            store.retireAllGenerations()
            #expect(store.backend.localReadGenerationsOutstanding() == 0)
            let lastDelivered = fixture.expected[pageSize - 1]
            let removedThrough = try #require(store.objects(AuditLog.self)
                .where { $0.globalId == lastDelivered }.snapshot(limit: 1).first?.primaryKey)
            let removed = store.delete(AuditLog.self, where: { $0.primaryKey <= removedThrough })
            let pruneError = store.lastQueryError()
            #expect(removed)
            try #require(pruneError == nil)
            // One new row leaves the live collection SHORTER than the
            // initial count, and belongs after the finite catch-up bound.
            try store.add(CatchUpCancellationRecord(value: 10_000))
            let appended = try #require(store.eventsAfter(globalId: fixture.expected.last)
                .snapshot().first?.globalId)
            store.resumeGenerations()
            await probe.release()
            try #require(await eventually { await probe.finished })
            #expect(await probe.activations == 1)
            let expected = fixture.expected + [appended]
            try #require(await eventually {
                (try? client.pageIDs(allowFloorReset: true).flatMap { $0 }.count) == expected.count
            })
            let pages = try client.pageIDs(allowFloorReset: true)
            #expect(pages.flatMap { $0 } == expected)
            #expect(pages.allSatisfy { !$0.isEmpty && $0.count <= pageSize })
            #expect(await probe.offsets == [0, 2, 4, 6, 8])
            _catchUpObservationForTesting.withLockedValue { $0 = nil }
            store.close()
            writer = nil
            await fixture.shutdown()
        } catch {
            await probe.release()
            _catchUpObservationForTesting.withLockedValue { $0 = nil }
            writer?.resumeGenerations()
            writer?.close()
            await fixture.shutdown()
            throw error
        }
    }

    @Test("A pruned catch-up tail completes without closing the socket")
    func prunedTailEndsCatchUpNormally() async throws {
        let fixture = try await CatchUpFixture.make(pageSize: 2)
        let probe = CatchUpProbe()
        _catchUpObservationForTesting.withLockedValue { $0 = { channel, event in
            if channel == fixture.channel { await probe.observe(event) }
        } }
        var writer: Lattice?
        do {
            let client = try await fixture.connect()
            try #require(await eventually { await probe.offsets == [0] })
            let file = fixture.root.appending(path: fixture.channel + ".sqlite")
            let store = try Lattice(CatchUpCancellationRecord.self,
                configuration: SyncRelayApplyPolicy.configuration(fileURL: file, storeConfiguration: nil))
            writer = store
            store.retireAllGenerations()
            let lastPrepared = fixture.expected[1]
            let boundary = try #require(store.objects(AuditLog.self)
                .where { $0.globalId == lastPrepared }.snapshot(limit: 1).first?.primaryKey)
            let removed = store.delete(AuditLog.self, where: { $0.primaryKey > boundary })
            let pruneError = store.lastQueryError()
            #expect(removed)
            try #require(pruneError == nil)
            store.resumeGenerations()
            await probe.release()
            try #require(await eventually { await probe.finished })
            #expect(await probe.activations == 1)
            #expect(await probe.offsets == [0])
            let socket = try #require(client.socket)
            #expect(!socket.isClosed)
            try #require(await eventually { client.frames.count == 1 })
            let initialPages = try client.pageIDs()
            #expect(initialPages.flatMap { $0 } == Array(fixture.expected.prefix(2)))

            // The completed catch-up still hands new writes to observer push.
            try store.add(CatchUpCancellationRecord(value: 10_000))
            let appended = try #require(store.eventsAfter(globalId: lastPrepared)
                .snapshot().last?.globalId)
            try #require(await eventually {
                (try? client.pageIDs().flatMap { $0 }.last) == appended
            })
            #expect(!socket.isClosed)
            _catchUpObservationForTesting.withLockedValue { $0 = nil }
            store.close()
            writer = nil
            await fixture.shutdown()
        } catch {
            await probe.release()
            _catchUpObservationForTesting.withLockedValue { $0 = nil }
            writer?.resumeGenerations()
            writer?.close()
            await fixture.shutdown()
            throw error
        }
    }

    @Test("Task registration cannot lose a racing close", arguments: [false, true])
    func closeCancelsOwnedTask(closeFirst: Bool) async {
        let state = ConnectionRelayState()
        let gate = CatchUpProbe()
        let task = Task<Void, Error> {
            await gate.observe(.pageRead(offset: 0))
            try Task.checkCancellation()
        }
        if closeFirst { state.cancelCatchUp() }
        state.installCatchUp(task)
        if !closeFirst { state.cancelCatchUp() }
        #expect(state.catchUpStopped)
        #expect(task.isCancelled)
        await gate.release()
        do {
            try await task.value
            Issue.record("A closed connection's catch-up task must be cancelled")
        } catch {
            #expect(error is CancellationError)
        }
        state.finishCatchUp()
    }
}
