import Testing
import Foundation
import Lattice
import XCTest
#if canImport(SQLite3)
import SQLite3
#endif

/// XCTest wrapper so `xctest -XCTest` can target the child path.
/// (`xctest -XCTest` only filters XCTest tests, not Swift Testing @Test.)
class CrossProcessChildRunner: XCTestCase {
    func testChildPath() throws {
        guard let childDBPath = ProcessInfo.processInfo.environment["LATTICE_XPROC_CHILD_DB_PATH"] else { return }
        let fileURL = URL(fileURLWithPath: childDBPath)
        let op = ProcessInfo.processInfo.environment["LATTICE_XPROC_CHILD_OP"] ?? "insert"

        switch op {
        case "update", "insert":
            let lattice = try Lattice(
                for: [Person.self, Dog.self],
                configuration: .init(fileURL: fileURL)
            )
            if op == "update" {
                if let person = lattice.objects(Person.self).where({ $0.name == "ExistingPerson" }).first {
                    person.age = 99
                }
            } else {
                let p = Person()
                p.name = "FromOtherProcess"
                p.age = 42
                lattice.add(p)
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
                lattice.add(dog)
                owner.dogs.append(dog)
            }
        case "append_to_virtual_list":
            let lattice = try Lattice(
                for: [TestDog.self, TestCat.self, TestPersonWithPets.self],
                configuration: .init(fileURL: fileURL)
            )
            if let owner = lattice.objects(TestPersonWithPets.self).where({ $0.label == "PetOwner" }).first {
                let dog = TestDog()
                dog.name = "Buddy"
                dog.breed = "Lab"
                lattice.add(dog)
                owner.pets.append(dog as any Animal)
            }
        default:
            let lattice = try Lattice(
                for: [Person.self, Dog.self],
                configuration: .init(fileURL: fileURL)
            )
            let p = Person()
            p.name = "FromOtherProcess"
            p.age = 42
            lattice.add(p)
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
private func spawnChild(execURL: URL, args: [String], dbPath: String, op: String) {
    let child = Process()
    child.executableURL = execURL
    var env = ProcessInfo.processInfo.environment
    env["LATTICE_XPROC_CHILD_DB_PATH"] = dbPath
    env["LATTICE_XPROC_CHILD_OP"] = op
    for key in env.keys where key.hasPrefix("XCTest") {
        env.removeValue(forKey: key)
    }
    child.environment = env
    child.arguments = args
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    child.terminationHandler = nil
    try! child.run()
}

@Suite("Cross-Process Observation Tests")
struct CrossProcessTests {

    /// Tests that `withObservationTracking` (what @Bindable uses) detects
    /// cross-process property changes on a hydrated model instance.
    @Test(.timeLimit(.minutes(1)))
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
        lattice.add(seed)

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

    @Test(.timeLimit(.minutes(1)))
    func crossProcessObservation() async throws {
        // ── Child path ──────────────────────────────────────────────
        if let childDBPath = ProcessInfo.processInfo.environment["LATTICE_XPROC_CHILD_DB_PATH"] {
            let fileURL = URL(fileURLWithPath: childDBPath)
            let lattice = try Lattice(
                for: [Person.self, Dog.self],
                configuration: .init(fileURL: fileURL)
            )

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
                lattice.add(p)
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
        lattice.add(initial)

        guard let (execURL, childArgs) = childProcessConfig() else {
            Issue.record("Could not determine child process configuration")
            return
        }

        var cancellable: AnyCancellable?
        let changes = AsyncStream<Void> { stream in
            cancellable = lattice.objects(Person.self).observe { change in
                if case .insert = change {
                    stream.yield()
                    stream.finish()
                }
            }
            spawnChild(execURL: execURL, args: childArgs, dbPath: dbPath, op: "insert")
        }

        var fired = false
        for await _ in changes { fired = true }
        cancellable?.cancel()

        #expect(fired, "Cross-process observer did not fire")

        let results = lattice.objects(Person.self).where { $0.name == "FromOtherProcess" }
        #expect(results.count == 1)
        if let found = results.first {
            #expect(found.age == 42)
        }
    }

    @Test(.timeLimit(.minutes(1)))
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
            lattice.add(p)
        }

        // Wait a bit to ensure no spurious duplicate notifications arrive
        try await Task.sleep(for: .milliseconds(200))

        cancellable?.cancel()
        #expect(insertCount == 1,
                "Expected 1 insert notification, got \(insertCount) — self-notification not suppressed")
    }

    @Test(.timeLimit(.minutes(1)))
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
        lattice.add(seed)

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

    @Test(.timeLimit(.minutes(1)))
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
        lattice.add(initial)

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

    /// Tests that the passive sync progress observer fires when a cross-process
    /// write UPDATEs existing AuditLog rows (e.g., marking isSynchronized = 1)
    /// without creating new rows. This is the exact production path: the daemon
    /// ACKs synced entries, and the Visualizer's onSyncProgress should update.
    @Test(.timeLimit(.minutes(1)))
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
        lattice.add(p)

        var syncFilter = Lattice.SyncFilter()
        syncFilter.include(Person.self)
        lattice.updateSyncFilter(syncFilter)

        guard let (execURL, childArgs) = childProcessConfig(filter: "crossProcessAuditLogUpdateFiresObserver") else {
            Issue.record("Could not determine child process configuration")
            return
        }

        // Use onSyncProgress (the production API) via AsyncStream.
        // `for await` is cancellation-safe — .timeLimit can kill it if the
        // observer never fires, instead of hanging forever.
        let progress = AsyncStream<Void> { stream in
            lattice.onSyncProgress { _ in
                stream.yield()
                stream.finish()
            }
            spawnChild(execURL: execURL, args: childArgs, dbPath: dbPath, op: "update_audit")
        }

        var fired = false
        for await _ in progress { fired = true }

        #expect(fired, "onSyncProgress did not fire for cross-process AuditLog UPDATE")
    }

