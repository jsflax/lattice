import Foundation
import NIOConcurrencyHelpers
import NIOCore
import Testing
import Lattice
import Vapor

/// Regression tests for the WSS URL-change handover scenario.
///
/// Background: each `lattice_db` opened with a `wssEndpoint` competes for an
/// `flock` on `<path>.sync.lock`. Pre-fix, when two in-process Lattices on the
/// same path opened with *different* URLs, the second one silently lost the
/// flock and ran with no synchronizer — for the lifetime of the first Lattice.
/// When the first Lattice closed, its sibling-handoff block iterated for an
/// instance with the SAME URL and (if it found a dormant ghost on the old URL)
/// resurrected sync against the now-stale URL.
///
/// Post-fix, `setup_sync_if_configured` recognizes a same-process sibling on a
/// different URL as a URL-change scenario and kicks the sibling out instead.
/// `teardown_sync(fire_handoff: false)` is called from the kick path so the
/// kicked sibling doesn't immediately resurrect another same-URL ghost.
///
/// All synchronization waits use observer-based primitives (`onSyncStateChange`,
/// `changeStream`) — no polls, no sleeps, per project convention.
@Suite("URLChange Sync Tests")
actor URLChangeSyncTests {
    let serverA: TestSyncServer
    let serverB: TestSyncServer
    let sharedPath = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    let serverPathA = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    let serverPathB = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    var portA: Int = 0
    var portB: Int = 0
    private let serverConfigA: Lattice.Configuration
    private let serverConfigB: Lattice.Configuration

    enum URLChangeError: Error { case noPort }

    deinit {
        serverA.shutdown()
        serverB.shutdown()
        try? FileManager.default.removeItem(at: sharedPath)
        try? FileManager.default.removeItem(at: serverPathA)
        try? FileManager.default.removeItem(at: serverPathB)
    }

    init() async throws {
        lattice_set_log_level(lattice.log_level.warn)
        self.serverConfigA = .init(fileURL: serverPathA)
        self.serverConfigB = .init(fileURL: serverPathB)

        // D1b: shared TestSyncServer per endpoint (one server-lifetime
        // lattice each, ordered persistence).
        self.serverA = try await TestSyncServer(models: [SimpleSyncObject.self], configuration: serverConfigA, label: "URLChangeA")
        self.serverB = try await TestSyncServer(models: [SimpleSyncObject.self], configuration: serverConfigB, label: "URLChangeB")
        self.portA = serverA.port
        self.portB = serverB.port
    }

    /// Open Lattice A on path P with URL_A. Open Lattice B on path P with
    /// URL_B. The kick path makes B take over: A's sync transitions to
    /// disconnected, B's transitions to connected. A write through B then
    /// reaches server B (the new URL); writes that pre-dated the open of B
    /// reach server A (the old URL) — confirming the kick happened only AT
    /// the moment of B's open.
    @Test(.disabled(if: isMacOSCI, "Darwin CI hang class — await never resumes and .timeLimit cannot interrupt on macOS; runs locally and on Linux CI. Owner: 1.0 item D1b/D2"), .timeLimit(.minutes(5)))
    func laterOpenWithDifferentURLTakesOverSync() async throws {
        let urlA = URL(string: "http://localhost:\(portA)/test")!
        let urlB = URL(string: "http://localhost:\(portB)/test")!

        let configA = Lattice.Configuration(
            fileURL: sharedPath,
            authorizationToken: "tokenA",
            wssEndpoint: urlA)
        let configB = Lattice.Configuration(
            fileURL: sharedPath,
            authorizationToken: "tokenB",
            wssEndpoint: urlB)

        // Open A; wait for connect.
        let latticeA = try Lattice(SimpleSyncObject.self, configuration: configA)
        try await waitForURLSyncState(latticeA, connected: true)
        #expect(latticeA.isSyncConnected, "A should be connected after open")

        // Pre-kick write: lands on server A.
        let preKickValue = 100
        let preKickArrived: Task<Void, any Error> = Task.detached {
            let serverLattice = try Lattice(for: [SimpleSyncObject.self],
                                            configuration: self.serverConfigA)
            for try await changes in serverLattice.changeStream {
                let resolved = changes.compactMap { $0.resolve(isolation: nil, on: serverLattice) }
                let touched = resolved.contains { $0.tableName == "SimpleSyncObject" }
                if touched, serverLattice.objects(SimpleSyncObject.self)
                    .first(where: { $0.value == preKickValue }) != nil { break }
            }
        }
        try latticeA.add(SimpleSyncObject(value: preKickValue, floatValue: 1.0))
        try await preKickArrived.value

        // Open B with a different URL on the same path. The fix kicks A
        // synchronously inside B's `setup_sync_if_configured` —
        // `victim->teardown_sync(false)` resets A's `synchronizer_` unique_ptr
        // before B's constructor returns. We wait only for B's connect; A's
        // state-change callback won't fire (the C++ handler is destroyed
        // along with the synchronizer), but `isSyncConnected` reads false
        // because `synchronizer_ == nullptr`.
        let latticeB = try Lattice(SimpleSyncObject.self, configuration: configB)
        try await waitForURLSyncState(latticeB, connected: true)

        #expect(!latticeA.isSyncConnected, "A should be disconnected after kick")
        #expect(latticeB.isSyncConnected, "B should be connected after take-over")

        // Post-kick write: lands on server B (B's URL).
        let postKickValue = 7
        let postKickArrived: Task<Void, any Error> = Task.detached {
            let serverLattice = try Lattice(for: [SimpleSyncObject.self],
                                            configuration: self.serverConfigB)
            for try await changes in serverLattice.changeStream {
                let resolved = changes.compactMap { $0.resolve(isolation: nil, on: serverLattice) }
                let touched = resolved.contains { $0.tableName == "SimpleSyncObject" }
                if touched, serverLattice.objects(SimpleSyncObject.self)
                    .first(where: { $0.value == postKickValue }) != nil { break }
            }
        }
        try latticeB.add(SimpleSyncObject(value: postKickValue, floatValue: 7.0))
        try await postKickArrived.value

        // Server A should NOT have received the post-kick write.
        let serverA = try Lattice(for: [SimpleSyncObject.self], configuration: serverConfigA)
        #expect(serverA.objects(SimpleSyncObject.self)
            .first(where: { $0.value == postKickValue }) == nil,
                "Server A must not have received B's post-kick write")

        latticeA.close()
        latticeB.close()
    }

    /// Same-URL legitimate dormant-duplicate case: opening two Lattices on the
    /// same path with the SAME URL must NOT kick either of them. The first to
    /// acquire the flock owns sync; the second runs as a dormant duplicate.
    /// Behavior unchanged from pre-fix.
    @Test(.timeLimit(.minutes(5)))
    func sameURLDoesNotKick() async throws {
        let urlA = URL(string: "http://localhost:\(portA)/test")!
        let configA = Lattice.Configuration(
            fileURL: sharedPath,
            authorizationToken: "tokenA",
            wssEndpoint: urlA)

        let latticeA1 = try Lattice(SimpleSyncObject.self, configuration: configA)
        try await waitForURLSyncState(latticeA1, connected: true)

        // Open a second Lattice with the same URL. A1 must keep sync; the
        // second opens as a dormant duplicate. To detect that A1 is NOT
        // kicked, race a "did A1 disconnect within a write round-trip" probe
        // against an actual successful write through A1.
        let latticeA2 = try Lattice(SimpleSyncObject.self, configuration: configA)
        let serverLattice = try Lattice(for: [SimpleSyncObject.self],
                                       configuration: serverConfigA)
        // Stream creation registers synchronously. Establish the observer
        // before the originating write, even if iteration starts afterward.
        let changes = serverLattice.changeStream
        try latticeA1.add(SimpleSyncObject(value: 42, floatValue: 4.2))
        var writeArrived = false
        for try await batch in changes {
            let resolved = batch.compactMap { $0.resolve(on: serverLattice) }
            let touched = resolved.contains { $0.tableName == "SimpleSyncObject" }
            if touched, serverLattice.objects(SimpleSyncObject.self)
                .first(where: { $0.value == 42 }) != nil {
                writeArrived = true
                break
            }
        }
        // Iterating in this test task propagates its time-limit cancellation
        // to the stream; no detached waiter outlives the parent.
        try Task.checkCancellation()
        try #require(writeArrived, "the originating write must reach server A")

        #expect(latticeA1.isSyncConnected, "A1 must NOT be kicked by same-URL A2")
        _ = latticeA2  // suppress unused warning — keep alive through the test

        latticeA1.close()
        latticeA2.close()
    }
}

