#if canImport(Combine)
import Combine  // AnyCancellable on Darwin; Linux uses Lattice's shim (LinuxCompat.swift)
#endif
import Foundation
import Testing
@testable import Lattice

/// Documents the per-isolation reading pattern for work started by an
/// observer block. The block returns promptly; a private read thread races
/// its resolved handle's reads against closing the attaching actor's handle.
///
/// **Background (original implementation).** When
/// `Lattice.observe(_:where:block:)` fired a notification, the user's block
/// ran inside a cooperative `Task.detached`. If the block captures the
/// attaching actor's `Lattice` and reads through it (e.g.
/// `lattice.objects(T.self).snapshot()`), it goes through the
/// attaching `swift_lattice`'s `db_` from a thread the attaching
/// actor doesn't own. When the attaching actor calls
/// `lattice.close()` concurrently, the `~database()` destructor
/// races the cooperative thread's iteration → SIGSEGV in
/// `basic_string::__is_long` while copying a
/// `unordered_map<string, property_descriptor>`.
///
/// Real-world repro: ClaudeCodeIRC `Query.Wrapper.fetch()` was
/// captured-`lattice`-style and SIGSEGV'd when
/// `RoomInstance.swap()` closed the @MainActor `Lattice` while a
/// pending observer fire was iterating on the cooperative thread.
/// Crash dump: `claudecodeirc-2026-04-30-084830.ips`.
///
/// **Safe pattern.** Capture `lattice.sendableReference` and call
/// `ref.resolve()` on the independent read thread. `resolve()` returns
/// a `Lattice` keyed on the *current* isolation's scheduler — for
/// this nonisolated thread that's a separate `swift_lattice` with its own
/// `db_`, so an in-flight `close()` on the attaching actor's
/// instance can't tear down what we're reading. The C++
/// `LatticeCache` returns the same instance for the same
/// `(path, scheduler, …)` key on subsequent fires, so there's no
/// `ensure_tables` thrash.
///
/// The DEBUG case also holds Core's active-generation-read witness across
/// owner close; the existing handshakes and their diagnostics remain intact.
///
/// These tests exercise the safe pattern across two attaching
/// isolations (`@MainActor` and a custom `actor`). With consumer
/// code following this pattern, the close-during-observe race
/// disappears even though Lattice itself made no API change.
@Suite("Observe close race")
class ObserveCloseRaceTests: BaseTest {
    private let path: String = "\(String.random(length: 32)).sqlite"

    // Retain the legacy macOS exclusion and its recorded rationale pending
    // qualification of this revised handshake; its callback no longer blocks.

    /// `@MainActor`-isolated open + close. The observer schedules a private
    /// reader so its resolved handle's reads can overlap the close on main.
    @MainActor
    @Test(.disabled(if: isMacOSCI, "cooperative-pool starvation on small CI runners: the test blocks pool threads on DispatchSemaphore.wait inside observer closures; with ~3 pool threads the signaling tasks never schedule. Runs locally + Linux CI. Owner: 1.0 test hygiene (item F)"), .timeLimit(.minutes(5)))
    func test_PerIsolationResolve_SurvivesCloseOnMain() async throws {
        let lattice: Lattice
        do {
            let phase = PayloadObserverDiagnosticLog.beginMainActorPhase("closeRace.openAndSeed")
            defer { PayloadObserverDiagnosticLog.endMainActorPhase("closeRace.openAndSeed", started: phase) }
            lattice = try testLattice(path: path, Person.self)
            try Self.seed(lattice: lattice, count: 500)
        }

        let reader = CloseRaceReadWorker(reference: lattice.sendableReference)
        defer { reader.cancel() }
        let token = lattice.objects(Person.self).observe { _ in
            reader.startOnce()
        }
        defer { token.cancel() }

        let trigger = Person()
        trigger.name = "trigger"
        trigger.age = 0
        try lattice.add(trigger)

        let entered = await reader.waitUntilEntered()
        try #require(entered, "independent reader did not resolve its handle")
        reader.proceed()
        let reading = await reader.waitUntilReading()
        try #require(reading, "independent reader did not enter its read loop")
        do {
            let phase = PayloadObserverDiagnosticLog.beginMainActorPhase("closeRace.close")
            defer { PayloadObserverDiagnosticLog.endMainActorPhase("closeRace.close", started: phase) }
            lattice.close()
        }
        reader.finishClosing()
        let snapshotCount = try #require(await reader.waitUntilExited())
        #expect(snapshotCount >= 500)
    }

