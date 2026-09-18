import Testing
import Foundation
@testable import Lattice
import XCTest
#if canImport(SQLite3)
import SQLite3
#endif

// Fixed scalar diagnostics for one test invocation. No event payloads, SQL,
// new tasks/awaits, readiness gate, or changed notification semantics.
private final class CrossProcessObservationDiagnostic: @unchecked Sendable {
    enum Stage: String, CaseIterable, Codable {
        case observer_registration_begin, observer_registration_returned
        case child_launch_begin, child_launch_returned, child_exited
        case consumer_wait_begin, insert_callback, update_callback, delete_callback, consumer_received, consumer_wait_returned
        case callback_entry
        case enqueue_boundary, job_started, collection_resolution_skipped
        case collection_resolution_nil, collection_decisions_started, collection_decisions_completed
        case collection_actor_hop, collection_actor_delivery_started
        case collection_emission_started, collection_emission_returned
        case cancel_call_begin, cancel_call_returned, cancel_requested, cancel_returned
    }
    enum ChildStage: String, CaseIterable, Codable {
        case open_begin, open_returned, owner_found, write_begin, write_returned
        case list_append_begin, list_append_returned
    }
    struct Point: Codable { let stage: Stage; var firstNS: UInt64; var lastNS: UInt64; var count: UInt64 }
    struct ChildPoint: Codable { let stage: ChildStage; let uptimeNS: UInt64? }
    struct Snapshot: Codable {
        let cutoffNS: UInt64
        let observer: String
        let points: [Point]
        let childPoints: [ChildPoint]
        let childExitStatus: Int32?
        let childExitReason: Int?
        let childStillRunning: Bool?
    }
    let directory: URL
    let observer: String
    private let lock = NSLock()
    private var points: [Stage: Point] = [:]
    private var exitStatus: Int32?
    private var exitReason: Int?
    private var closed = false

    init?(observer: String = "crossProcessObservation") {
        self.observer = observer
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        directory = packageRoot.appendingPathComponent(".build/xproc-stage-fixtures")
            .appendingPathComponent(UUID().uuidString)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return nil }
    }
    func record(_ stage: Stage, at time: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        if var old = points[stage] {
            old.lastNS = time
            if old.count < UInt64.max { old.count += 1 }
            points[stage] = old
        } else {
            points[stage] = Point(stage: stage, firstNS: time, lastNS: time, count: 1)
        }
    }
    var probe: PayloadObserverDiagnostic {
        PayloadObserverDiagnostic(observer: observer) { [self] event in
            if let stage = Stage(rawValue: event.stage) { record(stage, at: event.uptime) }
        }
    }
    func childExited(_ process: Process) {
        let status = process.terminationStatus
        let reason = process.terminationReason.rawValue
        record(.child_exited)
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        exitStatus = status
        exitReason = reason
    }
    static func childPoint(_ stage: ChildStage) {
        guard let root = ProcessInfo.processInfo.environment["LATTICE_XPROC_DIAGNOSTIC_DIRECTORY"] else { return }
        let time = String(DispatchTime.now().uptimeNanoseconds)
        // Seven fixed files of at most20 ASCII bytes. Atomic replacement lets
        // the parent distinguish a complete point from unavailable evidence.
        try? Data(time.utf8).write(to: URL(fileURLWithPath: root).appendingPathComponent(stage.rawValue), options: .atomic)
    }
    func finish(failed: Bool, childStillRunning: Bool?) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let copy = Array(points.values)
        let status = exitStatus, reason = exitReason
        let cutoff = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
        guard failed else { return }
        let childPoints = ChildStage.allCases.map { stage -> ChildPoint in
            let path = directory.appendingPathComponent(stage.rawValue)
            // No unbounded reads, even when the child never reached setup.
            let handle = try? FileHandle(forReadingFrom: path)
            defer { try? handle?.close() }
            let data = try? handle?.read(upToCount: 21)
            let time = data.flatMap { $0.count <= 20 ? UInt64(String(decoding: $0, as: UTF8.self)) : nil }
            return ChildPoint(stage: stage, uptimeNS: time.flatMap { $0 <= cutoff ? $0 : nil })
        }
        let snapshot = Snapshot(cutoffNS: cutoff, observer: observer, points: copy.sorted { $0.firstNS < $1.firstNS },
                                childPoints: childPoints, childExitStatus: status,
                                childExitReason: reason, childStillRunning: childStillRunning)
        guard let data = try? JSONEncoder().encode(snapshot), data.count <= 16 * 1024 else { return }
        print("DIAGNOSTIC CrossProcessObservation: \(String(decoding: data, as: UTF8.self))")
    }
    func removeFixture() { try? FileManager.default.removeItem(at: directory) }
}

