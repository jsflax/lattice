import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@Suite("ExternalWriteLock bounded release", .serialized, .timeLimit(.minutes(1)))
struct ExternalWriteLockTests {
    private func withFixture(acquisitionScript: String? = nil,
                             _ body: (ExternalWriteLock) async throws -> Void) async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-lock-\(UUID().uuidString).sqlite").path
        let lock = try ExternalWriteLock(path: path, acquisitionScript: acquisitionScript)
        func finish() async {
            let result = await lock.release()
            #expect(result.cleanupComplete && result.childReaped,
                    Comment(rawValue: "fixture cleanup: \(result.failures)"))
            // An unresolved child must retain both its owner and its backing file.
            if result.cleanupComplete {
                for suffix in ["", "-wal", "-shm", "-journal"] {
                    try? FileManager.default.removeItem(atPath: path + suffix)
                }
            }
        }
        do {
            try await body(lock)
            await finish()
        } catch {
            await finish()
            throw error
        }
    }

    @Test func normalReleaseRequiresCommitMarkerEOFAndNormalReap() async throws {
        try await withFixture { lock in
            let acquisitionDeadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
            let acquired = await lock.waitUntilHeld(deadlineNS: acquisitionDeadline)
            let resumed = DispatchTime.now().uptimeNanoseconds
            try #require(acquired,
                         Comment(rawValue: "acquisition deadlineNS=\(acquisitionDeadline) resumedNS=\(resumed) snapshotAfterWait=\(lock.timingSnapshot)"))
            // Decide using the recorded event even with an expired wait budget.
            #expect(await lock.waitUntilHeld(timeout: 0))
            let held = try #require(lock.timingSnapshot.heldObservedNS)
            #expect(await lock.waitUntilHeld(deadlineNS: held))
            #expect(!(await lock.waitUntilHeld(deadlineNS: held - 1)),
                    "readiness recorded after the cutoff must still fail")
            let result = await lock.release()
            #expect(result.success && result.cleanupComplete)
            #expect(result.timing.exitedNormally && result.timing.exitStatus == 0)
            #expect(result.timing.releaseObservedNS != nil && result.stdoutEOF && result.childReaped)
            #expect(result.releaseWritesCompleted == 1 && result.signals.isEmpty)
            #expect(await lock.release() == result, "a late caller receives the frozen result")
        }
    }

    @Test func concurrentReleaseCallersShareOneCommitAndResult() async throws {
        try await withFixture { lock in
            try #require(await lock.waitUntilHeld(timeout: 5))
            async let first = lock.release()
            async let second = lock.release()
            let (a, b) = await (first, second)
            #expect(a == b)
            #expect(a.success && a.cleanupComplete && a.releaseWritesCompleted == 1)
            #expect(a.signals.isEmpty)
        }
    }

    @Test func earlySQLiteFailureIsReapedWithoutInventingCommitSuccess() async throws {
        try await withFixture(acquisitionScript: ".bail on\nSELECT * FROM __external_lock_missing_table__;\n") { lock in
            let result = await lock.release()
            #expect(!result.success && result.cleanupComplete && result.childReaped)
            #expect(result.timing.exitedNormally && result.timing.exitStatus != 0)
            #expect(result.timing.releaseObservedNS == nil && result.stdoutEOF)
            #expect(!result.failures.isEmpty)
            #expect(await lock.release() == result)
        }
    }

    @Test func cancelledReleaseCallerStillJoinsOwnedCleanup() async throws {
        try await withFixture { lock in
            try #require(await lock.waitUntilHeld(timeout: 5))
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                let wasCancelled = Task.isCancelled
                return (wasCancelled, await lock.release())
            }
            let (wasCancelled, result) = await cancelled.value
            #expect(wasCancelled)
            #expect(result.success && result.cleanupComplete && result.childReaped)
            #expect(await lock.release() == result)
            #expect(result.releaseWritesCompleted == 1 && result.signals.isEmpty)
        }
    }

    @Test func heldSQLiteQueryRequiresOwnedTERMAndKeepsFailedResult() async throws {
        // COUNT cannot produce a result from this unbounded recursive stream.
        // SQLite confirms BEGIN first, then cannot consume the queued COMMIT.
        // Only this fixture's direct child runs the query; no shell/descendant.
        let heldThenBusy = ".bail on\nBEGIN IMMEDIATE;\nSELECT 'LOCKHELD';\n"
            + "WITH RECURSIVE endless(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM endless) SELECT count(*) FROM endless;\n"
        try await withFixture(acquisitionScript: heldThenBusy) { lock in
            try #require(await lock.waitUntilHeld(timeout: 5))
            async let first = lock.release()
            async let second = lock.release()
            let (a, b) = await (first, second)
            #expect(a == b)
            #expect(!a.success, "forced disposal must never count as successful COMMIT")
            #expect(a.signals.contains { $0.signal == SIGTERM && $0.error == nil },
                    "normal release must reach the owned TERM escalation")
            #expect(a.childReaped && a.rawWaitStatus != nil && a.stdoutEOF && a.cleanupComplete,
                    Comment(rawValue: "forced child cleanup: \(a.failures)"))
            #expect(a.timing.releaseObservedNS == nil, "the blocked child must not claim COMMIT completion")
            #expect(a.failures.contains("normal release deadline exceeded"))
            #expect(await lock.release() == a, "later callers must retain the same failed result")
        }
    }
}
