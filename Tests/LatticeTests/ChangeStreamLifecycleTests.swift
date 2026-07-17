import Testing
import Foundation
import Lattice

@Model final class ChangeStreamLifecycleObject {
    var value: Int = 0
}

// D3 (1.0): `changeStream` is an `AsyncThrowingStream`. The observer
// registers synchronously at creation (leaf-lock map insert — preserves the
// "stream created ⇒ subsequent commits are captured" contract), while the
// BLOCKING query-Lattice open hops off the caller's task, buffering raw
// batches until ready. These tests pin the failure modes of the old
// `AsyncStream` shape (a `try!` trap on a failed open; blocking
// non-suspending setup in the caller's context that starved cooperative
// cancellation) plus the no-lost-events contract the off-task open must keep.
@Suite("Change Stream Lifecycle Tests")
final class ChangeStreamLifecycleTests: BaseTest {

    /// Cancelling the consuming task must end `for try await` promptly — no
    /// leaked continuation, no hang. `onTermination` removes the observer on
    /// whichever side of the setup race it lands.
    @Test(.timeLimit(.minutes(1)))
    func test_changeStream_cancellationTerminatesIteration() async throws {
        let lattice = try testLattice(ChangeStreamLifecycleObject.self)
        let stream = lattice.changeStream

        let consumer = Task {
            for try await _ in stream { }
        }
        // Cancel while the consumer is (or is about to be) parked on next().
        await Task.yield()
        consumer.cancel()

        let clock = ContinuousClock()
        let start = clock.now
        // A leaked continuation would park this await until the time limit.
        _ = try? await consumer.value
        #expect(clock.now - start < .seconds(10),
                "cancelled changeStream iteration did not terminate promptly")

        // Teardown smoke check: a write after cancellation must not deliver
        // to (or crash on) the torn-down stream's observer.
        try lattice.add(ChangeStreamLifecycleObject())
    }

    /// A commit that lands immediately after stream creation — while the
    /// background query-Lattice open is still in flight — must be delivered:
    /// observer registration is synchronous and raw batches buffer until the
    /// open completes.
    @Test(.timeLimit(.minutes(1)))
    func test_changeStream_writeImmediatelyAfterCreationIsDelivered() async throws {
        let lattice = try testLattice(ChangeStreamLifecycleObject.self)
        let stream = lattice.changeStream
        // No yield/sleep: deliberately race the write against the open.
        try lattice.add(ChangeStreamLifecycleObject())
        var sawInsert = false
        for try await refs in stream {
            let resolved = refs.compactMap { $0.resolve(isolation: nil, on: lattice) }
            if resolved.contains(where: {
                $0.tableName == "ChangeStreamLifecycleObject" && $0.operation == .insert
            }) {
                sawInsert = true
                break
            }
        }
        #expect(sawInsert, "insert landed during stream setup was not delivered")
    }

    /// A failed background query-Lattice open must surface as a thrown error
    /// at iteration — not trap the process (the pre-1.0 shape was `try!`).
    @Test(.timeLimit(.minutes(1)))
    func test_changeStream_failedOpenThrowsAtIteration() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "changestream-\(String.random(length: 16))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // wssEndpoint matters: the core's LatticeCache keys on it, and
        // changeStream's query open STRIPS sync fields — so this is the
        // cross-process shape where the query open misses the pooled instance
        // and genuinely reopens the file. A sync-free config would pool-hit
        // and never touch the (deleted) path. The endpoint never connects;
        // connection failures only log.
        let config = Lattice.Configuration(
            fileURL: dir.appending(path: "db.sqlite"),
            authorizationToken: "cs",
            wssEndpoint: URL(string: "ws://localhost:1/unused"))
        let lattice = try Lattice(ChangeStreamLifecycleObject.self, configuration: config)
        defer { try? Lattice.delete(for: config) }

        // The consumer's handle stays open; deleting the parent directory
        // makes the stream's background re-open of the path fail.
        try FileManager.default.removeItem(at: dir)

        let stream = lattice.changeStream // must not trap
        await #expect(throws: (any Error).self) {
            for try await _ in stream { }
        }
    }
}