/// XCTest wrapper so `xctest -XCTest` can target the child path.
/// (`xctest -XCTest` only filters XCTest tests, not Swift Testing @Test.)
class CrossProcessChildRunner: XCTestCase {
    func testChildPath() throws {
        guard let childDBPath = ProcessInfo.processInfo.environment["LATTICE_XPROC_CHILD_DB_PATH"] else { return }
        let fileURL = URL(fileURLWithPath: childDBPath)
        let op = ProcessInfo.processInfo.environment["LATTICE_XPROC_CHILD_OP"] ?? "insert"

        switch op {
        case "update", "insert":
            CrossProcessObservationDiagnostic.childPoint(.open_begin)
            let lattice = try Lattice(
                for: [Person.self, Dog.self],
                configuration: .init(fileURL: fileURL)
            )
            CrossProcessObservationDiagnostic.childPoint(.open_returned)
            if op == "update" {
                if let person = lattice.objects(Person.self).where({ $0.name == "ExistingPerson" }).first {
                    person.age = 99
                }
            } else {
                let p = Person()
                p.name = "FromOtherProcess"
                p.age = 42
                CrossProcessObservationDiagnostic.childPoint(.write_begin)
                try lattice.add(p)
                CrossProcessObservationDiagnostic.childPoint(.write_returned)
            }
        case "update_audit":
            var db: OpaquePointer?
            guard sqlite3_open(childDBPath, &db) == SQLITE_OK else { return }
            defer { sqlite3_close(db) }
            sqlite3_exec(db, "UPDATE AuditLog SET isSynchronized = 1 WHERE isSynchronized = 0", nil, nil, nil)
            _lattice_post_cross_process_notification(std.string(childDBPath))
        case "append_to_list":
            let lattice = try Lattice(
                for: [Person.self, Dog.self, PersonWithDogs.self],
                configuration: .init(fileURL: fileURL)
            )
            if let owner = lattice.objects(PersonWithDogs.self).where({ $0.name == "DogOwner" }).first {
                let dog = Dog()
                dog.name = "Buddy"
                try lattice.add(dog)
                owner.dogs.append(dog)
            }
        case "append_to_virtual_list":
            CrossProcessObservationDiagnostic.childPoint(.open_begin)
            let lattice = try Lattice(
                for: [TestDog.self, TestCat.self, TestPersonWithPets.self],
                configuration: .init(fileURL: fileURL)
            )
            CrossProcessObservationDiagnostic.childPoint(.open_returned)
            if let owner = lattice.objects(TestPersonWithPets.self).where({ $0.label == "PetOwner" }).first {
                CrossProcessObservationDiagnostic.childPoint(.owner_found)
                let dog = TestDog()
                dog.name = "Buddy"
                dog.breed = "Lab"
                CrossProcessObservationDiagnostic.childPoint(.write_begin)
                try lattice.add(dog)
                CrossProcessObservationDiagnostic.childPoint(.write_returned)
                CrossProcessObservationDiagnostic.childPoint(.list_append_begin)
                owner.pets.append(dog as any Animal)
                CrossProcessObservationDiagnostic.childPoint(.list_append_returned)
            }
        case "multi_row_transaction":
            let lattice = try Lattice(
                for: [Person.self, Dog.self],
                configuration: .init(fileURL: fileURL)
            )
            try lattice.transaction {
                for i in 0..<3 {
                    let p = Person()
                    p.name = "MultiRow_\(i)"
                    p.age = i
                    try lattice.add(p)
                }
            }
        default:
            let lattice = try Lattice(
                for: [Person.self, Dog.self],
                configuration: .init(fileURL: fileURL)
            )
            let p = Person()
            p.name = "FromOtherProcess"
            p.age = 42
            try lattice.add(p)
        }
    }
}

