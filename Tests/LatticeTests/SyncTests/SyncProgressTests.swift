import Foundation
#if canImport(Combine)
import Combine
#endif
import NIOConcurrencyHelpers
import NIOCore
import Testing
import Lattice
import Observation
import Vapor


// MARK: - Sync Progress Tests

@Suite("Sync Progress Tests")
actor SyncProgressTests {
    let server: TestSyncServer
    let syncLatticeURL = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    let lattice1URL = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    let lattice2URL = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    var port: Int = 0
    var localLattice1: Lattice!
    var localLattice2: Lattice!
    var syncedLattice: Lattice!
    var syncedLatticeConfiguration: Lattice.Configuration
    var localLattice1Configuration: Lattice.Configuration
    var localLattice2Configuration: Lattice.Configuration

    deinit {
        server.shutdown()
        try? Lattice.delete(for: localLattice1Configuration)
        try? Lattice.delete(for: localLattice2Configuration)
        try? Lattice.delete(for: syncedLatticeConfiguration)
    }

    init() async throws {
        lattice_set_log_level(lattice.log_level.debug)
        self.localLattice1Configuration = .init(fileURL: lattice1URL)
        self.localLattice2Configuration = .init(fileURL: lattice2URL)
        self.syncedLatticeConfiguration = .init(fileURL: syncLatticeURL)

        // D1b: shared TestSyncServer (one server-lifetime lattice, ordered persistence).
        self.server = try await TestSyncServer(models: [SimpleSyncObject.self],
                                               configuration: syncedLatticeConfiguration,
                                               label: "SyncProgress")
        syncedLattice = server.lattice
        self.port = server.port

        localLattice1Configuration = Lattice.Configuration(
            fileURL: lattice1URL,
            authorizationToken: "hi",
            wssEndpoint: URL(string: "http://localhost:\(port)/test"))
        localLattice2Configuration = Lattice.Configuration(
            fileURL: lattice2URL,
            authorizationToken: "hi2",
            wssEndpoint: URL(string: "http://localhost:\(port)/test"))

        localLattice1 = try Lattice(SimpleSyncObject.self,
                                    configuration: localLattice1Configuration)
        localLattice2 = try Lattice(SimpleSyncObject.self,
                                    configuration: localLattice2Configuration)
    }

    @Test(.disabled(if: isMacOSCI, "Darwin CI hang class — await never resumes and .timeLimit cannot interrupt on macOS; runs locally and on Linux CI. Owner: 1.0 item D1b/D2"), .timeLimit(.minutes(5)))
    func test_SyncProgress_UploadTracking() async throws {
        let lattice = localLattice1!

        // Listen for progress with totalUpload > 0. The stream MUST be
        // created on the suite's own handle — the actual sync agent. A fresh
        // Lattice open inside a detached task is NOT a ref-cache hit (the
        // cache key includes the isolation context), so it lands on a second,
        // non-sync-agent instance whose xproc branch never fires for
        // same-process writes — the await wedges forever. Stream creation
        // registers the handler synchronously, so creating it before add()
        // means the event can't be lost; the Sendable stream then crosses
        // into the detached iterator.
        let stream = lattice.syncProgressStream
        let progressTask = Task.detached {
            for await progress in stream {
                if progress.totalUpload > 0 {
                    return progress
                }
            }
            return Lattice.SyncProgress(pendingUpload: 0, totalUpload: 0, acked: 0, received: 0)
        }

        // Add objects to trigger upload
        for i in 0..<5 {
            try lattice.add(SimpleSyncObject(value: i, floatValue: Float(i)))
        }

        let progress = await progressTask.value
        #expect(progress.totalUpload > 0)
    }

    @Test(.timeLimit(.minutes(5)))
    func test_SyncProgress_AckTracking() async throws {
        let lattice = localLattice1!

        // Use syncProgressStream (the canonical progress API) to detect ACK
        // directly, avoiding the race between WAL hook and acked counter.
        // Stream on the suite's own sync-agent handle (see UploadTracking for
        // why a fresh detached-task open wedges), created BEFORE the add so
        // the event can't be lost.
        let stream = lattice.syncProgressStream
        let ackedTask = Task.detached {
            for await progress in stream {
                if progress.acked > 0 {
                    return progress
                }
            }
            return Lattice.SyncProgress(pendingUpload: 0, totalUpload: 0, acked: 0, received: 0)
        }

        try lattice.add(SimpleSyncObject(value: 99, floatValue: 99.0))

        let acked = await ackedTask.value
        #expect(acked.acked > 0)
    }

    @Test(.timeLimit(.minutes(5)))
    func test_SyncProgress_DownloadTracking() async throws {
        let lattice = localLattice1!
        let lattice2 = localLattice2!

        // Wait for both WebSocket connections to be established before inserting.
        // Without this, lattice1 can upload before lattice2 connects, and the
        // server relays to 0 other sockets — lattice2 never receives the entry.
        await server.sockets.waitForCount(2)

        print("[DownloadTracking] START lattice1=\(lattice1URL.lastPathComponent) lattice2=\(lattice2URL.lastPathComponent) sockets=\(server.sockets.count)")

        // Wait for lattice2's own sync progress to show received increased.
        // Stream on lattice2's OWN handle (its process-side sync agent for its
        // file; a fresh detached-task open is a cache MISS across isolation
        // contexts and wedges — see UploadTracking), created BEFORE the
        // triggering add so the event can't be lost.
        let stream = lattice2.syncProgressStream
        let receivedTask = Task.detached {
            for await progress in stream {
                print("[DownloadTracking] syncProgressStream fired: received=\(progress.received)")
                if progress.received > 0 {
                    return progress
                }
            }
            return Lattice.SyncProgress(pendingUpload: 0, totalUpload: 0, acked: 0, received: 0)
        }

        print("[DownloadTracking] Stream registered, adding value 77 to lattice1")
        try lattice.add(SimpleSyncObject(value: 77, floatValue: 77.0))
        print("[DownloadTracking] Value 77 added to lattice1")

        let received = await receivedTask.value
        #expect(received.received > 0)
        #expect(lattice2.objects(SimpleSyncObject.self).contains(where: { $0.value == 77 }))
    }

    @Test(.timeLimit(.minutes(5)))
    func test_SyncProgress_Callback() async throws {
        let lattice = localLattice1!

        // Use syncProgressStream (the canonical progress API) and wait for
        // totalUpload > 0. Stream on the suite's own sync-agent handle,
        // created BEFORE the adds (see UploadTracking for both constraints).
        let stream = lattice.syncProgressStream
        let callbackFired = Task.detached {
            for await progress in stream {
                if progress.totalUpload > 0 {
                    return progress
                }
            }
            return Lattice.SyncProgress(pendingUpload: 0, totalUpload: 0, acked: 0, received: 0)
        }

        try lattice.add(SimpleSyncObject(value: 1, floatValue: 1.0))
        try lattice.add(SimpleSyncObject(value: 2, floatValue: 2.0))

        let progress = await callbackFired.value
        #expect(progress.totalUpload > 0)
    }

    @Test(.timeLimit(.minutes(5)))
    func test_SyncError_FiresOnConnectionFailure() async throws {
        // Connect to a port that isn't listening — should trigger onSyncError
        let badURL = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 30)).sqlite")
        defer { try? FileManager.default.removeItem(at: badURL) }

        let badConfig = Lattice.Configuration(
            fileURL: badURL,
            authorizationToken: "bad",
            wssEndpoint: URL(string: "ws://localhost:1/nonexistent"))

        // The instance must outlive the await: an error callback can't be
        // delivered to a torn-down Lattice, and the old `let lattice` inside
        // the closure only worked because the strong cache leaked the instance.
        let lattice = try! Lattice(SimpleSyncObject.self, configuration: badConfig)
        let errorMessage: String = await withCheckedContinuation { continuation in
            let once = AtomicOnce()
            lattice.onSyncError { error in
                guard once.tryFire() else { return }
                continuation.resume(returning: error)
            }
        }
        withExtendedLifetime(lattice) {}

        #expect(!errorMessage.isEmpty, "Error message should not be empty")
    }

    @Test(.timeLimit(.minutes(5)))
    func test_SyncStateChange_Connected() async throws {
        let lattice = localLattice1!

        // Should fire with connected=true once WebSocket opens
        let connected: Bool = await withCheckedContinuation { continuation in
            let once = AtomicOnce()
            lattice.onSyncStateChange { isConnected in
                if isConnected {
                    guard once.tryFire() else { return }
                    continuation.resume(returning: isConnected)
                }
            }
        }

        #expect(connected == true)
    }
}

