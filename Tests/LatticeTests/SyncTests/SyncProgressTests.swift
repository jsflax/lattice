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
    let app: Application
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

    private let sockets = SocketStore(label: "SyncProgress")

    deinit {
        app.shutdown()
        try? Lattice.delete(for: localLattice1Configuration)
        try? Lattice.delete(for: localLattice2Configuration)
        try? Lattice.delete(for: syncedLatticeConfiguration)
    }

    private func launchServer() async throws {
        let syncedLatticeConfiguration = self.syncedLatticeConfiguration
        app.webSocket("test", maxFrameSize: WebSocketMaxFrameSize(integerLiteral: 500 * 1024 * 1024)) { req, ws in
            print("[SERVER:SyncProgress] New WebSocket connection accepted, total=\(self.sockets.count + 1)")
            self.sockets.append(ws)
            ws.onBinary { ws, bb in
                let data = Data(buffer: bb)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let kind = json["kind"] as? String else {
                    print("[SERVER:SyncProgress] Failed to parse incoming message")
                    return
                }

                if kind == "auditLog" {
                    if let auditLogs = json["auditLog"] as? [[String: Any]] {
                        let globalIds = auditLogs.compactMap { $0["globalId"] as? String }
                            .compactMap(UUID.init(uuidString:))
                        print("[SERVER:SyncProgress] Received \(auditLogs.count) audit entries, sending ACK for \(globalIds.count) ids")
                        ws.send(try! JSONEncoder().encode(ServerSentEvent.ack(globalIds)))
                    }
                    let others = self.sockets.others(excluding: ws)
                    print("[SERVER:SyncProgress] Relaying to \(others.count) other sockets")
                    for socket in others {
                        socket.send(bb)
                    }
                }
                Task.detached {
                    let lattice = try Lattice(configuration: syncedLatticeConfiguration)
                    _ = try? lattice.receive(data)
                }
            }

            let lattice = try! Lattice(configuration: syncedLatticeConfiguration)
            let events = lattice.eventsAfter(globalId: try? req.query.get(UUID?.self, at: "last-event-id"))
            let count = events.count
            print("[SERVER:SyncProgress] Sending \(count) initial events to new connection")
            for i in stride(from: 0, to: count, by: 1000) {
                let page = events[i..<min(count, i + 1000)]
                let encoded = try! JSONEncoder().encode(ServerSentEvent.auditLog(Array(page)))
                ws.send(ByteBuffer(data: encoded))
            }
        }
    }

    init() async throws {
        lattice_set_log_level(lattice.log_level.debug)
        var env = try Environment.detect()
        env.arguments = ["vapor"]
        self.app = try await Application.make(env)
        self.localLattice1Configuration = .init(fileURL: lattice1URL)
        self.localLattice2Configuration = .init(fileURL: lattice2URL)
        self.syncedLatticeConfiguration = .init(fileURL: syncLatticeURL)

        app.http.server.configuration.port = 0

        syncedLattice = try Lattice(for: [SimpleSyncObject.self],
                                    configuration: syncedLatticeConfiguration)

        try await launchServer()
        try await app.startup()

        guard let localAddress = app.http.server.shared.localAddress,
              let assignedPort = localAddress.port else {
            throw SyncTests.SyncTestError.noPort
        }
        self.port = assignedPort

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

    @Test(.timeLimit(.minutes(1)))
    func test_SyncProgress_UploadTracking() async throws {
        let lattice = localLattice1!
        let config = localLattice1Configuration

        // Start listening for progress where totalUpload > 0.
        // Synchronize: ensure the stream handler is registered BEFORE
        // adding objects, otherwise fire_progress() can fire before the
        // handler exists and the event is lost.
        var progressTask: Task<Lattice.SyncProgress, any Error>?
        await withCheckedContinuation { continuation in
            progressTask = Task.detached {
                let l = try Lattice(SimpleSyncObject.self, configuration: config)
                let stream = l.syncProgressStream
                continuation.resume()
                for await progress in stream {
                    if progress.totalUpload > 0 {
                        return progress
                    }
                }
                return Lattice.SyncProgress(pendingUpload: 0, totalUpload: 0, acked: 0, received: 0)
            }
        }

        // Add objects to trigger upload
        for i in 0..<5 {
            lattice.add(SimpleSyncObject(value: i, floatValue: Float(i)))
        }

        let progress = try await progressTask!.value
        #expect(progress.totalUpload > 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func test_SyncProgress_AckTracking() async throws {
        let lattice = localLattice1!

        // Use the sync progress callback to detect ACK directly,
        // avoiding the race between WAL hook and acked counter.
        let acked: Lattice.SyncProgress = await withCheckedContinuation { continuation in
            let once = AtomicOnce()
            lattice.onSyncProgress { progress in
                if progress.acked > 0 {
                    guard once.tryFire() else { return }
                    continuation.resume(returning: progress)
                }
            }
            lattice.add(SimpleSyncObject(value: 99, floatValue: 99.0))
        }

        #expect(acked.acked > 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func test_SyncProgress_DownloadTracking() async throws {
        let lattice = localLattice1!
        let lattice2 = localLattice2!

        // Wait for both WebSocket connections to be established before inserting.
        // Without this, lattice1 can upload before lattice2 connects, and the
        // server relays to 0 other sockets — lattice2 never receives the entry.
        await sockets.waitForCount(2)

        print("[DownloadTracking] START lattice1=\(lattice1URL.lastPathComponent) lattice2=\(lattice2URL.lastPathComponent) sockets=\(sockets.count)")

        // Wait for lattice2's own sync progress to show received increased.
        // Register the callback BEFORE triggering the sync so we don't miss
        // the event, and avoid creating a temporary Lattice on the same config
        // which can steal lattice2's sync connection.
        let received: Lattice.SyncProgress = await withCheckedContinuation { continuation in
            let once = AtomicOnce()
            lattice2.onSyncProgress { progress in
                print("[DownloadTracking] onSyncProgress fired: received=\(progress.received)")
                if progress.received > 0 {
                    guard once.tryFire() else { return }
                    print("[DownloadTracking] RESUMING continuation")
                    continuation.resume(returning: progress)
                }
            }
            print("[DownloadTracking] Handler registered, adding value 77 to lattice1")
            // Callback registered; trigger the sync.
            lattice.add(SimpleSyncObject(value: 77, floatValue: 77.0))
            print("[DownloadTracking] Value 77 added to lattice1")
        }

        #expect(received.received > 0)
        #expect(lattice2.objects(SimpleSyncObject.self).contains(where: { $0.value == 77 }))
    }

    @Test(.timeLimit(.minutes(1)))
    func test_SyncProgress_Callback() async throws {
        let lattice = localLattice1!
        let config = localLattice1Configuration

        // Use syncProgressStream (backed by onSyncProgress callback)
        // and wait for totalUpload > 0.
        // Must synchronize: ensure the stream handler is registered BEFORE
        // adding objects, otherwise fire_progress() can fire before the
        // handler exists and the event is lost.
        var callbackFired: Task<Lattice.SyncProgress, any Error>?
        await withCheckedContinuation { continuation in
            callbackFired = Task.detached {
                let l = try Lattice(SimpleSyncObject.self, configuration: config)
                let stream = l.syncProgressStream
                continuation.resume()
                for await progress in stream {
                    if progress.totalUpload > 0 {
                        return progress
                    }
                }
                return Lattice.SyncProgress(pendingUpload: 0, totalUpload: 0, acked: 0, received: 0)
            }
        }

        lattice.add(SimpleSyncObject(value: 1, floatValue: 1.0))
        lattice.add(SimpleSyncObject(value: 2, floatValue: 2.0))

        let progress = try await callbackFired!.value
        #expect(progress.totalUpload > 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func test_SyncProgress_OwnedDB_BackgroundThread() async throws {
        let lattice = localLattice1!
        let config = localLattice1Configuration

        // The progress callback fires on the synchronizer's std_thread_scheduler
        // thread, which must NOT be the main thread.
        // Use a two-stage continuation: signal when l's callback is registered,
        // then wait for the callback to actually fire.
        var isBackgroundTask: Task<Bool, any Error>?
        await withCheckedContinuation { (readyContinuation: CheckedContinuation<Void, Never>) in
            isBackgroundTask = Task.detached {
                let l = try Lattice(SimpleSyncObject.self, configuration: config)
                return await withCheckedContinuation { resultContinuation in
                    let once = AtomicOnce()
                    l.onSyncProgress { _ in
                        guard once.tryFire() else { return }
                        resultContinuation.resume(returning: !Thread.isMainThread)
                    }
                    // l is created and callback is registered — safe to trigger sync
                    readyContinuation.resume()
                }
            }
        }

        lattice.add(SimpleSyncObject(value: 42, floatValue: 42.0))

        let result = try await isBackgroundTask!.value
        #expect(result == true, "Progress callback should fire on a background thread")
    }

    @Test(.timeLimit(.minutes(1)))
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

    @Test(.timeLimit(.minutes(1)))
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

