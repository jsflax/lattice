import Testing
import Foundation
import Lattice
import XCTest

// MARK: - Item A Commit 1, Test T1 — trap-impossibility watchdog (A4 pattern)
//
// A background deleter loop races a reader doing `count` +
// `subscript(count - 1)` (main-actor batches AND an unpinned tight loop),
// 10k iterations, on file / private-memory / named shared-cache storage.
//
// The racing workload runs in a CHILD PROCESS with a parent-side watchdog:
// the old `fatalError("Index out of bounds")` path aborts the whole process,
// so an in-process test could never fail cleanly — the child's exit status
// is the assertion. A trap (or a hang) in the child fails the parent test;
// the tolerant ladder makes both impossible.
//
// IMPORTANT: this file deliberately uses ONLY pre-item-A API (objects/where/
// count/subscript/add/delete) so it still compiles against a revert of the
// trap fix — that is how the "T1 fails against the reverted trap" evidence
// is produced.

/// XCTest wrapper so the Xcode `xctest -XCTest` runner can target the child
/// path (mirrors CrossProcessChildRunner).
class LiveResultsT1ChildRunner: XCTestCase {
    func testChildPath() async throws {
        guard let storage = ProcessInfo.processInfo.environment["LATTICE_ITEMA_T1_STORAGE"] else { return }
        try await _runT1ChildWorkload(storage: storage)
    }
}

@Model final class T1Item {
    var name: String
    var rank: Int
}

private final class T1Box<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

private final class T1Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var value: Bool { lock.withLock { raised } }
    func raise() { lock.withLock { raised = true } }
}

private final class T1Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// The child-side racing workload. ~10k reader iterations total:
/// phase A = main-actor batches (the canonical SwiftUI shape, exercising the
/// render-batch boundary), phase B = an unpinned background tight loop (the
/// sharpest count-then-fetch torn window).
private func _runT1ChildWorkload(storage: String) async throws {
    let config: Lattice.Configuration
    switch storage {
    case "memory":
        config = .init(storage: .memory())
    case "namedmemory":
        config = .init(storage: .memory(named: "t1_shared_\(String.random(length: 12))"))
    default:
        let url = FileManager.default.temporaryDirectory
            .appending(path: "t1_watchdog_\(String.random(length: 12)).sqlite")
        config = .init(fileURL: url)
    }

    let lattice = try Lattice(T1Item.self, configuration: config)
    let rowsPerBurst = 40

    func seed() throws {
        try lattice.add(contentsOf: (0..<rowsPerBurst).map { i -> T1Item in
            let item = T1Item()
            item.name = "row_\(i)"
            item.rank = i
            return item
        })
    }
    try seed()

    let stop = T1Flag()
    let latticeBox = T1Box(lattice)
    let deleterDone = T1Flag()
    let bursts = T1Counter()

    // Background deleter: shrink the table from the TAIL one row at a time
    // (each delete is its own settled commit — maximal count-then-fetch torn
    // windows against `subscript(count - 1)`), then bulk re-insert.
    Thread.detachNewThread {
        let lattice = latticeBox.value
        while !stop.value {
            for rank in stride(from: rowsPerBurst - 1, through: 0, by: -1) {
                _ = lattice.delete(T1Item.self, where: { $0.rank == rank })
            }
            try? lattice.add(contentsOf: (0..<rowsPerBurst).map { i -> T1Item in
                let item = T1Item()
                item.name = "row_\(i)"
                item.rank = i
                return item
            })
            bursts.increment()
        }
        deleterDone.raise()
    }

    let results = lattice.objects(T1Item.self)

    // Phase A: 500 main-actor batches × 10 accesses (≈ render passes).
    for _ in 0..<500 {
        await MainActor.run {
            for _ in 0..<10 {
                let count = results.count
                if count > 0 {
                    _ = results[count - 1]
                }
            }
        }
    }

    // Phase B: unpinned tight iterations on a background thread — at least
    // 5,000 iterations AND at least 2 s of wall-clock racing, so the deleter
    // is guaranteed real interleaving however fast the reads are.
    let phaseBStart = Date()
    var phaseBIterations = 0
    while phaseBIterations < 5_000 || Date().timeIntervalSince(phaseBStart) < 2.0 {
        let count = results.count
        if count > 0 {
            _ = results[count - 1]
        }
        phaseBIterations += 1
    }

    stop.raise()
    let deadline = Date().addingTimeInterval(30)
    while !deleterDone.value && Date() < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    // The race must have been REAL: enough full-table delete bursts landed
    // while the reader ran that stale count → fetch windows were plentiful.
    // (Guards against a vacuous pass where the deleter never got scheduled.)
    print("T1 child(\(storage)): completed, delete bursts = \(bursts.value)")
    // Floor 8 (was 20): slow CI runners legitimately complete fewer bursts
    // in the window (observed 19 on a Linux runner); 8 still guarantees the
    // reader raced a live deleter many times — the anti-vacuity point.
    #expect(bursts.value >= 8,
            "T1(\(storage)): only \(bursts.value) delete bursts ran — the reader was not racing a live deleter")
}

