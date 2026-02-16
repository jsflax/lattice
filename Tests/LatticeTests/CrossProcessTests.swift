#if os(macOS)
import Testing
import Foundation
import Lattice
import XCTest

/// Thread-unsafe sendable box for cross-thread communication in tests.
private class Box<T>: @unchecked Sendable {
    var value: T?
    init(_ value: T? = nil) { self.value = value }
}

/// XCTest wrapper so `xctest -XCTest` can target the child path.
/// (`xctest -XCTest` only filters XCTest tests, not Swift Testing @Test.)
class CrossProcessChildRunner: XCTestCase {
    func testChildPath() throws {
        guard let childDBPath = ProcessInfo.processInfo.environment["LATTICE_XPROC_CHILD_DB_PATH"] else { return }
        let fileURL = URL(fileURLWithPath: childDBPath)
        let lattice = try Lattice(
            for: [Person.self, Dog.self],
            configuration: .init(fileURL: fileURL)
        )

        let op = ProcessInfo.processInfo.environment["LATTICE_XPROC_CHILD_OP"] ?? "insert"
        switch op {
        case "update":
            // Find the seeded object and update it
            if let person = lattice.objects(Person.self).where({ $0.name == "ExistingPerson" }).first {
                person.age = 99
            }
        default:
            let p = Person()
            p.name = "FromOtherProcess"
            p.age = 42
            lattice.add(p)
        }
    }
}

