import Foundation
import Testing
import Lattice
import CLatticeTestSQLite

// A Swift-only model: this type has no C++ LATTICE_SCHEMA registration. Keep
// it separate from models used by the existing warmed vector/IPC fixtures.
@Model private final class ColdIPCVectorMemory {
    var content: String
    var topic: String
    var project: String
    var embedding: FloatVector

    init(content: String = "", topic: String = "cold-vector", project: String = "sdk-ipc",
         embedding: [Float] = []) {
        self.content = content
        self.topic = topic
        self.project = project
        self.embedding = FloatVector(embedding)
    }
}

@Suite("Cold IPC vector initialization", .serialized)
actor ColdIPCVectorInitializationTests {
    private enum FirstQuery { case rows, count }
    private enum FixtureError: Error {
        case sqlite(String, Int32)
        case invalidReadback
    }

    // Read only the new fixture files through a separate real SQLite handle.
    // No vec0 module, raw Lattice handle, sidecar writes or metadata priming.
    private final class Reader {
        private var database: OpaquePointer?

        init(_ url: URL) throws {
            var pointer: OpaquePointer?
            let result = sqlite3_open_v2(url.path, &pointer,
                                        SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
            guard result == SQLITE_OK, let pointer else {
                if let pointer { sqlite3_close(pointer) }
                throw FixtureError.sqlite("open readback", result)
            }
            database = pointer
            guard sqlite3_busy_timeout(pointer, 100) == SQLITE_OK else {
                sqlite3_close(pointer)
                database = nil
                throw FixtureError.invalidReadback
            }
        }

        deinit { if let database { sqlite3_close(database) } }

        func close() {
            guard let database else { return }
            let result = sqlite3_close(database)
            #expect(result == SQLITE_OK, "Readback handle must actually close")
            if result == SQLITE_OK { self.database = nil }
        }

        private func rows(_ sql: String, bindings: [String] = []) throws -> [[String?]] {
            guard let database else { throw FixtureError.invalidReadback }
            var pointer: OpaquePointer?
            let prepared = sqlite3_prepare_v2(database, sql, -1, &pointer, nil)
            guard prepared == SQLITE_OK, let statement = pointer else {
                if let pointer { sqlite3_finalize(pointer) }
                throw FixtureError.sqlite("prepare readback", prepared)
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (index, value) in bindings.enumerated() {
                let result = sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
                guard result == SQLITE_OK else { throw FixtureError.sqlite("bind readback", result) }
            }
            var result: [[String?]] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { return result }
                guard step == SQLITE_ROW else { throw FixtureError.sqlite("step readback", step) }
                guard result.count < 16 else { throw FixtureError.invalidReadback }
                result.append((0..<sqlite3_column_count(statement)).map { index in
                    sqlite3_column_text(statement, index).map { String(cString: $0) }
                })
            }
        }

        func matches(_ id: UUID, content: String, embedding: FloatVector) throws -> Bool {
            let values = try rows("""
                SELECT content, topic, project, hex(embedding)
                FROM main.ColdIPCVectorMemory WHERE globalId = ?1 COLLATE NOCASE
                """, bindings: [id.uuidString])
            let expectedHex = embedding.toData().map { String(format: "%02X", $0) }.joined()
            return values.count == 1 && values[0] == [content, "cold-vector", "sdk-ipc", expectedHex]
        }

        func acknowledged(_ id: UUID, channel: String) throws -> Bool {
            // One SELECT observes the row, audit history and exact IPC channel
            // in one snapshot. A global isSynchronized flag alone is not ACK.
            let values = try rows("""
                SELECT
                  (SELECT COUNT(*) FROM main.ColdIPCVectorMemory
                   WHERE globalId = ?1 COLLATE NOCASE),
                  EXISTS (SELECT 1 FROM main.AuditLog
                          WHERE tableName = 'ColdIPCVectorMemory' AND globalRowId = ?1 COLLATE NOCASE)
                    AND EXISTS (SELECT 1 FROM main._lattice_replication_slots WHERE sync_id = ?2)
                    AND NOT EXISTS (
                      SELECT 1 FROM main.AuditLog a
                      WHERE a.tableName = 'ColdIPCVectorMemory' AND a.globalRowId = ?1 COLLATE NOCASE
                        AND COALESCE((SELECT s.is_synchronized FROM main._lattice_sync_state s
                                     WHERE s.audit_entry_id = a.id AND s.sync_id = ?2),
                                     a.isSynchronized) != 1)
                """, bindings: [id.uuidString, "ipc:\(channel)"])
            guard values.count == 1, values[0].count == 2 else { throw FixtureError.invalidReadback }
            return values[0] == ["1", "1"]
        }

        func indexedIDs() throws -> Set<String> {
            let values = try rows("""
                SELECT id FROM main._ColdIPCVectorMemory_embedding_vec_rowids ORDER BY id LIMIT 17
                """)
            return try Set(values.map { row in
                guard row.count == 1, let id = row[0] else { throw FixtureError.invalidReadback }
                return id.lowercased()
            })
        }
    }

    private func waitUntil(_ ready: () throws -> Bool) async throws -> Bool {
        let end = ContinuousClock.now.advanced(by: .seconds(30))
        repeat {
            if try ready() { return true }
            try await Task.sleep(for: .milliseconds(25))
        } while ContinuousClock.now < end
        return try ready()
    }

    private func coldDelivery(firstQuery: FirstQuery) async throws {
        let directory = testTemporaryDirectory.appending(path: "civ-\(UUID().uuidString.prefix(8))")
        try #require(!FileManager.default.fileExists(atPath: directory.path), "The cold fixture directory must be fresh")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appending(path: "source.sqlite")
        let hubURL = directory.appending(path: "hub.sqlite")
        let socketPath = directory.appending(path: "ipc.sock").path
        try #require(socketPath.utf8.count < 104, "Use a short LATTICE_TEST_TMPDIR for the Darwin socket limit")
        let channel = "cold-vector-\(UUID().uuidString.prefix(8))"
        let target = Lattice.IPCSyncTarget(channel: channel, socketPath: socketPath)
        var sourceConfig = Lattice.Configuration(fileURL: sourceURL, busyTimeoutMs: 2_000)
        sourceConfig.ipcTargets = [target]
        sourceConfig.auditRetention = 0
        let source = try Lattice(ColdIPCVectorMemory.self, configuration: sourceConfig)
        defer { source.close() }
        var hubConfig = Lattice.Configuration(fileURL: hubURL, busyTimeoutMs: 2_000)
        hubConfig.ipcTargets = [target]
        hubConfig.auditRetention = 0
        let hub = try Lattice(ColdIPCVectorMemory.self, configuration: hubConfig)
        defer { hub.close() }
        let sourceReader = try Reader(sourceURL)
        defer { sourceReader.close() }
        let hubReader = try Reader(hubURL)
        defer { hubReader.close() }

        let vector = FloatVector([1, 0, 0, 0])
        let memory = ColdIPCVectorMemory(content: "cold real IPC vector", embedding: vector.elements)
        try source.add(memory)
        let id = try #require(memory.globalId)
        try #require(await waitUntil {
            try hubReader.matches(id, content: "cold real IPC vector", embedding: vector)
                && sourceReader.matches(id, content: "cold real IPC vector", embedding: vector)
        }, "Real IPC delivery must preserve the exact content and nonempty four-dimensional embedding")
        try #require(await waitUntil {
            try sourceReader.acknowledged(id, channel: channel)
                && hubReader.acknowledged(id, channel: channel)
        }, "The actual row must be acknowledged on both sides of its IPC channel")

        // No hub add, reopen, nearest/count query, reconcile or vacuum preceded
        // this operation. A failed result must not hide its error diagnostic.
        let nearest = hub.objects(ColdIPCVectorMemory.self)
            .nearest(to: vector, on: \.embedding, limit: 1, distance: .cosine)
        switch firstQuery {
        case .rows:
            let firstRows = nearest.snapshot()
            let firstError = hub.lastQueryError() // before any assertion or other query
            #expect(firstError == nil, "First cold combined nearest failed: \(firstError ?? "<none>")")
            #expect(firstRows.count == 1)
            #expect(firstRows.first?.object.globalId == id)
            #expect((firstRows.first?.distance ?? 999) < 0.001)
            let count = nearest.count
            let countError = hub.lastQueryError()
            #expect(countError == nil, "Count after first cold query failed: \(countError ?? "<none>")")
            #expect(count == 1)
        case .count:
            let firstCount = nearest.count
            let firstError = hub.lastQueryError() // before a full query can clear it
            #expect(firstError == nil, "First cold combined count failed: \(firstError ?? "<none>")")
            #expect(firstCount == 1)
            let rows = nearest.snapshot()
            let rowsError = hub.lastQueryError()
            #expect(rowsError == nil, "Rows after first cold count failed: \(rowsError ?? "<none>")")
            #expect(rows.count == 1)
            #expect(rows.first?.object.globalId == id)
            #expect((rows.first?.distance ?? 999) < 0.001)
        }

        // Once initialized, a later real IPC insert must be maintained by the
        // installed index path; no local hub insertion or maintenance assists it.
        let laterVector = FloatVector([0, 1, 0, 0])
        let later = ColdIPCVectorMemory(content: "later real IPC vector", embedding: laterVector.elements)
        try source.add(later)
        let laterID = try #require(later.globalId)
        try #require(await waitUntil {
            try hubReader.matches(laterID, content: "later real IPC vector", embedding: laterVector)
                && sourceReader.acknowledged(laterID, channel: channel)
                && hubReader.acknowledged(laterID, channel: channel)
        }, "Subsequent vector delivery and both exact channel ACKs must finish")
        let laterRows = hub.objects(ColdIPCVectorMemory.self)
            .nearest(to: laterVector, on: \.embedding, limit: 1, distance: .cosine).snapshot()
        let laterError = hub.lastQueryError()
        #expect(laterError == nil, "Subsequent IPC vector query failed: \(laterError ?? "<none>")")
        #expect(laterRows.count == 1)
        #expect(laterRows.first?.object.globalId == laterID)
        #expect((laterRows.first?.distance ?? 999) < 0.001)
        #expect(try hubReader.indexedIDs() == Set([id.uuidString.lowercased(), laterID.uuidString.lowercased()]))
    }

    @Test(.timeLimit(.minutes(2)))
    func firstCombinedNearestFindsColdAcknowledgedIPCVector() async throws {
        try await coldDelivery(firstQuery: .rows)
    }

    @Test(.timeLimit(.minutes(2)))
    func firstCombinedCountFindsColdAcknowledgedIPCVector() async throws {
        try await coldDelivery(firstQuery: .count)
    }
}