    /// Same race, attaching isolation pinned to a custom `actor`
    /// (the shape used by ClaudeCodeIRC's `RoomSyncServer`).
    @Test(.disabled(if: isMacOSCI, "cooperative-pool starvation on small CI runners: the test blocks pool threads on DispatchSemaphore.wait inside observer closures; with ~3 pool threads the signaling tasks never schedule. Runs locally + Linux CI. Owner: 1.0 test hygiene (item F)"), .timeLimit(.minutes(5)))
    func test_PerIsolationResolve_SurvivesCloseOnCustomActor() async throws {
        let owner = LatticeOwner()
        try await owner.open(path: path)
        try await owner.seed(count: 500)
        let reader = CloseRaceReadWorker(reference: await owner.sendableReference())
        defer { reader.cancel() }
        await owner.attachObserver { _ in
            reader.startOnce()
        }

        try await owner.fireTrigger()
        let entered = await reader.waitUntilEntered()
        try #require(entered, "independent reader did not resolve its handle")
        reader.proceed()
        let reading = await reader.waitUntilReading()
        try #require(reading, "independent reader did not enter its read loop")
        await owner.close()
        reader.finishClosing()
        let snapshotCount = try #require(await reader.waitUntilExited())
        #expect(snapshotCount >= 500)
    }

    #if DEBUG
    /// The native generation's in_flight count is held across owner close.
    /// SQL has not begun at the hook; this does not claim opcode-level overlap.
    @MainActor
    @Test(.timeLimit(.minutes(2)))
    func test_PerIsolationResolve_HeldReadSurvivesOwnerCloseOnMain() async throws {
        let lattice = try testLattice(path: path, Person.self)
        try Self.seed(lattice: lattice, count: 500)
        let read = InFlightGenerationRead()
        let reference = lattice.sendableReference
        let ownerIdentity = lattice.backend.identityHash
        let token = lattice.objects(Person.self).observe { _ in
            MainActor.preconditionIsolated()
            read.start(reference: reference, ownerIdentity: ownerIdentity)
        }
        defer { token.cancel(); read.release() }
        let trigger = Person()
        trigger.name = "trigger"
        try lattice.add(trigger)

        let prepared = await Self.poll { read.state.hookEntered || read.state.finished }
        let held = prepared && read.state.hookEntered && !read.state.queryReturned
        #expect(held, "native active-generation-read witness was not held: \(read.state.failure ?? "no hook")")
        guard held else {
            read.release()
            _ = await Self.poll { read.state.finished }
            lattice.close()
            return
        }
        // No owning actor, observer callback or cooperative-pool thread waits.
        // The dedicated reader Thread is inside Core's native active-read hook.
        lattice.close()
        #expect(lattice.objects(Person.self).count == 0)
        #expect(read.state.hookEntered && !read.state.queryReturned,
                "the active read must remain held until owner close returns")
        read.release()
        let finished = await Self.poll { read.state.finished }
        #expect(finished, "independent reader Thread did not finish")
        #expect(read.state.failure == nil)
        #expect(read.state.independentBackend)
        #expect(read.state.generationID != 0)
        #expect(read.state.queryReturned)
        #expect(!read.state.stale)
        #expect(read.state.snapshotCount == 501)
    }
    #endif

    private static func poll(_ condition: @escaping @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private static func seed(lattice: Lattice, count: Int) throws {
        // 500 rows so each snapshot iteration takes long enough
        // to overlap with `close()`. With the safe pattern the
        // overlap is harmless; without it the run crashes.
        for i in 0..<count {
            let p = Person()
            p.name = "person-\(i)"
            p.age = i
            try lattice.add(p)
        }
    }
}

/// One deliberate blocking step on a private, deep-stack thread. No observer
/// callback waits, and repeated callbacks cannot launch another parked thread.
private final class CloseRaceReadWorker: @unchecked Sendable {
    private let reference: LatticeThreadSafeReference
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var started = false
    private var cancelled = false
    private var closingFinished = false
    private let entered = AsyncStream<Void>.makeStream()
    private let reading = AsyncStream<Void>.makeStream()
    private let exited = AsyncStream<Int>.makeStream()

    init(reference: LatticeThreadSafeReference) { self.reference = reference }

    func startOnce() {
        lock.lock()
        guard !started, !cancelled else { lock.unlock(); return }
        started = true
        lock.unlock()

        let thread = Thread { [self] in
            defer {
                entered.continuation.finish()
                reading.continuation.finish()
                exited.continuation.finish()
            }
            // performReads owns the resolved handle until it returns; the
            // exit signal therefore follows that handle's read lifetime.
            if let minimumCount = performReads() {
                exited.continuation.yield(minimumCount)
            }
        }
        thread.name = "lattice.test-close-race-reader"
        thread.stackSize = 8 << 20
        thread.start()
    }

    private func performReads() -> Int? {
        // Resolve before the attaching handle closes; the worker's nil
        // isolation gives it an independently owned read handle.
        guard !isCancelled, let cooperative = reference.resolve() else { return nil }
        entered.continuation.yield()
        entered.continuation.finish()
        gate.wait()
        guard !isCancelled else { return nil }

        // Establish a real pre-close read before allowing the owner to close.
        var minimumCount = Array(cooperative.objects(Person.self)).count
        reading.continuation.yield()
        reading.continuation.finish()
        // Race continued reads against close, then require a final post-close
        // read too. No timing assumption decides when this loop is finished.
        repeat {
            minimumCount = min(minimumCount, Array(cooperative.objects(Person.self)).count)
        } while !shouldFinishReading
        guard !isCancelled else { return nil }
        return min(minimumCount, Array(cooperative.objects(Person.self)).count)
    }