    /// Tests that a cross-process List<T> append (link table INSERT) triggers
    /// an observer on the parent model. This is the CanaryBuilder scenario:
    /// MCP server appends a node to a container's children list, and the
    /// macOS builder app should see the change.
    @Test(.timeLimit(.minutes(1)))
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
                lattice.add(dog)
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
        lattice.add(owner)

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
    @Test(.timeLimit(.minutes(1)))
    func crossProcessVirtualListAppend() async throws {
        // ── Child path ──────────────────────────────────────────────
        if let childDBPath = ProcessInfo.processInfo.environment["LATTICE_XPROC_CHILD_DB_PATH"] {
            let fileURL = URL(fileURLWithPath: childDBPath)
            let lattice = try Lattice(
                for: [TestDog.self, TestCat.self, TestPersonWithPets.self],
                configuration: .init(fileURL: fileURL)
            )
            if let owner = lattice.objects(TestPersonWithPets.self).where({ $0.label == "PetOwner" }).first {
                let dog = TestDog()
                dog.name = "Buddy"
                dog.breed = "Lab"
                lattice.add(dog)
                owner.pets.append(dog as any Animal)
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
        lattice.add(owner)

        guard let (execURL, childArgs) = childProcessConfig(filter: "crossProcessVirtualListAppend") else {
            Issue.record("Could not determine child process configuration")
            return
        }

        // Observe the TestPersonWithPets collection for updates.
        // When the child appends to the VirtualList, the polymorphic link
        // table INSERT should be resolved to a TestPersonWithPets UPDATE.
        var cancellable: AnyCancellable?
        let changes = AsyncStream<Void> { stream in
            cancellable = lattice.objects(TestPersonWithPets.self).observe { change in
                if case .update = change {
                    stream.yield()
                    stream.finish()
                }
            }
            spawnChild(execURL: execURL, args: childArgs, dbPath: dbPath, op: "append_to_virtual_list")
        }

        var fired = false
        for await _ in changes { fired = true }
        cancellable?.cancel()

        #expect(fired, "Cross-process VirtualList append did not trigger parent observer — link table notification not resolved")

        let reloaded = lattice.objects(TestPersonWithPets.self).where { $0.label == "PetOwner" }.first
        #expect(reloaded?.pets.count == 1, "Expected 1 pet after cross-process append, got \(reloaded?.pets.count ?? 0)")
    }
}
