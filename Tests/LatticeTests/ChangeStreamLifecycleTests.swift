import Testing
import Foundation
@testable import Lattice

// Fixed scalar points only; one invocation in this suite. No payload/row IDs,
// new task, await, sleep, SQL or scheduling hook. Missing phases stay unknown.
private final class CancellationPhaseDiagnostic: @unchecked Sendable {
    enum Stage: String, CaseIterable, Codable, Sendable {
        case stream_create_begin, stream_create_returned
        case query_open_started, query_open_completed, query_ready_returned, query_open_failed
        case consumer_body_entered, consumer_body_exiting
        case cancel_call_begin, cancel_call_returned, parent_wait_begin, parent_resumed
        case stream_cancelled, stream_finished, stream_termination_unknown, stream_termination_returned
    }
    struct Point: Codable { let stage: Stage; let uptime: UInt64 }
    private let lock = NSLock()
    private var times: [Stage: UInt64] = [:]
    private var closed = false

    func record(_ stage: Stage, at uptime: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.lock(); defer { lock.unlock() }
        if !closed && times[stage] == nil { times[stage] = uptime }
    }
    var probe: PayloadObserverDiagnostic {
        PayloadObserverDiagnostic(observer: "changeStreamCancellation") { [self] event in
            if let stage = Stage(rawValue: event.stage) { record(stage, at: event.uptime) }
        }
    }
    func finish(failed: Bool) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let points = times.map { Point(stage: $0.key, uptime: $0.value) }
        let cutoff = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
        guard failed else { return }
        let sorted = points.sorted { $0.uptime < $1.uptime }
        guard let encoded = try? JSONEncoder().encode(sorted), encoded.count <= 8 * 1024 else { return }
        print("DIAGNOSTIC ChangeStreamCancellation: cutoff_ns=\(cutoff) points=\(String(decoding: encoded, as: UTF8.self)) body_exiting_is_not_task_completion=true")
    }
}

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
        let diagnostic = ProcessInfo.processInfo.environment["LATTICE_OBSERVER_WORKER_DIAGNOSTICS"] == "1"
            ? CancellationPhaseDiagnostic() : nil
        defer { diagnostic?.finish(failed: false) }
        diagnostic?.record(.stream_create_begin)
        let stream = lattice._changeStream(diagnostic: diagnostic?.probe)
        diagnostic?.record(.stream_create_returned)

        let consumer = Task {
            diagnostic?.record(.consumer_body_entered)
            defer { diagnostic?.record(.consumer_body_exiting) }
            for try await _ in stream { }
        }
        // Cancel while the consumer is (or is about to be) parked on next().
        await Task.yield()
        diagnostic?.record(.cancel_call_begin)
        consumer.cancel()
        diagnostic?.record(.cancel_call_returned)

        let clock = ContinuousClock()
        let start = clock.now
        // A leaked continuation would park this await until the time limit.
        diagnostic?.record(.parent_wait_begin)
        _ = try? await consumer.value
        diagnostic?.record(.parent_resumed)
        #expect(clock.now - start < .seconds(10),
                "cancelled changeStream iteration did not terminate promptly")
        // Freeze at this assertion, before the later teardown-smoke write.
        // This diagnostic's second clock read is not the assertion verdict.
        diagnostic?.finish(failed: clock.now - start >= .seconds(10))

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