/// Returns (executableURL, arguments) for spawning the child test process.
/// Handles SPM on macOS (`swiftpm-testing-helper`), SPM on Linux (direct `.xctest` binary),
/// and Xcode (`xctest`) runners.
private func childProcessConfig(filter: String = "crossProcessObservation") -> (URL, [String])? {
    let args = ProcessInfo.processInfo.arguments

    // SPM (macOS): argv[0] is swiftpm-testing-helper, args include --test-bundle-path
    if args[0].hasSuffix("swiftpm-testing-helper"),
       let idx = args.firstIndex(of: "--test-bundle-path"), idx + 1 < args.count {
        let bundleBinary = args[idx + 1]
        return (
            URL(fileURLWithPath: args[0]),
            [
                "--test-bundle-path", bundleBinary,
                "--filter", filter,
                bundleBinary,
                "--testing-library", "swift-testing"
            ]
        )
    }

    // SPM (Linux): argv[0] is the .xctest binary itself, directly executable
    if args[0].hasSuffix(".xctest"),
       args.contains("--testing-library") {
        return (
            URL(fileURLWithPath: args[0]),
            ["--filter", filter, "--testing-library", "swift-testing"]
        )
    }

    #if canImport(ObjectiveC)
    // Xcode: use xctest to run the .xctest bundle
    let bundle = Bundle(for: CrossProcessChildRunner.self)
    guard let bundlePath = bundle.bundlePath as String?,
          bundlePath.hasSuffix(".xctest") else { return nil }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    proc.arguments = ["-f", "xctest"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    try? proc.run()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else { return nil }
    let xctestPath = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !xctestPath.isEmpty else { return nil }

    return (
        URL(fileURLWithPath: xctestPath),
        ["-XCTest", "CrossProcessChildRunner/testChildPath", bundlePath]
    )
    #endif

    return nil
}

/// Spawns a child process (fire-and-forget from the caller's perspective).
@discardableResult
private func spawnChild(execURL: URL, args: [String], dbPath: String, op: String,
                        diagnostic: CrossProcessObservationDiagnostic? = nil) -> Process {
    let child = Process()
    child.executableURL = execURL
    var env = ProcessInfo.processInfo.environment
    env["LATTICE_XPROC_CHILD_DB_PATH"] = dbPath
    env["LATTICE_XPROC_CHILD_OP"] = op
    for key in env.keys where key.hasPrefix("XCTest") {
        env.removeValue(forKey: key)
    }
    if let diagnostic { env["LATTICE_XPROC_DIAGNOSTIC_DIRECTORY"] = diagnostic.directory.path }
    child.environment = env
    child.arguments = args
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    if let diagnostic {
        child.terminationHandler = { process in diagnostic.childExited(process) }
    } else {
        child.terminationHandler = nil
    }
    try! child.run()
    return child
}

@Suite("Cross-Process Observation Tests")
struct CrossProcessTests {

    /// Tests that `withObservationTracking` (what @Bindable uses) detects
    /// cross-process property changes on a hydrated model instance.
    @Test(.timeLimit(.minutes(5)))
    func crossProcessBindableObservation() async throws {
        // ── Child path ──────────────────────────────────────────────
        if let childDBPath = ProcessInfo.processInfo.environment["LATTICE_XPROC_CHILD_DB_PATH"] {
            let op = ProcessInfo.processInfo.environment["LATTICE_XPROC_CHILD_OP"] ?? "insert"
            guard op == "update" else { return }
            let fileURL = URL(fileURLWithPath: childDBPath)
            let lattice = try Lattice(
                for: [Person.self, Dog.self],
                configuration: .init(fileURL: fileURL)
            )
            if let person = lattice.objects(Person.self).where({ $0.name == "ExistingPerson" }).first {
                person.age = 99
            }
            return
        }

        // ── Parent path ─────────────────────────────────────────────
        let dbName = "xproc_bindable_\(UUID().uuidString).sqlite"
        let fileURL = FileManager.default.temporaryDirectory.appending(path: dbName)
        let dbPath = fileURL.path(percentEncoded: false)

        let lattice = try Lattice(
            for: [Person.self, Dog.self],
            configuration: .init(fileURL: fileURL)
        )
        defer { try? Lattice.delete(for: .init(fileURL: fileURL)) }

        let seed = Person()
        seed.name = "ExistingPerson"
        seed.age = 1
        try lattice.add(seed)

        let person = lattice.objects(Person.self).where { $0.name == "ExistingPerson" }.first!

        guard let (execURL, childArgs) = childProcessConfig(filter: "crossProcessBindableObservation") else {
            Issue.record("Could not determine child process configuration")
            return
        }

        // AsyncStream that yields once when withObservationTracking fires.
        // `for await` is cancellation-safe — .timeLimit can kill it.
        let observations = AsyncStream<Void> { stream in
            withObservationTracking {
                _ = person.age
            } onChange: {
                stream.yield()
                stream.finish()
            }
            spawnChild(execURL: execURL, args: childArgs, dbPath: dbPath, op: "update")
        }

        var fired = false
        for await _ in observations { fired = true }

        #expect(fired, "withObservationTracking did not fire — @Bindable would not update from cross-process change")
        #expect(person.age == 99, "Expected age 99 after cross-process update, got \(person.age)")
    }

    @Test(.timeLimit(.minutes(5)))
    func crossProcessObservation() async throws {
        // ── Child path ──────────────────────────────────────────────
        if let childDBPath = ProcessInfo.processInfo.environment["LATTICE_XPROC_CHILD_DB_PATH"] {
            let fileURL = URL(fileURLWithPath: childDBPath)
            CrossProcessObservationDiagnostic.childPoint(.open_begin)
            let lattice = try Lattice(
                for: [Person.self, Dog.self],
                configuration: .init(fileURL: fileURL)
            )

            CrossProcessObservationDiagnostic.childPoint(.open_returned)
            let op = ProcessInfo.processInfo.environment["LATTICE_XPROC_CHILD_OP"] ?? "insert"
            switch op {
            case "update":
                if let person = lattice.objects(Person.self).where({ $0.name == "ExistingPerson" }).first {
                    person.age = 99
                }
            default:
                let p = Person()
                p.name = "FromOtherProcess"
                p.age = 42
                CrossProcessObservationDiagnostic.childPoint(.write_begin)
                try lattice.add(p)
                CrossProcessObservationDiagnostic.childPoint(.write_returned)
            }
            return
        }

        // ── Parent path ─────────────────────────────────────────────
        let dbName = "xproc_\(UUID().uuidString).sqlite"
        let fileURL = FileManager.default.temporaryDirectory.appending(path: dbName)
        let dbPath = fileURL.path(percentEncoded: false)

        let lattice = try Lattice(
            for: [Person.self, Dog.self],
            configuration: .init(fileURL: fileURL)
        )
        defer { try? Lattice.delete(for: .init(fileURL: fileURL)) }

        let initial = Person()
        initial.name = "ExistingPerson"
        initial.age = 1
        try lattice.add(initial)

        guard let (execURL, childArgs) = childProcessConfig() else {
            Issue.record("Could not determine child process configuration")
            return
        }

        let diagnosticsEnabled = ProcessInfo.processInfo.environment["LATTICE_OBSERVER_WORKER_DIAGNOSTICS"] == "1"
        let diagnostic = diagnosticsEnabled ? CrossProcessObservationDiagnostic() : nil
        if diagnosticsEnabled && diagnostic == nil {
            print("DIAGNOSTIC CrossProcessObservation: unavailable_fixture")
        }
        var child: Process?
        defer {
            diagnostic?.finish(failed: false, childStillRunning: child?.isRunning)
            // Do not unlink a fixture while a still-running child might write.
            // Process ownership is retained to this point; no child deadline,
            // kill, await or existing test deadline is introduced or changed.
            if child?.isRunning != true { diagnostic?.removeFixture() }
            withExtendedLifetime(child) {}
        }
        var cancellable: AnyCancellable?
        let changes = AsyncStream<Void> { stream in
            diagnostic?.record(.observer_registration_begin)
            let results = lattice.objects(Person.self)
            // TableResults.observe forwards this same handle, element type
            // and whereStatement to _observeCollection. Retain construction
            // and the actual predicate while adding only its diagnostic tap.
            cancellable = lattice._observeCollection(Person.self, where: results.whereStatement,
                                                      diagnostic: diagnostic?.probe) { change in
                if case .insert = change {
                    diagnostic?.record(.insert_callback)
                    stream.yield()
                    stream.finish()
                }
            }
            diagnostic?.record(.observer_registration_returned)
            diagnostic?.record(.child_launch_begin)
            child = spawnChild(execURL: execURL, args: childArgs, dbPath: dbPath, op: "insert", diagnostic: diagnostic)
            diagnostic?.record(.child_launch_returned)
        }

        var fired = false
        diagnostic?.record(.consumer_wait_begin)
        for await _ in changes {
            diagnostic?.record(.consumer_received)
            fired = true
        }
        diagnostic?.record(.consumer_wait_returned)
        diagnostic?.record(.cancel_call_begin)
        cancellable?.cancel()
        diagnostic?.record(.cancel_call_returned)

        #expect(fired, "Cross-process observer did not fire")
        diagnostic?.finish(failed: !fired, childStillRunning: child?.isRunning)

        let results = lattice.objects(Person.self).where { $0.name == "FromOtherProcess" }
        #expect(results.count == 1)
        if let found = results.first {
            #expect(found.age == 42)
        }
    }

    @Test(.timeLimit(.minutes(5)))
    func selfNotificationSuppressed() async throws {
        guard ProcessInfo.processInfo.environment["LATTICE_XPROC_CHILD_DB_PATH"] == nil else { return }

        let dbName = "xproc_self_\(UUID().uuidString).sqlite"
        let fileURL = FileManager.default.temporaryDirectory.appending(path: dbName)
        let lattice = try Lattice(
            for: [Person.self, Dog.self],
            configuration: .init(fileURL: fileURL)
        )
        defer { try? Lattice.delete(for: .init(fileURL: fileURL)) }

        var insertCount = 0
        var cancellable: AnyCancellable?

        // The observer fires synchronously during add(), so the continuation
        // resumes immediately — no cancellation risk here.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            cancellable = lattice.objects(Person.self).observe { change in
                if case .insert = change {
                    insertCount += 1
                }
                guard !resumed else { return }
                resumed = true
                continuation.resume()
            }

            let p = Person()
            p.name = "LocalPerson"
            p.age = 10
            try! lattice.add(p)
        }

        // Wait a bit to ensure no spurious duplicate notifications arrive
        try await Task.sleep(for: .milliseconds(200))

        cancellable?.cancel()
        #expect(insertCount == 1,
                "Expected 1 insert notification, got \(insertCount) — self-notification not suppressed")
    }

    @Test(.timeLimit(.minutes(5)))
    func crossProcessObjectObservation() async throws {
        // ── Child path ──────────────────────────────────────────────
        if let childDBPath = ProcessInfo.processInfo.environment["LATTICE_XPROC_CHILD_DB_PATH"] {
            let op = ProcessInfo.processInfo.environment["LATTICE_XPROC_CHILD_OP"] ?? "insert"
            guard op == "update" else { return }
            let fileURL = URL(fileURLWithPath: childDBPath)
            let lattice = try Lattice(
                for: [Person.self, Dog.self],
                configuration: .init(fileURL: fileURL)
            )
            if let person = lattice.objects(Person.self).where({ $0.name == "ExistingPerson" }).first {
                person.age = 99
            }
            return
        }

        // ── Parent path ─────────────────────────────────────────────
        let dbName = "xproc_obj_\(UUID().uuidString).sqlite"
        let fileURL = FileManager.default.temporaryDirectory.appending(path: dbName)
        let dbPath = fileURL.path(percentEncoded: false)

        let lattice = try Lattice(
            for: [Person.self, Dog.self],
            configuration: .init(fileURL: fileURL)
        )
        defer { try? Lattice.delete(for: .init(fileURL: fileURL)) }

        let seed = Person()
        seed.name = "ExistingPerson"
        seed.age = 1
        try lattice.add(seed)

        let person = lattice.objects(Person.self).where { $0.name == "ExistingPerson" }.first!

        guard let (execURL, childArgs) = childProcessConfig(filter: "crossProcessObjectObservation") else {
            Issue.record("Could not determine child process configuration")
            return
        }

        var cancellable: AnyCancellable?
        let changes = AsyncStream<Void> { stream in
            cancellable = person.objectWillChange.sink {
                stream.yield()
                stream.finish()
            }
            spawnChild(execURL: execURL, args: childArgs, dbPath: dbPath, op: "update")
        }

        var fired = false
        for await _ in changes { fired = true }
        cancellable?.cancel()

        #expect(fired, "objectWillChange did not fire on hydrated instance from cross-process update")
        #expect(person.age == 99, "Expected age 99 after cross-process update, got \(person.age)")
    }

    @Test(.timeLimit(.minutes(5)))
    func crossProcessUpdateObservation() async throws {
        // ── Child path ──────────────────────────────────────────────
        if let childDBPath = ProcessInfo.processInfo.environment["LATTICE_XPROC_CHILD_DB_PATH"] {
            let op = ProcessInfo.processInfo.environment["LATTICE_XPROC_CHILD_OP"] ?? "insert"
            guard op == "update" else { return }
            let fileURL = URL(fileURLWithPath: childDBPath)
            let lattice = try Lattice(
                for: [Person.self, Dog.self],
                configuration: .init(fileURL: fileURL)
            )
            if let person = lattice.objects(Person.self).where({ $0.name == "ExistingPerson" }).first {
                person.age = 99
            }
            return
        }

        // ── Parent path ─────────────────────────────────────────────
        let dbName = "xproc_update_\(UUID().uuidString).sqlite"
        let fileURL = FileManager.default.temporaryDirectory.appending(path: dbName)
        let dbPath = fileURL.path(percentEncoded: false)

        let lattice = try Lattice(
            for: [Person.self, Dog.self],
            configuration: .init(fileURL: fileURL)
        )
        defer { try? Lattice.delete(for: .init(fileURL: fileURL)) }

        let initial = Person()
        initial.name = "ExistingPerson"
        initial.age = 1
        try lattice.add(initial)

        guard let (execURL, childArgs) = childProcessConfig(filter: "crossProcessUpdateObservation") else {
            Issue.record("Could not determine child process configuration")
            return
        }

        var cancellable: AnyCancellable?
        let changes = AsyncStream<Void> { stream in
            cancellable = lattice.objects(Person.self).observe { change in
                if case .update = change {
                    stream.yield()
                    stream.finish()
                }
            }
            spawnChild(execURL: execURL, args: childArgs, dbPath: dbPath, op: "update")
        }

        var fired = false
        for await _ in changes { fired = true }
        cancellable?.cancel()

        #expect(fired, "Cross-process update observer did not fire")

        let results = lattice.objects(Person.self).where { $0.name == "ExistingPerson" }
        #expect(results.count == 1)
        if let found = results.first {
            #expect(found.age == 99)
        }
    }

    /// Tests that the passive (non-sync-agent) sync progress path fires when a
    /// cross-process write UPDATEs existing AuditLog rows (e.g., marking
    /// isSynchronized = 1) without creating new rows. This is the exact
    /// production path: the daemon ACKs synced entries, and the Visualizer's
    /// syncProgressStream should update.
    @Test(.timeLimit(.minutes(5)))
    func crossProcessAuditLogUpdateFiresObserver() async throws {
        // ── Child path ──────────────────────────────────────────────
        if let childDBPath = ProcessInfo.processInfo.environment["LATTICE_XPROC_CHILD_DB_PATH"] {
            let op = ProcessInfo.processInfo.environment["LATTICE_XPROC_CHILD_OP"] ?? "insert"
            guard op == "update_audit" else { return }
            var db: OpaquePointer?
            guard sqlite3_open(childDBPath, &db) == SQLITE_OK else { return }
            defer { sqlite3_close(db) }
            sqlite3_exec(db, "UPDATE AuditLog SET isSynchronized = 1 WHERE isSynchronized = 0", nil, nil, nil)
            _lattice_post_cross_process_notification(std.string(childDBPath))
            return
        }

        // ── Parent path ─────────────────────────────────────────────
        let dbName = "xproc_audit_update_\(UUID().uuidString).sqlite"
        let fileURL = FileManager.default.temporaryDirectory.appending(path: dbName)
        let dbPath = fileURL.path(percentEncoded: false)

        let lattice = try Lattice(
            for: [Person.self, Dog.self],
            configuration: .init(fileURL: fileURL)
        )
        defer { try? Lattice.delete(for: .init(fileURL: fileURL)) }

        let p = Person()
        p.name = "SeedPerson"
        p.age = 1
        try lattice.add(p)

        var syncFilter = Lattice.SyncFilter()
        syncFilter.include(Person.self)
        lattice.updateSyncFilter(syncFilter)

        guard let (execURL, childArgs) = childProcessConfig(filter: "crossProcessAuditLogUpdateFiresObserver") else {
            Issue.record("Could not determine child process configuration")
            return
        }

        // Use syncProgressStream (the production API). Stream creation
        // registers the xproc handler synchronously, so the child spawns
        // strictly after registration. `for await` is cancellation-safe —
        // .timeLimit can kill it if the handler never fires, instead of
        // hanging forever.
        let progress = lattice.syncProgressStream
        spawnChild(execURL: execURL, args: childArgs, dbPath: dbPath, op: "update_audit")

        var fired = false
        for await _ in progress {
            fired = true
            break
        }

        #expect(fired, "syncProgressStream did not fire for cross-process AuditLog UPDATE")
    }

    /// Tests that a cross-process List<T> append (link table INSERT) triggers
    /// an observer on the parent model. This is the CanaryBuilder scenario:
    /// MCP server appends a node to a container's children list, and the
    /// macOS builder app should see the change.
    @Test(.timeLimit(.minutes(5)))
    func crossProcessListAppend() async throws {
        // ── Child path ──────────────────────────────────────────────
        if let childDBPath = ProcessInfo.processInfo.environment["LATTICE_XPROC_CHILD_DB_PATH"] {
            let fileURL = URL(fileURLWithPath: childDBPath)
            let lattice = try Lattice(
                for: [Person.self, Dog.self, PersonWithDogs.self],
                configuration: .init(fileURL: fileURL)
            )
            if let owner = lattice.objects(PersonWithDogs.self).where({ $0.name == "DogOwner" }).first {
                let dog = Dog()
                dog.name = "Buddy"
                try lattice.add(dog)
                owner.dogs.append(dog)
            }
            return
        }

        // ── Parent path ─────────────────────────────────────────────
        let dbName = "xproc_list_\(UUID().uuidString).sqlite"
        let fileURL = FileManager.default.temporaryDirectory.appending(path: dbName)
        let dbPath = fileURL.path(percentEncoded: false)

        let lattice = try Lattice(
            for: [Person.self, Dog.self, PersonWithDogs.self],
            configuration: .init(fileURL: fileURL)
        )
        defer {
            try? Lattice.delete(for: .init(fileURL: fileURL))
        }

        let owner = PersonWithDogs()
        owner.name = "DogOwner"
        owner.age = 30
        try lattice.add(owner)

        guard let (execURL, childArgs) = childProcessConfig(filter: "crossProcessListAppend") else {
            Issue.record("Could not determine child process configuration")
            return
        }

        var cancellable: AnyCancellable?
        let changes = AsyncStream<Void> { stream in
            cancellable = lattice.objects(PersonWithDogs.self).observe { change in
                if case .update = change {
                    stream.yield()
                    stream.finish()
                }
            }
            spawnChild(execURL: execURL, args: childArgs, dbPath: dbPath, op: "append_to_list")
        }

        var fired = false
        for await _ in changes { fired = true }
        cancellable?.cancel()

        #expect(fired, "Cross-process List<T> append did not trigger parent observer — link table notification not resolved")

        let reloaded = lattice.objects(PersonWithDogs.self).where { $0.name == "DogOwner" }.first
        #expect(reloaded?.dogs.count == 1, "Expected 1 dog after cross-process append, got \(reloaded?.dogs.count ?? 0)")
    }

    /// Tests that a cross-process VirtualList<any Protocol> append (polymorphic
    /// link table INSERT) triggers an observer on the parent model.
    @Test(.timeLimit(.minutes(5)))
    func crossProcessVirtualListAppend() async throws {
        // ── Child path ──────────────────────────────────────────────
        if let childDBPath = ProcessInfo.processInfo.environment["LATTICE_XPROC_CHILD_DB_PATH"] {
            let fileURL = URL(fileURLWithPath: childDBPath)
            CrossProcessObservationDiagnostic.childPoint(.open_begin)
            let lattice = try Lattice(
                for: [TestDog.self, TestCat.self, TestPersonWithPets.self],
                configuration: .init(fileURL: fileURL)
            )
            CrossProcessObservationDiagnostic.childPoint(.open_returned)
            if let owner = lattice.objects(TestPersonWithPets.self).where({ $0.label == "PetOwner" }).first {
                CrossProcessObservationDiagnostic.childPoint(.owner_found)
                let dog = TestDog()
                dog.name = "Buddy"
                dog.breed = "Lab"
                CrossProcessObservationDiagnostic.childPoint(.write_begin)
                try lattice.add(dog)
                CrossProcessObservationDiagnostic.childPoint(.write_returned)
                CrossProcessObservationDiagnostic.childPoint(.list_append_begin)
                owner.pets.append(dog as any Animal)
                CrossProcessObservationDiagnostic.childPoint(.list_append_returned)
            }
            return
        }

        // ── Parent path ─────────────────────────────────────────────
        let dbName = "xproc_vlist_\(UUID().uuidString).sqlite"
        let fileURL = FileManager.default.temporaryDirectory.appending(path: dbName)
        let dbPath = fileURL.path(percentEncoded: false)

        let lattice = try Lattice(
            for: [TestDog.self, TestCat.self, TestPersonWithPets.self],
            configuration: .init(fileURL: fileURL)
        )
        defer { try? Lattice.delete(for: .init(fileURL: fileURL)) }

        let owner = TestPersonWithPets()
        owner.label = "PetOwner"
        try lattice.add(owner)

        guard let (execURL, childArgs) = childProcessConfig(filter: "crossProcessVirtualListAppend") else {
            Issue.record("Could not determine child process configuration")
            return
        }

        // Observe the TestPersonWithPets collection for updates.
        // When the child appends to the VirtualList, the polymorphic link
        // table INSERT should be resolved to a TestPersonWithPets UPDATE.
        let diagnosticsEnabled = ProcessInfo.processInfo.environment["LATTICE_OBSERVER_WORKER_DIAGNOSTICS"] == "1"
        let diagnostic = diagnosticsEnabled ? CrossProcessObservationDiagnostic(observer: "crossProcessVirtualListAppend") : nil
        if diagnosticsEnabled && diagnostic == nil {
            print("DIAGNOSTIC CrossProcessObservation: observer=crossProcessVirtualListAppend unavailable_fixture")
        }
        var child: Process?
        defer {
            diagnostic?.finish(failed: false, childStillRunning: child?.isRunning)
            // Preserve diagnostic files if the child might still write them.
            // This records lifecycle; it does not add a child wait or deadline.
            if child?.isRunning != true { diagnostic?.removeFixture() }
            withExtendedLifetime(child) {}
        }
        var cancellable: AnyCancellable?
        let changes = AsyncStream<Void> { stream in
            diagnostic?.record(.observer_registration_begin)
            let results = lattice.objects(TestPersonWithPets.self)
            cancellable = lattice._observeCollection(TestPersonWithPets.self, where: results.whereStatement,
                                                      diagnostic: diagnostic?.probe) { change in
                switch change {
                case .insert: diagnostic?.record(.insert_callback)
                case .update: diagnostic?.record(.update_callback)
                case .delete: diagnostic?.record(.delete_callback)
                }
                if case .update = change {
                    stream.yield()
                    stream.finish()
                }
            }
            diagnostic?.record(.observer_registration_returned)
            diagnostic?.record(.child_launch_begin)
            child = spawnChild(execURL: execURL, args: childArgs, dbPath: dbPath, op: "append_to_virtual_list", diagnostic: diagnostic)
            diagnostic?.record(.child_launch_returned)
        }

        var fired = false
        diagnostic?.record(.consumer_wait_begin)
        for await _ in changes {
            diagnostic?.record(.consumer_received)
            fired = true
        }
        diagnostic?.record(.consumer_wait_returned)
        diagnostic?.record(.cancel_call_begin)
        cancellable?.cancel()
        diagnostic?.record(.cancel_call_returned)
        diagnostic?.finish(failed: !fired, childStillRunning: child?.isRunning)

        #expect(fired, "Cross-process VirtualList append did not trigger parent observer — link table notification not resolved")

        let reloaded = lattice.objects(TestPersonWithPets.self).where { $0.label == "PetOwner" }.first
        #expect(reloaded?.pets.count == 1, "Expected 1 pet after cross-process append, got \(reloaded?.pets.count ?? 0)")
    }

    /// Regression: when a transaction in another process inserts N rows of
    /// the same model type, the parent's `changeStream` must fire once per
    /// AuditLog row — not once per batch.
    ///
    /// `handle_cross_process_notification` builds a `changes` vector
    /// containing one entry per new AuditLog row (plus the corresponding
    /// model-table change), then calls `notify_changes_batched`. Until this
    /// test's fix, that function deduplicated AuditLog observer fires per
    /// batch via `seen_audit_observers`, so a 3-row transaction produced
    /// ONE changeStream yield instead of three. Downstream consumers that
    /// relay AuditLog rows over the wire (e.g. ClaudeCodeIRC's
    /// RoomSyncServer) silently dropped rows 2..N — they stayed in the
    /// audit table with `isSynchronized = 0` forever.
    ///
    /// Surfaced by an Apr 30 2026 smoke test: a multi-question
    /// AskUserQuestion (3 rows in one shim transaction) only ever delivered
    /// Q1 to the peer.
    @Test(.timeLimit(.minutes(5)))
    func multiRowTransactionFiresAuditObserverOncePerRow() async throws {
        // ── Child path: insert 3 Person rows in a single transaction ──
        if ProcessInfo.processInfo.environment["LATTICE_XPROC_CHILD_DB_PATH"] != nil {
            let childDBPath = ProcessInfo.processInfo.environment["LATTICE_XPROC_CHILD_DB_PATH"]!
            let op = ProcessInfo.processInfo.environment["LATTICE_XPROC_CHILD_OP"] ?? ""
            guard op == "multi_row_transaction" else { return }

            let fileURL = URL(fileURLWithPath: childDBPath)
            let lattice = try Lattice(
                for: [Person.self, Dog.self],
                configuration: .init(fileURL: fileURL)
            )
            // Single transaction, three inserts. Without `transaction { }`
            // each `add` would commit separately — yielding 3 cross-process
            // notifications, each with 1 audit row, which sidesteps the
            // dedup bug (it only triggers for batches of >1 audit row).
            try lattice.transaction {
                for i in 0..<3 {
                    let p = Person()
                    p.name = "MultiRow_\(i)"
                    p.age = i
                    try lattice.add(p)
                }
            }
            return
        }

        // ── Parent path ─────────────────────────────────────────────
        let dbName = "xproc_multirow_\(UUID().uuidString).sqlite"
        let fileURL = FileManager.default.temporaryDirectory.appending(path: dbName)
        let dbPath = fileURL.path(percentEncoded: false)

        let lattice = try Lattice(
            for: [Person.self, Dog.self],
            configuration: .init(fileURL: fileURL)
        )
        defer { try? Lattice.delete(for: .init(fileURL: fileURL)) }

        guard let (execURL, childArgs) = childProcessConfig(
            filter: "multiRowTransactionFiresAuditObserverOncePerRow"
        ) else {
            Issue.record("Could not determine child process configuration")
            return
        }

        // Mirror `crossProcessObservation`: register the AuditLog observer
        // inside the AsyncStream builder, then spawn the child synchronously
        // within the same closure so the observer is live before the
        // cross-process notification fires.
        var cancellable: AnyCancellable?
        var personInserts = 0
        let stream = AsyncStream<Void> { yielder in
            cancellable = lattice.observe { (entries: [AuditLog]) in
                for entry in entries
                    where entry.tableName == "Person" && entry.operation == .insert {
                    personInserts += 1
                    yielder.yield()
                }
                if personInserts >= 3 {
                    yielder.finish()
                }
            }
            spawnChild(execURL: execURL, args: childArgs, dbPath: dbPath, op: "multi_row_transaction")
        }

        for await _ in stream {
            if personInserts >= 3 { break }
        }
        cancellable?.cancel()

        #expect(
            personInserts == 3,
            "AuditLog observer should fire once per Person INSERT row in a 3-row transaction (got \(personInserts))"
        )

        // Sanity: the rows did land on disk — bug is in the observer
        // pipeline, not the write path.
        let landed0 = lattice.objects(Person.self).where { $0.name == "MultiRow_0" }
        let landed1 = lattice.objects(Person.self).where { $0.name == "MultiRow_1" }
        let landed2 = lattice.objects(Person.self).where { $0.name == "MultiRow_2" }
        #expect(landed0.count == 1 && landed1.count == 1 && landed2.count == 1,
                "All 3 rows should have been written to the shared DB file")
    }
}
