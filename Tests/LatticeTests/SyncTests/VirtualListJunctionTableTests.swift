import Foundation
import Testing
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite)
import CSQLite
#endif
@testable import Lattice

/// Helper to check if a table exists in a SQLite database file.
private func tableExists(_ tableName: String, in dbPath: String) -> Bool {
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return false }
    defer { sqlite3_close(db) }

    var stmt: OpaquePointer?
    let sql = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
    defer { sqlite3_finalize(stmt) }

    sqlite3_bind_text(stmt, 1, tableName, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
    return sqlite3_column_int(stmt, 0) > 0
}

/// Regression test for VirtualList junction table creation during sync.
///
/// Bug: Polymorphic VirtualList junction tables (e.g. `_Screen_rootNodes` for
/// `VirtualList<any ViewNode>`) are only created lazily on first local write.
/// When a relay server calls `receive()` before forwarding, events targeting
/// these tables cause `receive()` to throw, dropping the entire frame.
///
/// Discovered in CanaryBuilder: MCP server creates node subtrees, but the
/// SyncRelay and macOS app never see them because junction table events fail.
@Suite("VirtualList Junction Table Tests")
class VirtualListJunctionTableTests: BaseTest {

    // MARK: - Test 1: Junction table exists after init (no writes needed)

    /// Verify that polymorphic VirtualList junction tables are created during
    /// Lattice initialization, NOT lazily on first write.
    @Test func test_polymorphicJunctionTableExistsAfterInit() async throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 32)).sqlite")
        defer { try? Lattice.delete(for: .init(fileURL: path)) }

        // Create a Lattice — do NOT write any data.
        _ = try Lattice(TestDog.self, TestCat.self, TestPersonWithPets.self,
                        configuration: .init(fileURL: path))

        // Force WAL checkpoint so tables are visible to a separate connection
        var checkpointDb: OpaquePointer?
        sqlite3_open(path.path, &checkpointDb)
        sqlite3_wal_checkpoint_v2(checkpointDb, nil, SQLITE_CHECKPOINT_FULL, nil, nil)
        sqlite3_close(checkpointDb)

        let dbPath = path.path

        // The junction table for TestPersonWithPets.pets (VirtualList<any Animal>)
        // should exist immediately after init, before any writes.
        #expect(tableExists("_TestPersonWithPets_pets", in: dbPath),
                "Polymorphic VirtualList junction table must be created eagerly during init, not lazily on first write")

        // Sanity: model tables should also exist
        #expect(tableExists("TestPersonWithPets", in: dbPath))
        #expect(tableExists("TestDog", in: dbPath))
        #expect(tableExists("TestCat", in: dbPath))
    }

    // MARK: - Test 2: receive() handles VirtualList events on a fresh Lattice

    /// Core regression test: export events containing VirtualList append operations
    /// from Lattice A, then import them into Lattice B (which has never locally
    /// written to any VirtualList). This mimics the SyncRelay/macOS app scenario.
    @Test func test_receiveVirtualListEventsWithoutLocalWrite() async throws {
        Lattice.setLogFile(.temporaryDirectory.appending(path: "vtests-lattice.log"))
        Lattice.setLogLevel(.debug)
        // --- Lattice A: create objects and append to VirtualList ---
        let latticeA = try testLattice(TestDog.self, TestCat.self, TestPersonWithPets.self)

        let person = TestPersonWithPets()
        person.label = "Alice"
        let dog = TestDog()
        dog.name = "Rex"
        dog.breed = "Lab"
        let cat = TestCat()
        cat.name = "Whiskers"
        cat.indoor = true

        try latticeA.transaction {
            try latticeA.add(person)
            try latticeA.add(dog)
            try latticeA.add(cat)
            person.pets.append(dog as any Animal)
            person.pets.append(cat as any Animal)
        }

        #expect(person.pets.count == 2, "Sanity check: local VirtualList works")

        // Export all events from Lattice A
        let events = latticeA.eventsAfter(globalId: nil)
        #expect(!events.isEmpty, "Should have audit log events")

        // Verify events include junction table entries
        let junctionEvents = events.filter { $0.tableName.hasPrefix("_TestPersonWithPets") }
        for junctionEvent in junctionEvents {
            print(junctionEvent.changedFields)
            print(junctionEvent.changedFieldsNames)
        }
        #expect(!junctionEvents.isEmpty, "Should have junction table events for VirtualList append")

        // --- Lattice B: fresh instance, same schema, no local writes ---
        let latticeB = try testLattice(TestDog.self, TestCat.self, TestPersonWithPets.self)

        // Encode events as ServerSentEvent (the wire format)
        let data = try JSONEncoder().encode(ServerSentEvent.auditLog(Array(events)))

        // This is the critical call — receive() must NOT throw.
        // If the junction table doesn't exist in Lattice B, this will fail
        // with a "no such table" error, which is the bug.
        let receivedIds = try latticeB.receive(data)
        #expect(!receivedIds.isEmpty, "receive() should return processed event IDs")

        // Verify the objects arrived
        #expect(latticeB.objects(TestPersonWithPets.self).count == 1)
        #expect(latticeB.objects(TestDog.self).count == 1)
        #expect(latticeB.objects(TestCat.self).count == 1)

        // THE KEY ASSERTION: VirtualList membership must have synced
        let syncedPerson = latticeB.objects(TestPersonWithPets.self).first!
        #expect(syncedPerson.pets.count == 2,
                "VirtualList entries must arrive via receive() even though Lattice B never called .append() locally")
        #expect(syncedPerson.pets.contains(where: { $0.name == "Rex" }),
                "Dog should be in synced VirtualList")
        #expect(syncedPerson.pets.contains(where: { $0.name == "Whiskers" }),
                "Cat should be in synced VirtualList")
    }

    // MARK: - Test 3: Relay pattern (receive-before-forward) doesn't drop events

    /// Simulates the SyncRelay pattern where the relay calls receive() on its own
    /// Lattice before forwarding to other clients. If receive() throws for junction
    /// table events, the forward never happens and downstream clients lose data.
    @Test func test_relayReceiveBeforeForwardPattern() async throws {
        // --- Source Lattice: creates data ---
        let source = try testLattice(TestDog.self, TestCat.self, TestPersonWithPets.self)

        let person = TestPersonWithPets()
        person.label = "RelayTest"
        let dog = TestDog()
        dog.name = "Buddy"
        dog.breed = "Golden"

        try source.transaction {
            try source.add(person)
            try source.add(dog)
            person.pets.append(dog as any Animal)
        }

        let events = source.eventsAfter(globalId: nil)
        for event in events {
            print("[DIAG] table=\(event.tableName) op=\(event.operation) globalRowId=\(event.globalRowId?.uuidString ?? "nil") changedFields=\(event.changedFields.count) changedFieldsNames=\(event.changedFieldsNames?.count ?? -1)")
            for (k, v) in event.changedFields {
                print("[DIAG]   field: \(k) = \(v)")
            }
        }
        let data = try JSONEncoder().encode(ServerSentEvent.auditLog(Array(events)))

        // --- Relay Lattice: same schema, mimics SyncRelay ---
        let relay = try testLattice(TestDog.self, TestCat.self, TestPersonWithPets.self)

        // Mimic SyncRelay.handleBinaryFrame: receive FIRST, then forward
        var forwardedData: Data?
        do {
            _ = try relay.receive(data)
            // Only forward on success (this is the SyncRelay pattern)
            forwardedData = data
        } catch {
            // BUG: If this catch fires, no data is forwarded to downstream clients
            Issue.record("Relay receive() threw — downstream clients will lose data: \(error)")
        }

        #expect(forwardedData != nil, "Relay must successfully receive so it can forward")

        // --- Downstream Lattice: receives forwarded data ---
        let downstream = try testLattice(TestDog.self, TestCat.self, TestPersonWithPets.self)
        _ = try downstream.receive(forwardedData!)

        let syncedPerson = downstream.objects(TestPersonWithPets.self).first!
        #expect(syncedPerson.pets.count == 1,
                "VirtualList must survive the relay receive-before-forward pattern")
        #expect(syncedPerson.pets.first?.name == "Buddy")
    }
}
