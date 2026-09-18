import Foundation
import Testing
@testable import Lattice

@Suite("Actor delivery mailbox", .serialized)
struct ObserverActorDeliveryTests {
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func detachedSubmissionReturnsToCreationActor() async throws {
        let mailbox = ObserverActorDelivery(isolation: MainActor.shared)
        let values = ActorMailboxValues()
        let complete = ActorMailboxSignal()
        await Task.detached {
            for index in 0..<50 {
                mailbox.enqueue {
                    MainActor.preconditionIsolated()
                    values.append(index)
                    if index == 49 { complete.send() }
                }
            }
        }.value
        try await complete.wait()
        #expect(values.snapshot == Array(0..<50))
    }

    @Test(.timeLimit(.minutes(1)))
    func heldActorAdmitsOneTurnThenDrainsEveryBatchInOrder() async throws {
        let owner = ActorMailboxOwner()
        let mailbox = await owner.makeMailbox()
        let gate = owner.executor.hold()
        defer { gate.release.signal() }
        try await gate.entered.wait()
        let before = owner.executor.admissions
        let values = ActorMailboxValues()
        let complete = ActorMailboxSignal()
        for index in 0..<200 {
            mailbox.enqueue {
                owner.preconditionIsolated()
                values.append(index)
                if index == 199 { complete.send() }
            }
        }
        let queuedAdmissions = owner.executor.admissions - before
        #expect(queuedAdmissions == 1, "a held actor has one admitted mailbox turn")
        #expect(values.snapshot.isEmpty)
        gate.release.signal()
        try await complete.wait()
        #expect(values.snapshot == Array(0..<200))
        #expect(!gate.timedOut)
    }

    @Test(.timeLimit(.minutes(1)))
    func callbackAndCaptureReleaseCanEnqueueAgain() async throws {
        let owner = ActorMailboxOwner()
        let mailbox = await owner.makeMailbox()
        let values = ActorMailboxValues()
        let complete = ActorMailboxSignal()
        mailbox.enqueue {
            owner.preconditionIsolated()
            values.append(1)
            mailbox.enqueue { values.append(3); complete.send() }
            values.append(2)
        }
        try await complete.wait()
        #expect(values.snapshot == [1, 2, 3])

        let released = ActorMailboxSignal()
        func enqueueCapture() {
            let capture = ActorMailboxLifetime {
                mailbox.enqueue { released.send() }
            }
            mailbox.enqueue { withExtendedLifetime(capture) {} }
        }
        enqueueCapture()
        try await released.wait()
    }

    @Test(.timeLimit(.minutes(1)))
    func alreadyQueuedBatchSurvivesProducerCancellation() async throws {
        let owner = ActorMailboxOwner()
        let mailbox = await owner.makeMailbox()
        let gate = owner.executor.hold()
        defer { gate.release.signal() }
        try await gate.entered.wait()
        let queued = ActorMailboxSignal()
        let delivered = ActorMailboxSignal()
        let producer = Task.detached {
            mailbox.enqueue { owner.preconditionIsolated(); delivered.send() }
            queued.send()
            do { try await Task.sleep(for: .seconds(30)) } catch { }
            return Task.isCancelled
        }
        defer { producer.cancel() }
        try await queued.wait()
        producer.cancel()
        let wasCancelled = await producer.value
        #expect(wasCancelled)
        gate.release.signal()
        try await delivered.wait()
        #expect(!gate.timedOut)
    }

    @Test(.timeLimit(.minutes(1)))
    func pendingBatchesOutliveFacadeAndIdleMailboxIsReleased() async throws {
        let owner = ActorMailboxOwner()
        var mailbox: ObserverActorDelivery? = await owner.makeMailbox()
        let weakMailbox = WeakActorMailbox(mailbox!)
        let gate = owner.executor.hold()
        defer { gate.release.signal() }
        try await gate.entered.wait()
        let values = ActorMailboxValues()
        let complete = ActorMailboxSignal()
        for index in 0..<10 {
            mailbox!.enqueue {
                owner.preconditionIsolated()
                values.append(index)
                if index == 9 { complete.send() }
            }
        }
        mailbox = nil
        #expect(weakMailbox.value != nil, "accepted payloads retain a pending lease")
        gate.release.signal()
        try await complete.wait()
        // Completion marks the callback, not the end of its actor turn. An
        // actor barrier follows that final turn before checking idle lifetime.
        await owner.barrier()
        #expect(values.snapshot == Array(0..<10))
        #expect(!gate.timedOut)
        #expect(weakMailbox.value == nil, "an idle mailbox has no self-cycle")
    }
}

private final class ActorMailboxSignal: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    init() {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream
        continuation = pair.continuation
    }
    func send() { continuation.yield(()); continuation.finish() }
    func wait() async throws {
        var iterator = stream.makeAsyncIterator()
        guard await iterator.next() != nil else { throw CancellationError() }
    }
}

private final class ActorMailboxValues: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func append(_ value: Int) { lock.withLock { values.append(value) } }
    var snapshot: [Int] { lock.withLock { values } }
}

private final class ActorMailboxLifetime: Sendable {
    private let released: @Sendable () -> Void
    init(_ released: @escaping @Sendable () -> Void) { self.released = released }
    deinit { released() }
}

private final class WeakActorMailbox: @unchecked Sendable {
    weak var value: ObserverActorDelivery?
    init(_ value: ObserverActorDelivery) { self.value = value }
}

private final class ActorMailboxGate: @unchecked Sendable {
    let entered = ActorMailboxSignal()
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var expired = false
    var timedOut: Bool { lock.withLock { expired } }
    func wait() {
        let didExpire = release.wait(timeout: .now() + 30) != .success
        lock.withLock { expired = didExpire }
    }
}

private final class ActorMailboxExecutor: SerialExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "lattice.actor-mailbox-test")
    private let lock = NSLock()
    private var count = 0
    var admissions: Int { lock.withLock { count } }
    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        lock.withLock { count += 1 }
        queue.async { unowned.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }
    func hold() -> ActorMailboxGate {
        let gate = ActorMailboxGate()
        queue.async {
            gate.entered.send()
            // Only this dedicated serial queue is held; no cooperative task
            // or MainActor waits synchronously. Failure cleanup also releases.
            gate.wait()
        }
        return gate
    }
}

private actor ActorMailboxOwner {
    nonisolated let executor = ActorMailboxExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    func makeMailbox() -> ObserverActorDelivery { ObserverActorDelivery(isolation: self) }
    func barrier() {}
}