    func proceed() { gate.signal() }

    func finishClosing() {
        lock.lock(); defer { lock.unlock() }
        closingFinished = true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        // Release parked waits and end stream waits. Resolver/SQL operations
        // are not interrupted; the worker exits after its current call returns.
        gate.signal()
        entered.continuation.finish()
        reading.continuation.finish()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    private var shouldFinishReading: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled || closingFinished
    }

    func waitUntilEntered() async -> Bool {
        for await _ in entered.stream { return true }
        return false
    }

    func waitUntilReading() async -> Bool {
        for await _ in reading.stream { return true }
        return false
    }

    func waitUntilExited() async -> Int? {
        for await count in exited.stream { return count }
        return nil
    }
}

/// Custom actor that owns a `Lattice` end-to-end — open, seed,
/// attach observer, fire a trigger, close. Mirrors the
/// `RoomSyncServer` shape (a background actor that owns its own
/// `Lattice` handle) so the close-during-observe race exercises
/// the non-`@MainActor` isolation path.
private actor LatticeOwner {
    private var lattice: Lattice!
    private var token: AnyCancellable?

    func open(path: String) throws {
        let url = testTemporaryDirectory.appending(path: path)
        self.lattice = try Lattice(
            for: [Person.self],
            configuration: .init(fileURL: url))
    }

    func seed(count: Int) throws {
        for i in 0..<count {
            let p = Person()
            p.name = "person-\(i)"
            p.age = i
            try lattice.add(p)
        }
    }

    func sendableReference() -> LatticeThreadSafeReference {
        lattice.sendableReference
    }

    func attachObserver(body: @escaping @Sendable (CollectionChange) -> Void) {
        token = lattice.objects(Person.self).observe(body)
    }

    func fireTrigger() throws {
        let p = Person()
        p.name = "trigger"
        p.age = 0
        try lattice.add(p)
    }

    func close() {
        lattice.close()
    }
}

#if DEBUG
/// Resolves and queries only on one dedicated Thread. The witness is emitted
/// by Core after gen->in_flight increments, never by a pre-query Swift gate.
private final class InFlightGenerationRead: @unchecked Sendable {
    struct State {
        var started = false
        var hookEntered = false
        var queryReturned = false
        var finished = false
        var independentBackend = false
        var generationID: UInt64 = 0
        var snapshotCount: Int64?
        var stale = false
        var failure: String?
    }
    private let values = LockedBox(State())
    private let worker = LockedBox<Thread?>(nil)
    private let proceed = DispatchSemaphore(value: 0)
    var state: State {
        var snapshot = values.withLock { $0 }
        snapshot.finished = worker.withLock { $0?.isFinished == true }
        return snapshot
    }

    func start(reference: LatticeThreadSafeReference, ownerIdentity: Int64) {
        let first = values.withLock { state in
            guard !state.started else { return false }
            state.started = true
            return true
        }
        guard first else { return }
        let thread = Thread { [weak self] in
            guard let self else { return }
            guard let reader = reference.resolve(isolation: nil),
                  let backend = reader.backend as? CxxBackend else {
                values.withLock { $0.failure = "independent Cxx reader did not resolve" }
                return
            }
            let generation = backend.acquireReadGeneration()
            guard generation != 0 else {
                values.withLock { $0.failure = "reader did not acquire a generation" }
                return
            }
            values.withLock {
                $0.independentBackend = reader.backend.identityHash != ownerIdentity
                $0.generationID = generation
            }
            defer {
                // This fixture has only this generation query. It has returned
                // before hook mutation; release the hold only after clearing.
                if !backend.setGenerationQueryGapForTesting(nil) {
                    values.withLock { $0.failure = "test generation hook did not clear" }
                }
                backend.releaseReadGeneration(generation)
            }
            let installed = backend.setGenerationQueryGapForTesting { [weak self] in
                guard let self else { return }
                // Never park the shared observer worker or any other executor,
                // even if a future fixture change adds another generation read.
                guard worker.withLock({ $0 === Thread.current }) else { return }
                let first = values.withLock { state in
                    guard !state.hookEntered else { return false }
                    state.hookEntered = true
                    return true
                }
                guard first else { return }
                if proceed.wait(timeout: .now() + 30) != .success {
                    values.withLock { $0.failure = "owner-close active-read gate timed out" }
                }
            }
            guard installed else {
                values.withLock { $0.failure = "test generation hook did not install" }
                return
            }
            let count = backend.countAt(generation: generation, table: Person.entityName,
                                        where: nil, groupBy: nil, distinctBy: nil, params: [])
            let stale = backend.lastGenerationReadStale()
            values.withLock {
                $0.snapshotCount = count
                $0.stale = stale
                $0.queryReturned = true
            }
            // Never explicitly close the nil-isolation backend: it may also be
            // held by the observer worker's already completed decision reader.
            withExtendedLifetime(reader) {}
        }
        thread.name = "lattice.test.active-generation-read"
        thread.stackSize = ObserverDeliveryWorker.requiredStackSize
        worker.withLock { $0 = thread }
        thread.start()
    }

    func release() { proceed.signal() }
}
#endif
