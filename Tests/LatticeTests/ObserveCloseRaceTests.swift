#if canImport(Combine)
import Combine  // AnyCancellable on Darwin; Linux uses Lattice's shim (LinuxCompat.swift)
#endif
import Foundation
import Testing
@testable import Lattice

/// Documents the per-isolation reading pattern for code that runs
/// inside an observer block.
///
/// **Background.** When `Lattice.observe(_:where:block:)` fires a
/// notification, the user's block runs inside a cooperative
/// `Task.detached` (Lattice.swift ~1497). If the block captures the
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
/// `ref.resolve()` *inside* the observer body. `resolve()` returns
/// a `Lattice` keyed on the *current* isolation's scheduler — for
/// `Task.detached` that's a separate `swift_lattice` with its own
/// `db_`, so an in-flight `close()` on the attaching actor's
/// instance can't tear down what we're reading. The C++
/// `LatticeCache` returns the same instance for the same
/// `(path, scheduler, …)` key on subsequent fires, so there's no
/// `ensure_tables` thrash.
///
/// These tests exercise the safe pattern across two attaching
/// isolations (`@MainActor` and a custom `actor`). With consumer
/// code following this pattern, the close-during-observe race
/// disappears even though Lattice itself made no API change.
@Suite("Observe close race")
class ObserveCloseRaceTests: BaseTest {
    private let path: String = "\(String.random(length: 32)).sqlite"

    /// `@MainActor`-isolated open + close. Observer body resolves
    /// its own per-isolation `Lattice` via `sendableReference` so
    /// the read survives the close on main.
    @MainActor
    @Test(.disabled(if: isMacOSCI, "cooperative-pool starvation on small CI runners: the test blocks pool threads on DispatchSemaphore.wait inside observer closures; with ~3 pool threads the signaling tasks never schedule. Runs locally + Linux CI. Owner: 1.0 test hygiene (item F)"), .timeLimit(.minutes(5)))
    func test_PerIsolationResolve_SurvivesCloseOnMain() async throws {
        let lattice = try testLattice(path: path, Person.self)
        Self.seed(lattice: lattice, count: 500)

        nonisolated(unsafe) var enteredContinuation: CheckedContinuation<Void, Never>?
        nonisolated(unsafe) var exitedContinuation: CheckedContinuation<Void, Never>?
        let proceed = DispatchSemaphore(value: 0)
        let ref = lattice.sendableReference

        let token = lattice.objects(Person.self).observe { _ in
            enteredContinuation?.resume()
            enteredContinuation = nil
            proceed.wait()
            // Resolve on the cooperative isolation. Different
            // scheduler than `@MainActor` → different
            // `swift_lattice` → different `db_`. The close on main
            // doesn't reach this instance.
            guard let cooperative = ref.resolve() else { return }
            let snapshot = Array(cooperative.objects(Person.self))
            #expect(snapshot.count >= 500)
            exitedContinuation?.resume()
            exitedContinuation = nil
        }

        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
            let trigger = Person()
            trigger.name = "trigger"
            trigger.age = 0
            lattice.add(trigger)
        }

        await withCheckedContinuation { continuation in
            exitedContinuation = continuation
            proceed.signal()
            lattice.close()
        }

        _ = token
    }

    /// Same race, attaching isolation pinned to a custom `actor`
    /// (the shape used by ClaudeCodeIRC's `RoomSyncServer`).
    @Test(.disabled(if: isMacOSCI, "cooperative-pool starvation on small CI runners: the test blocks pool threads on DispatchSemaphore.wait inside observer closures; with ~3 pool threads the signaling tasks never schedule. Runs locally + Linux CI. Owner: 1.0 test hygiene (item F)"), .timeLimit(.minutes(5)))
    func test_PerIsolationResolve_SurvivesCloseOnCustomActor() async throws {
        nonisolated(unsafe) var enteredContinuation: CheckedContinuation<Void, Never>?
        nonisolated(unsafe) var exitedContinuation: CheckedContinuation<Void, Never>?
        let proceed = DispatchSemaphore(value: 0)

        let owner = LatticeOwner()
        try await owner.open(path: path)
        await owner.seed(count: 500)
        let ref = await owner.sendableReference()
        await owner.attachObserver { _ in
            enteredContinuation?.resume()
            enteredContinuation = nil
            proceed.wait()
            guard let cooperative = ref.resolve() else { return }
            let snapshot = Array(cooperative.objects(Person.self))
            #expect(snapshot.count >= 500)
            exitedContinuation?.resume()
            exitedContinuation = nil
        }

        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
            Task { await owner.fireTrigger() }
        }

        await withCheckedContinuation { continuation in
            exitedContinuation = continuation
            proceed.signal()
            Task { await owner.close() }
        }
    }

    private static func seed(lattice: Lattice, count: Int) {
        // 500 rows so each snapshot iteration takes long enough
        // to overlap with `close()`. With the safe pattern the
        // overlap is harmless; without it the run crashes.
        for i in 0..<count {
            let p = Person()
            p.name = "person-\(i)"
            p.age = i
            lattice.add(p)
        }
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
        let url = FileManager.default.temporaryDirectory.appending(path: path)
        self.lattice = try Lattice(
            for: [Person.self],
            configuration: .init(fileURL: url))
    }

    func seed(count: Int) {
        for i in 0..<count {
            let p = Person()
            p.name = "person-\(i)"
            p.age = i
            lattice.add(p)
        }
    }

    func sendableReference() -> LatticeThreadSafeReference {
        lattice.sendableReference
    }

    func attachObserver(body: @escaping @Sendable (CollectionChange) -> Void) {
        token = lattice.objects(Person.self).observe(body)
    }

    func fireTrigger() {
        let p = Person()
        p.name = "trigger"
        p.age = 0
        lattice.add(p)
    }

    func close() {
        lattice.close()
    }
}