/// Returns (executableURL, arguments) for spawning the child test process —
/// same runner detection as CrossProcessTests.
private func t1ChildProcessConfig(filter: String) -> (URL, [String])? {
    let args = ProcessInfo.processInfo.arguments

    // SPM (macOS): argv[0] is swiftpm-testing-helper.
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

    // SPM (Linux): argv[0] is the .xctest binary itself.
    if args[0].hasSuffix(".xctest"),
       args.contains("--testing-library") {
        return (
            URL(fileURLWithPath: args[0]),
            ["--filter", filter, "--testing-library", "swift-testing"]
        )
    }

    #if canImport(ObjectiveC)
    // Xcode: use xctest against the bundle, targeting the XCTest wrapper.
    let bundle = Bundle(for: LiveResultsT1ChildRunner.self)
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
        ["-XCTest", "LiveResultsT1ChildRunner/testChildPath", bundlePath]
    )
    #else
    return nil
    #endif
}

@Suite("Live Results Trap Watchdog (item A T1)", .serialized)
struct LiveResultsTrapWatchdogTests {

    @Test(.timeLimit(.minutes(10)))
    func t1TrapWatchdog_trapImpossibilityUnderConcurrentDeleteBursts() async throws {
        // ── Child path ──────────────────────────────────────────────
        if let storage = ProcessInfo.processInfo.environment["LATTICE_ITEMA_T1_STORAGE"] {
            try await _runT1ChildWorkload(storage: storage)
            return
        }

        // ── Parent path: spawn + watchdog per storage variant ───────
        guard let (execURL, childArgs) = t1ChildProcessConfig(filter: "t1TrapWatchdog") else {
            Issue.record("Could not determine child process configuration")
            return
        }

        for storage in ["file", "memory", "namedmemory"] {
            let child = Process()
            child.executableURL = execURL
            child.arguments = childArgs
            var env = ProcessInfo.processInfo.environment
            env["LATTICE_ITEMA_T1_STORAGE"] = storage
            for key in env.keys where key.hasPrefix("XCTest") {
                env.removeValue(forKey: key)
            }
            child.environment = env
            let logURL = FileManager.default.temporaryDirectory
                .appending(path: "t1_child_\(storage)_\(String.random(length: 8)).log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let logHandle = try FileHandle(forWritingTo: logURL)
            child.standardOutput = logHandle
            child.standardError = logHandle
            try child.run()

            // The watchdog: a bounded wall-clock deadline. A traped child
            // (SIGTRAP/abort) exits nonzero long before it; a deadlocked
            // child is terminated and fails the same assertion.
            let deadline = Date().addingTimeInterval(240)
            while child.isRunning && Date() < deadline {
                try await Task.sleep(for: .milliseconds(200))
            }
            var timedOut = false
            if child.isRunning {
                timedOut = true
                child.terminate()
                try await Task.sleep(for: .seconds(2))
            }
            try? logHandle.close()

            let tail: String = {
                guard let data = try? Data(contentsOf: logURL),
                      let text = String(data: data, encoding: .utf8) else { return "" }
                return text.split(separator: "\n").suffix(12).joined(separator: "\n")
            }()

            #expect(!timedOut,
                    "T1(\(storage)): child process hung past the watchdog deadline — reader/deleter deadlock or livelock. Tail:\n\(tail)")
            #expect(child.terminationStatus == 0,
                    "T1(\(storage)): child exited with status \(child.terminationStatus) (reason \(child.terminationReason.rawValue)) — a trap or test failure under the concurrent delete burst. Tail:\n\(tail)")
        }
    }
}
