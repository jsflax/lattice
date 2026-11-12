#if canImport(Darwin) && canImport(SQLite3)
import Foundation
import NIOCore
import SQLite3
import Testing
import Vapor
@testable import Lattice

/// A quiet server: it sends the same committed history once per connection,
/// honors the resume cursor, and never writes or periodically republishes data.
private final class RecoveryDownloadServer: @unchecked Sendable {
    private struct Connection: Sendable {
        let number: Int
        let socket: WebSocket
        let cursor: String?
    }

    struct Snapshot {
        let cursors: [String?]
        let closedConnections: Set<Int>
        let acknowledgedIDs: [String]
        let uploadedFrames: Int
        let protocolFailures: Int
    }

    private let lock = NSLock()
    private let history: Data
    private let eventIDs: [String]
    private var started = false
    private var connections: [Connection] = []
    private var closedConnections: Set<Int> = []
    private var acknowledgedIDs: [String] = []
    private var uploadedFrames = 0
    private var protocolFailures = 0

    init(history: Data, eventIDs: [UUID]) {
        self.history = history
        self.eventIDs = eventIDs.map { $0.uuidString.lowercased() }
    }

    func accept(_ socket: WebSocket, cursor: String?) {
        let (connection, shouldSend) = lock.withRecoveryLock {
            let connection = Connection(number: connections.count + 1, socket: socket,
                                        cursor: cursor?.lowercased())
            connections.append(connection)
            return (connection, started)
        }
        socket.onClose.whenComplete { [weak self] _ in
            guard let self else { return }
            self.lock.withRecoveryLock { _ = self.closedConnections.insert(connection.number) }
        }
        socket.onBinary { [weak self] _, buffer in
            self?.received(Data(buffer: buffer))
        }
        if shouldSend { sendHistory(to: connection) }
    }

    /// Gate only the initial delivery so the client error callback and SQLite
    /// fault are installed before the first byte arrives. Redials need no poke.
    func beginInitialDelivery() {
        let pending = lock.withRecoveryLock {
            started = true
            return connections
        }
        for connection in pending { sendHistory(to: connection) }
    }

    var snapshot: Snapshot {
        lock.withRecoveryLock {
            Snapshot(cursors: connections.map(\.cursor), closedConnections: closedConnections,
                     acknowledgedIDs: acknowledgedIDs, uploadedFrames: uploadedFrames,
                     protocolFailures: protocolFailures)
        }
    }

    private func sendHistory(to connection: Connection) {
        do {
            var envelope = try #require(JSONSerialization.jsonObject(with: history) as? [String: Any])
            let entries = try #require(envelope["auditLog"] as? [[String: Any]])
            let start: Int
            if let cursor = connection.cursor {
                // A falsely advanced cursor really omits those entries. Sending
                // the entire frame on every dial would hide that recovery bug.
                start = try #require(eventIDs.firstIndex(of: cursor)) + 1
            } else {
                start = 0
            }
            envelope["auditLog"] = Array(entries.dropFirst(start))
            let frame = try JSONSerialization.data(withJSONObject: envelope)
            connection.socket.eventLoop.execute {
                connection.socket.send(ByteBuffer(data: frame))
            }
        } catch {
            lock.withRecoveryLock { protocolFailures += 1 }
        }
    }

    private func received(_ data: Data) {
        guard let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            lock.withRecoveryLock { protocolFailures += 1 }
            return
        }
        lock.withRecoveryLock {
            if envelope["kind"] as? String == "auditLog" { uploadedFrames += 1 }
            if let ids = envelope["ack"] as? [String] {
                acknowledgedIDs.append(contentsOf: ids.map { $0.lowercased() })
            }
        }
    }
}

private final class RecoveryApplyFault: @unchecked Sendable {
    private let lock = NSLock()
    private let databaseURL: URL
    private var errors: [String] = []
    private var removalCode: Int32?
    private var auditCountAtFailure: Int?

    init(databaseURL: URL) { self.databaseURL = databaseURL }

    func install() throws {
        let code = Self.execute(databaseURL, sql: """
            CREATE TRIGGER recovery_test_abort_apply
            BEFORE UPDATE OF disabled ON _SyncControl
            WHEN NEW.disabled = 1
            BEGIN SELECT RAISE(ABORT, 'test download apply failure'); END
            """)
        #expect(code == SQLITE_OK)
        guard code == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }

    func receivedSyncError(_ message: String) {
        let shouldRemove = lock.withRecoveryLock {
            errors.append(message)
            return message.hasPrefix("Download incomplete:") && removalCode == nil
        }
        guard shouldRemove else { return }
        var count: Int?
        let code = Self.execute(databaseURL, sql: "DROP TRIGGER recovery_test_abort_apply") { sqlite in
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(sqlite, "SELECT COUNT(*) FROM AuditLog", -1, &statement, nil) == SQLITE_OK,
               let statement {
                defer { sqlite3_finalize(statement) }
                if sqlite3_step(statement) == SQLITE_ROW { count = Int(sqlite3_column_int64(statement, 0)) }
            }
        }
        lock.withRecoveryLock {
            removalCode = code
            auditCountAtFailure = count
        }
    }

    var snapshot: (errors: [String], removalCode: Int32?, auditCount: Int?) {
        lock.withRecoveryLock { (errors, removalCode, auditCountAtFailure) }
    }

    private static func execute(_ url: URL, sql: String,
                                before: (OpaquePointer) -> Void = { _ in }) -> Int32 {
        var pointer: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard opened == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close(pointer) }
            return opened
        }
        defer { sqlite3_close(pointer) }
        sqlite3_busy_timeout(pointer, 2_000)
        before(pointer)
        return sqlite3_exec(pointer, sql, nil, nil, nil)
    }
}

