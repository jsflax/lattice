import Foundation
import Testing
import LatticeTestSupport
@_spi(LatticeInternals) @testable import Lattice

@Model private final class SpanHookItem {
    var value: String = ""
}

private final class SpanHookEvents: @unchecked Sendable {
    struct Entry: Equatable, Sendable {
        let name: String
        let scope: LatticePerf.SpanScope
        let isBegin: Bool
        let isMainThread: Bool
    }

    private let lock = NSLock()
    private var values: [Entry] = []
    var entries: [Entry] { lock.withLock { values } }

    func record(_ name: StaticString, scope: LatticePerf.SpanScope, isBegin: Bool) {
        let event = Entry(name: String(describing: name), scope: scope,
                          isBegin: isBegin, isMainThread: Thread.isMainThread)
        lock.withLock { values.append(event) }
    }

    var hook: LatticePerf.SpanHook {
        { [self] name, scope in
            record(name, scope: scope, isBegin: true)
            return { [self] in record(name, scope: scope, isBegin: false) }
        }
    }
}

/// Cancels the caller at worker entry without blocking a cooperative worker
/// while another executor waits to observe that entry.
private final class SpanHookCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelTask: (@Sendable () -> Void)?
    private var requests = 0
    private var eventsWhenCancelled: [SpanHookEvents.Entry]?

    func install(_ cancel: @escaping @Sendable () -> Void) {
        lock.withLock { cancelTask = cancel }
    }

    func request(at entries: [SpanHookEvents.Entry]) {
        let cancel = lock.withLock {
            requests += 1
            let callback = cancelTask
            cancelTask = nil
            return callback
        }
        guard let cancel else { return }
        cancel()
        lock.withLock { eventsWhenCancelled = entries }
    }

    func clear() { lock.withLock { cancelTask = nil } }

    var snapshot: (requests: Int, eventsWhenCancelled: [SpanHookEvents.Entry]?) {
        lock.withLock { (requests, eventsWhenCancelled) }
    }
}

@Suite("Local open span hooks")
struct LocalOpenSpanHookTests {
    @Test func aSpanFinishesOnceThroughItsOriginalHook() {
        let first = SpanHookEvents()
        let replacement = SpanHookEvents()
        let span = LatticePerf.$spanHook.withValue(first.hook) {
            LatticePerf.beginSpan("test.operation", scope: .caller)
        }
        LatticePerf.$spanHook.withValue(replacement.hook) {
            span.end()
            span.end()
        }
        #expect(first.entries.map(\.isBegin) == [true, false])
        #expect(first.entries.allSatisfy { $0.name == "test.operation" && $0.scope == .caller })
        #expect(replacement.entries.isEmpty)
        #expect(LatticePerf.spanHook == nil)
        LatticePerf.beginSpan("unobserved.operation", scope: .caller).end()
        #expect(first.entries.count == 2)
    }

    @Test @MainActor func actualLocalOpenPropagatesTheHookToItsWorker() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = SpanHookEvents()
        let store = try await LatticePerf.$spanHook.withValue(events.hook) {
            try await Lattice.openLocal(for: [SpanHookItem.self],
                configuration: .init(fileURL: directory.appendingPathComponent("store.lattice")))
        }
        defer { store.close() }
        #expect(store.isolation === MainActor.shared)
        #expect(LatticePerf.spanHook == nil)
        let entries = events.entries
        // A scoped implementation may release its temporary native owner after
        // adoption. That is the only optional phase, and it must be one complete
        // worker interval before returning, with no caller interval left open.
        let hasDisposal = entries.contains { $0.name == "Lattice.openLocal.dispose" }
        let expectedNames = [
            "Lattice.openLocal.prepare", "Lattice.openLocal.prepare",
            "Lattice.openLocal.worker.open", "Lattice.openLocal.worker.open",
            "Lattice.openLocal.adopt", "Lattice.openLocal.adopt",
        ] + (hasDisposal ? ["Lattice.openLocal.dispose", "Lattice.openLocal.dispose"] : [])
          + ["Lattice.openLocal.return", "Lattice.openLocal.return"]
        let expectedScopes: [LatticePerf.SpanScope] = [.caller, .caller, .worker, .worker, .caller, .caller]
            + (hasDisposal ? [.worker, .worker] : []) + [.caller, .caller]
        #expect(entries.map(\.name) == expectedNames)
        #expect(entries.map(\.scope) == expectedScopes)
        #expect(entries.map(\.isBegin) == expectedNames.indices.map { $0.isMultiple(of: 2) })
        #if os(macOS)
        #expect(entries.filter { $0.scope == .worker }.allSatisfy { !$0.isMainThread })
        #endif
    }

    @Test @MainActor func cancellationReportsJoinedWorkerDisposal() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = SpanHookEvents()
        let cancellation = SpanHookCancellation()
        defer { cancellation.clear() }
        let task = Task { @MainActor in
            try await LatticePerf.$spanHook.withValue({ name, scope in
                let finish = events.hook(name, scope)
                if String(describing: name) == "Lattice.openLocal.worker.open" {
                    cancellation.request(at: events.entries)
                }
                return finish
            }) {
                let store = try await Lattice.openLocal(for: [SpanHookItem.self],
                    configuration: .init(fileURL: directory.appendingPathComponent("cancel.lattice")))
                store.close()
            }
        }
        // This uninterrupted MainActor turn installs the cancellation before
        // the MainActor task above can begin. Its worker requests it directly,
        // before native open returns, without a scheduler-dependent handshake.
        cancellation.install { task.cancel() }
        switch await task.result {
        case .success: Issue.record("The cancelled local open published a handle")
        case .failure(let error): #expect(error is CancellationError)
        }
        let cancelled = cancellation.snapshot
        #expect(cancelled.requests == 1)
        let beforeCancellation = try #require(cancelled.eventsWhenCancelled)
        #expect(beforeCancellation.map(\.name) == [
            "Lattice.openLocal.prepare", "Lattice.openLocal.prepare",
            "Lattice.openLocal.worker.open",
        ])
        #expect(beforeCancellation.map(\.scope) == [.caller, .caller, .worker])
        #expect(beforeCancellation.map(\.isBegin) == [true, false, true])
        let entries = events.entries
        let expectedNames = [
            "Lattice.openLocal.prepare", "Lattice.openLocal.prepare",
            "Lattice.openLocal.worker.open", "Lattice.openLocal.worker.open",
            "Lattice.openLocal.dispose", "Lattice.openLocal.dispose",
            "Lattice.openLocal.return", "Lattice.openLocal.return",
        ]
        #expect(entries.map(\.name) == expectedNames)
        #expect(entries.map(\.scope) == [.caller, .caller, .worker, .worker,
                                         .worker, .worker, .caller, .caller])
        #expect(entries.map(\.isBegin) == expectedNames.indices.map { $0.isMultiple(of: 2) })
        let disposal = entries.filter { $0.name == "Lattice.openLocal.dispose" }
        #expect(disposal.map(\.isBegin) == [true, false])
        #expect(disposal.allSatisfy { $0.scope == .worker })
        #if os(macOS)
        #expect(disposal.allSatisfy { !$0.isMainThread })
        #endif
        #expect(!entries.contains { $0.name == "Lattice.openLocal.adopt" })
        #expect(LatticePerf.spanHook == nil)
    }

    private func directory() throws -> URL {
        let directory = LatticeTestScratch.directory.appendingPathComponent("span-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