/// Returns (executableURL, arguments) for spawning the child test process.
/// Handles both SPM (`swiftpm-testing-helper`) and Xcode (`xctest`) runners.
private func childProcessConfig(filter: String = "crossProcessObservation") -> (URL, [String])? {
    let args = ProcessInfo.processInfo.arguments

    // SPM: argv[0] is swiftpm-testing-helper, args include --test-bundle-path
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

    // Xcode: use xctest to run the .xctest bundle
    let bundle = Bundle(for: CrossProcessChildRunner.self)
    guard let bundlePath = bundle.bundlePath as String?,
          bundlePath.hasSuffix(".xctest") else { return nil }

    // Find xctest binary
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

        // Simulate what @Bindable does: track property access via Observation framework
        let observationFired = Box<Bool>(false)
        withObservationTracking {
            _ = person.age
        } onChange: {
            observationFired.value = true
        }

        // Spawn child to update the person
        guard let (execURL, childArgs) = childProcessConfig(filter: "crossProcessBindableObservation") else {
            Issue.record("Could not determine child process configuration")
            return
        }

        let child = Process()
        child.executableURL = execURL
        var env = ProcessInfo.processInfo.environment
        env["LATTICE_XPROC_CHILD_DB_PATH"] = dbPath
        env["LATTICE_XPROC_CHILD_OP"] = "update"
        for key in env.keys where key.hasPrefix("XCTest") {
            env.removeValue(forKey: key)
        }
        child.environment = env
        child.arguments = childArgs
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice

        try child.run()

        let deadline = Date().addingTimeInterval(10)
        while child.isRunning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        if child.isRunning {
            child.terminate()
            Issue.record("Child process timed out after 10s")
            return
        }

        #expect(child.terminationStatus == 0, "Child process failed with exit code \(child.terminationStatus)")

        for _ in 0..<40 {
            if observationFired.value == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(observationFired.value == true,
                "withObservationTracking did not fire — @Bindable would not update from cross-process change")
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

        // Seed an initial object
        let initial = Person()
        initial.name = "ExistingPerson"
        initial.age = 1
        lattice.add(initial)

        // Set up observer
        let observerFired = Box<Bool>(false)
        let cancellable = lattice.objects(Person.self).observe { change in
            if case .insert = change {
                observerFired.value = true
            }
        }
        defer { cancellable.cancel() }

        // Find testing infrastructure
        guard let (execURL, childArgs) = childProcessConfig() else {
            Issue.record("Could not determine child process configuration")
            return
        }

        // Spawn child process
        let child = Process()
        child.executableURL = execURL
        var env = ProcessInfo.processInfo.environment
        env["LATTICE_XPROC_CHILD_DB_PATH"] = dbPath
        // Strip Xcode test session vars so the child xctest doesn't try
        // to connect back to Xcode's test reporter and hang.
        for key in env.keys where key.hasPrefix("XCTest") {
            env.removeValue(forKey: key)
        }
        child.environment = env
        child.arguments = childArgs

        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice

        try child.run()

        // Wait with timeout (10s) to avoid hanging forever
        let deadline = Date().addingTimeInterval(10)
        while child.isRunning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        if child.isRunning {
            child.terminate()
            Issue.record("Child process timed out after 10s")
            return
        }

        #expect(child.terminationStatus == 0, "Child process failed with exit code \(child.terminationStatus)")

        // Poll for the notification to arrive
        for _ in 0..<40 {
            if observerFired.value == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(observerFired.value == true, "Cross-process observer did not fire")

        // Verify the data arrived
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
        var checkedContinuation: CheckedContinuation<Void, Never>?
        var cancellable: AnyCancellable?

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            checkedContinuation = continuation
            cancellable = lattice.objects(Person.self).observe { change in
                if case .insert = change {
                    insertCount += 1
                }
                checkedContinuation?.resume()
                checkedContinuation = nil
            }

            let p = Person()
            p.name = "LocalPerson"
            p.age = 10
            lattice.add(p)
        }

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

        // Seed and hydrate a live instance
        let seed = Person()
        seed.name = "ExistingPerson"
        seed.age = 1
        lattice.add(seed)

        // Query back to get a managed, hydrated instance
        let person = lattice.objects(Person.self).where { $0.name == "ExistingPerson" }.first!

        // Subscribe to objectWillChange on the live instance
        let objectWillChangeFired = Box<Bool>(false)
        let cancellable = person.objectWillChange.sink {
            objectWillChangeFired.value = true
        }
        defer { cancellable.cancel() }

        // Spawn child to update the person
        guard let (execURL, childArgs) = childProcessConfig(filter: "crossProcessObjectObservation") else {
            Issue.record("Could not determine child process configuration")
            return
        }

        let child = Process()
        child.executableURL = execURL
        var env = ProcessInfo.processInfo.environment
        env["LATTICE_XPROC_CHILD_DB_PATH"] = dbPath
        env["LATTICE_XPROC_CHILD_OP"] = "update"
        for key in env.keys where key.hasPrefix("XCTest") {
            env.removeValue(forKey: key)
        }
        child.environment = env
        child.arguments = childArgs
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice

        try child.run()

        let deadline = Date().addingTimeInterval(10)
        while child.isRunning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        if child.isRunning {
            child.terminate()
            Issue.record("Child process timed out after 10s")
            return
        }

        #expect(child.terminationStatus == 0, "Child process failed with exit code \(child.terminationStatus)")

        // Poll for objectWillChange to fire
        for _ in 0..<40 {
            if objectWillChangeFired.value == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(objectWillChangeFired.value == true,
                "objectWillChange did not fire on hydrated instance from cross-process update")

        // dynamic_object_ref reads through to DB, so value should reflect the update
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

        // Seed an object for the child to update
        let initial = Person()
        initial.name = "ExistingPerson"
        initial.age = 1
        lattice.add(initial)

        // Set up observer for updates
        let updateFired = Box<Bool>(false)
        let cancellable = lattice.objects(Person.self).observe { change in
            if case .update = change {
                updateFired.value = true
            }
        }
        defer { cancellable.cancel() }

        // Find testing infrastructure
        guard let (execURL, childArgs) = childProcessConfig(filter: "crossProcessUpdateObservation") else {
            Issue.record("Could not determine child process configuration")
            return
        }

        // Spawn child process
        let child = Process()
        child.executableURL = execURL
        var env = ProcessInfo.processInfo.environment
        env["LATTICE_XPROC_CHILD_DB_PATH"] = dbPath
        env["LATTICE_XPROC_CHILD_OP"] = "update"
        for key in env.keys where key.hasPrefix("XCTest") {
            env.removeValue(forKey: key)
        }
        child.environment = env
        child.arguments = childArgs

        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice

        try child.run()

        // Wait with timeout
        let deadline = Date().addingTimeInterval(10)
        while child.isRunning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        if child.isRunning {
            child.terminate()
            Issue.record("Child process timed out after 10s")
            return
        }

        #expect(child.terminationStatus == 0, "Child process failed with exit code \(child.terminationStatus)")

        // Poll for the notification to arrive
        for _ in 0..<40 {
            if updateFired.value == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(updateFired.value == true, "Cross-process update observer did not fire")

        // Verify the data was updated
        let results = lattice.objects(Person.self).where { $0.name == "ExistingPerson" }
        #expect(results.count == 1)
        if let found = results.first {
            #expect(found.age == 99)
        }
    }
}

#endif