private extension NSLock {
    func withRecoveryLock<Value>(_ body: () -> Value) -> Value {
        lock(); defer { unlock() }
        return body()
    }
}

/// A partial download apply must halt the failed connection and redial from
/// the committed cursor. This server sends only auditLog frames; informational
/// control-frame handling has separate coverage in the core test suite.
@Suite("Darwin download apply recovery", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct ReceiveRecoveryTests {
    @Test func failedFirstChunkRedialsQuietServerWithoutSkippingHistory() async throws {
        let directory = testTemporaryDirectory
            .appendingPathComponent("receive-recovery-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try Lattice(SimpleSyncObject.self,
                                 configuration: .init(fileURL: directory.appendingPathComponent("source.sqlite")))
        defer { source.close() }
        try source.withTransaction {
            for value in 0..<120 {
                try source.add(SimpleSyncObject(value: value, floatValue: Float(value) / 2))
            }
        }
        let expectedRows = Dictionary(uniqueKeysWithValues:
            source.objects(SimpleSyncObject.self).compactMap { row in row.globalId.map { ($0, row.value) } })
        let auditEntries = Array(source.eventsAfter(globalId: nil))
        let expectedAuditIDs = auditEntries.compactMap(\.globalId)
        #expect(expectedRows.count == 120)
        #expect(expectedAuditIDs.count == 120)
        let server = RecoveryDownloadServer(history: try JSONEncoder().encode(ServerSentEvent.auditLog(auditEntries)),
                                            eventIDs: expectedAuditIDs)

        var environment = try Environment.detect()
        environment.arguments = ["vapor"]
        let app = try await Application.make(environment)
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0
        app.http.server.configuration.shutdownTimeout = .milliseconds(500)
        app.webSocket("download", maxFrameSize: .init(integerLiteral: 1 << 20)) { request, socket in
            server.accept(socket, cursor: try? request.query.get(String.self, at: "last-event-id"))
        }
        do {
            try await app.startup()
            let port = try #require(app.http.server.shared.localAddress?.port)
            let clientURL = directory.appendingPathComponent("client.sqlite")
            // Pre-open the schema; this replica never originates a model write.
            let schema = try Lattice(SimpleSyncObject.self, configuration: .init(fileURL: clientURL))
            schema.close()
            var configuration = Lattice.Configuration(
                // Core enables sync only when an endpoint and token are both
                // present. This token belongs solely to the synthetic server.
                fileURL: clientURL, authorizationToken: "receive-recovery-fixture",
                wssEndpoint: URL(string: "ws://127.0.0.1:\(port)/download"),
                busyTimeoutMs: 100,
                syncTuning: .init(baseDelaySeconds: 0.05, maxDelaySeconds: 0.1, registersAsObserver: true))
            configuration.uploadsEnabled = false
            let client = try Lattice(SimpleSyncObject.self, configuration: configuration)
            defer { client.close() }
            let fault = RecoveryApplyFault(databaseURL: clientURL)
            client.onSyncError { fault.receivedSyncError($0) }
            try fault.install()
            server.beginInitialDelivery()

            // Parallel suite load can delay this actor past a polling wakeup.
            // The old 15-second deadline-first loop could miss completed recovery
            // when it resumed. Check readiness first and budget for loaded runs.
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(60))
            var recovered = false
            while true {
                let network = server.snapshot
                if client.objects(SimpleSyncObject.self).count == 120,
                   network.cursors.count >= 2, network.closedConnections.contains(1),
                   network.acknowledgedIDs.count == 120 {
                    recovered = true
                    break
                }
                if clock.now >= deadline { break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }

            let readiness = server.snapshot
            #expect(recovered, """
                A quiet download-only replica must recover without a new server write or manual reconnect.
                Connections: \(readiness.cursors.count); closed: \(readiness.closedConnections.sorted()); ACK count: \(readiness.acknowledgedIDs.count).
                """)
            // Let completions from the canceled Darwin task arrive. They must
            // not disconnect its healthy successor or initiate a third dial.
            if recovered { try await Task.sleep(nanoseconds: 300_000_000) }
            let failure = fault.snapshot
            #expect(failure.errors == ["Download incomplete: applied 0 of 120 entries; reconnecting from the committed checkpoint."])
            #expect(failure.removalCode == SQLITE_OK)
            #expect(failure.auditCount == 0, "Both failed attempts must roll back the first chunk")
            let network = server.snapshot
            #expect(network.cursors.count == 2)
            #expect(network.cursors.allSatisfy { $0 == nil }, "A failed first chunk must not advance the resume cursor")
            #expect(network.closedConnections == [1], "Darwin redial must close the superseded socket while retaining its successor")
            #expect(network.uploadedFrames == 0)
            #expect(network.protocolFailures == 0)
            #expect(network.acknowledgedIDs.count == expectedAuditIDs.count)
            #expect(Set(network.acknowledgedIDs) == Set(expectedAuditIDs.map { $0.uuidString.lowercased() }))
            #expect(client.isSyncConnected)
            let actualRows = Dictionary(uniqueKeysWithValues:
                client.objects(SimpleSyncObject.self).compactMap { row in row.globalId.map { ($0, row.value) } })
            #expect(actualRows == expectedRows)
            #expect(client.objects(SimpleSyncObject.self).allSatisfy { $0.floatValue == Float($0.value) / 2 })
            #expect(client.objects(AuditLog.self).count == expectedAuditIDs.count)
            #expect(Set(client.objects(AuditLog.self).compactMap(\.globalId)) == Set(expectedAuditIDs))
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
#endif
