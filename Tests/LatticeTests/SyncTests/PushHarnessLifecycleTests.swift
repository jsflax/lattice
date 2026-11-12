import Foundation
import Testing
import Vapor
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

// Used by the fixture and by the failing-first lifecycle probe's cleanup.
// Keep this helper in the test-only patch so that control compiles unchanged.
func closePushHarnessClients(_ sockets: [WebSocket], timeout: TimeAmount = .seconds(60)) async {
    // Some transport-death tests have already stopped a client's private
    // event loop. Even whenComplete on its completed future would enqueue
    // onto that stopped loop, so do not touch futures for a closed socket.
    let live = sockets.filter { !$0.isClosed }
    for socket in live { socket.close(code: .goingAway, promise: nil) }
    let closures: [EventLoopFuture<Void>] = live.compactMap { socket in
        guard !socket.isClosed else { return nil }
        let closed = socket.eventLoop.makePromise(of: Void.self)
        let once = AtomicOnce()
        let deadline = socket.eventLoop.scheduleTask(in: timeout) {
            if once.tryFire() {
                closed.fail(Abort(.internalServerError, reason: "Raw push client did not close during fixture teardown"))
            }
        }
        socket.onClose.whenComplete { result in
            if once.tryFire() {
                deadline.cancel()
                closed.completeWith(result)
            }
        }
        return closed.futureResult
    }
    for closed in closures {
        do { try await closed.get() }
        catch { Issue.record(error, "Raw push client teardown failed") }
    }
}

private enum PushBodyFailure: Error { case expected }

private struct PushShutdownProbe: LifecycleHandler {
    let sockets: [WebSocket]
    let observed: NIOLockedValueBox<[Bool]?>

    func shutdownAsync(_ application: Application) async {
        // Observe the real lifecycle boundary before helping the old fixture
        // clean up. The control must fail without leaking its live clients.
        observed.withLockedValue { $0 = sockets.map(\.isClosed) }
        await closePushHarnessClients(sockets)
    }
}

@Suite("Push harness lifecycle", .timeLimit(.minutes(5)))
struct PushHarnessLifecycleTests {
    @Test(arguments: [false, true])
    func closesClientsBeforeApplicationShutdownOnEveryBodyExit(throwsFromBody: Bool) async throws {
        let observed = NIOLockedValueBox<[Bool]?>(nil)
        var application: Application?
        var storageURL: URL?
        var clients: [WebSocket] = []
        var caughtExpectedFailure = false
        do {
            try await withPushHarness { harness in
                application = harness.app
                storageURL = harness.storageURL
                // Each mount owns an independently established live socket.
                for mount in ["writer", "watch", "watch2"] {
                    let collector = try await harness.connect(
                        pathSuffix: "\(mount)/group/lifecycle?lattice-catch-up-complete=1", user: UUID())
                    let socket = try #require(collector.socket)
                    clients.append(socket)
                }
                #expect(clients.count == 3)
                #expect(clients.allSatisfy { !$0.isClosed })
                // A private group may already be gone when the fixture exits.
                // Teardown must not schedule a timer or callback on that loop.
                let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
                do {
                    let dead = try await harness.connect(
                        pathSuffix: "watch/group/terminated-loop", user: UUID(), on: group)
                    clients.append(try #require(dead.socket))
                } catch {
                    try? await group.shutdownGracefully()
                    throw error
                }
                try await group.shutdownGracefully()
                #expect(clients.last?.isClosed == true)
                harness.app.lifecycle.use(PushShutdownProbe(sockets: clients, observed: observed))
                if throwsFromBody { throw PushBodyFailure.expected }
            }
        } catch PushBodyFailure.expected {
            caughtExpectedFailure = true
        }
        #expect(caughtExpectedFailure == throwsFromBody)
        let closedAtApplicationShutdown = try #require(observed.withLockedValue { $0 })
        #expect(closedAtApplicationShutdown == [true, true, true, true],
                "The fixture must join actual client closes before releasing its HTTP server")
        #expect(clients.allSatisfy(\.isClosed))
        let app = try #require(application)
        #expect(app.didShutdown)
        let directory = try #require(storageURL)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
