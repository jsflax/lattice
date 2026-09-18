import Foundation
import Testing
@testable import Lattice

@Suite("Delete cache lock ordering")
final class DeleteCacheLockTests {
    @Test(.timeLimit(.minutes(1)))
    func unrelatedCachedLookupProgressesWhileCloseWaits() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "delete-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let selectedConfig = Lattice.Configuration(fileURL: directory.appending(path: "selected.sqlite"))
        let otherConfig = Lattice.Configuration(fileURL: directory.appending(path: "other.sqlite"))
        let selected = try Lattice(isolation: nil, for: [Person.self], configuration: selectedConfig)
        let other = try Lattice(isolation: nil, for: [Person.self], configuration: otherConfig)
        defer { selected.close(); other.close() }

        // Capture only the Sendable backend, not an actor-bound Lattice.
        let otherBackend = other.backend
        let beginLookup = DispatchSemaphore(value: 0)
        let lookupFinished = DispatchSemaphore(value: 0)
        let workerExited = DispatchSemaphore(value: 0)
        let lookedUpIdentity = UnfairLock<Int64?>(initialState: nil)
        let worker = Thread {
            defer { workerExited.signal() }
            guard beginLookup.wait(timeout: .now() + 10) == .success,
                  let ref = otherBackend.asCxxLatticeRef else { return }
            let resolved = Lattice(isolation: nil, ref: ref)
            lookedUpIdentity.withLockUnchecked { $0 = resolved?.backend.identityHash }
            lookupFinished.signal()
        }
        worker.start()

        var lookupCompletedBeforeCloseReturned = false
        try Lattice._delete(for: selectedConfig) { backend in
            // This is the blocking native-close interval. The lookup must
            // finish before we allow close to return; no scheduling sleep.
            beginLookup.signal()
            lookupCompletedBeforeCloseReturned =
                lookupFinished.wait(timeout: .now() + 3) == .success
            backend.close()
        }
        // Under the old ordering, the bounded wait above fails, then returning
        // from close releases cacheLock so the worker can finish cleanly.
        #expect(workerExited.wait(timeout: .now() + 3) == .success)
        #expect(lookupCompletedBeforeCloseReturned,
                "unrelated cached lookup was blocked by another path's close")
        let actualIdentity = lookedUpIdentity.withLockUnchecked { $0 }
        #expect(actualIdentity == other.backend.identityHash)
        #expect(!FileManager.default.fileExists(atPath: selectedConfig.fileURL.path))
        #expect(FileManager.default.fileExists(atPath: otherConfig.fileURL.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func allMatchingBackendsCloseBeforeUnlinkAndOtherPathRemainsCached() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "delete-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = Lattice.Configuration(fileURL: directory.appending(path: "selected.sqlite"))
        var secondConfig = config
        secondConfig.syncTuning = .init(chunkSize: 999)
        let otherConfig = Lattice.Configuration(fileURL: directory.appending(path: "other.sqlite"))
        let first = try Lattice(isolation: nil, for: [Person.self], configuration: config)
        let second = try Lattice(isolation: nil, for: [Person.self], configuration: secondConfig)
        let other = try Lattice(isolation: nil, for: [Person.self], configuration: otherConfig)
        defer { first.close(); second.close(); other.close() }
        let firstID = first.backend.identityHash
        let secondID = second.backend.identityHash
        try #require(firstID != secondID, "fixture must contain two native identities for one path")

        var closed: [Int64] = []
        var fileExistedAtEveryClose = true
        try Lattice._delete(for: config) { backend in
            fileExistedAtEveryClose = fileExistedAtEveryClose &&
                FileManager.default.fileExists(atPath: config.fileURL.path)
            closed.append(backend.identityHash)
            backend.close()
        }
        #expect(closed.count == 2)
        #expect(Set(closed) == Set([firstID, secondID]))
        #expect(fileExistedAtEveryClose, "all selected backends must close before the main file is unlinked")
        #expect(!FileManager.default.fileExists(atPath: config.fileURL.path))
        #expect(FileManager.default.fileExists(atPath: otherConfig.fileURL.path))

        let firstRef = try #require(first.backend.asCxxLatticeRef)
        let secondRef = try #require(second.backend.asCxxLatticeRef)
        let otherRef = try #require(other.backend.asCxxLatticeRef)
        let firstCachedIdentity = Lattice(isolation: nil, ref: firstRef)?.backend.identityHash
        let secondCachedIdentity = Lattice(isolation: nil, ref: secondRef)?.backend.identityHash
        #expect(firstCachedIdentity == nil)
        #expect(secondCachedIdentity == nil)
        let remaining = Lattice(isolation: nil, ref: otherRef)
        #expect(remaining?.backend.identityHash == other.backend.identityHash)
    }
}