/// Fixture-owned registration: observe first, then read the current state.
/// Core replays an already-connected state, but a checked continuation alone
/// cannot leave a never-connected wait when the test task is cancelled.
private func waitForURLSyncState(
    _ lattice: Lattice,
    connected target: Bool,
    isolation: isolated (any Actor)? = #isolation,
    afterRegistrationForTesting: (() -> Void)? = nil
) async throws {
    let states = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    lattice.onSyncStateChange { states.continuation.yield($0) }
    defer {
        lattice.onSyncStateChange { _ in }
        states.continuation.finish()
    }
    afterRegistrationForTesting?()
    try Task.checkCancellation()
    if lattice.isSyncConnected == target { return }
    for await state in states.stream {
        try Task.checkCancellation()
        if state == target { return }
    }
    try Task.checkCancellation()
    throw URLChangeFixtureError.stateStreamEnded
}

private enum URLChangeFixtureError: Error { case stateStreamEnded }

@Suite("URLChange fixture readiness", .serialized)
private actor URLChangeFixtureReadinessTests {
    @Test(.timeLimit(.minutes(1)))
    func changeStreamCapturesWriteBeforeIteration() async throws {
        let config = Lattice.Configuration(fileURL: FileManager.default.temporaryDirectory
            .appending(path: "url-change-buffered-\(UUID().uuidString).sqlite"))
        let lattice = try Lattice(SimpleSyncObject.self, configuration: config)
        defer { lattice.close(); try? Lattice.delete(for: config) }

        let changes = lattice.changeStream
        try lattice.add(SimpleSyncObject(value: 42, floatValue: 4.2))
        // Deliberately begin iteration only after the commit. Registration
        // readiness, not task scheduling, must preserve this notification.
        var iterator = changes.makeAsyncIterator()
        let batch = try #require(try await iterator.next())
        #expect(batch.contains { $0.resolve(on: lattice)?.tableName == "SimpleSyncObject" })
        #expect(lattice.objects(SimpleSyncObject.self).first(where: { $0.value == 42 }) != nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingParentEndsChangeStreamWait() async throws {
        let config = Lattice.Configuration(fileURL: FileManager.default.temporaryDirectory
            .appending(path: "url-change-cancel-stream-\(UUID().uuidString).sqlite"))
        let lattice = try Lattice(SimpleSyncObject.self, configuration: config)
        defer { lattice.close(); try? Lattice.delete(for: config) }
        let registered = AsyncStream<Void>.makeStream()
        let parent = Task {
            let changes = lattice.changeStream
            registered.continuation.yield(())
            registered.continuation.finish()
            for try await _ in changes { }
            try Task.checkCancellation()
        }
        for await _ in registered.stream { break }
        parent.cancel()
        do {
            try await parent.value
            Issue.record("a cancelled parent must not report a completed observation")
        } catch is CancellationError { }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingParentEndsNeverConnectedWait() async throws {
        let config = Lattice.Configuration(fileURL: FileManager.default.temporaryDirectory
            .appending(path: "url-change-cancel-state-\(UUID().uuidString).sqlite"))
        let lattice = try Lattice(SimpleSyncObject.self, configuration: config)
        defer { lattice.close(); try? Lattice.delete(for: config) }
        #expect(!lattice.isSyncConnected)
        let registered = AsyncStream<Void>.makeStream()
        let parent = Task {
            try await waitForURLSyncState(lattice, connected: true) {
                registered.continuation.yield(())
                registered.continuation.finish()
            }
        }
        for await _ in registered.stream { break }
        parent.cancel()
        do {
            try await parent.value
            Issue.record("a cancelled parent must not wait indefinitely for connection")
        } catch is CancellationError { }
    }
}
