import Foundation
import Lattice
import Testing
#if canImport(SQLite3)
import SQLite3
#endif

@Model final class VecItem {
    var content: String
    var project: String
    var embedding: FloatVector

    init(content: String = "", project: String = "", embedding: [Float] = []) {
        self.content = content
        self.project = project
        self.embedding = FloatVector(embedding)
    }
}

@Model final class PlainItem {
    var content: String
    var project: String

    init(content: String = "", project: String = "") {
        self.content = content
        self.project = project
    }
}

@Suite("Attach Tests", .serialized)
class AttachTests: BaseTest {

    // MARK: - Basic ATTACH without vectors

    @Test func attach_plainInsert_localLattice() async throws {
        let local = try testLattice(PlainItem.self)
        let synced = try testLattice(PlainItem.self)

        // Attach synced to local — creates UNION ALL TEMP views
        let query = try local.attaching(lattice: synced)

        // INSERT into local should still work (goes to main.PlainItem via db.cpp fix)
        let item = PlainItem(content: "local item", project: "test")
        local.add(item)
        #expect(item.primaryKey != nil)

        // Visible through both local and query lattice
        #expect(local.objects(PlainItem.self).count == 1)
        #expect(query.objects(PlainItem.self).count == 1)
    }

    @Test func attach_plainInsert_syncedLattice() async throws {
        let local = try testLattice(PlainItem.self)
        let synced = try testLattice(PlainItem.self)

        // Attach synced to local
        let query = try local.attaching(lattice: synced)

        // INSERT into synced directly (separate connection, no ATTACH)
        let item = PlainItem(content: "synced item", project: "test")
        synced.add(item)
        #expect(item.primaryKey != nil)

        // Visible through synced and query lattice
        #expect(synced.objects(PlainItem.self).count == 1)
        #expect(query.objects(PlainItem.self).count == 1)
    }

    @Test func attach_plainInsert_bothDBs_unionAll() async throws {
        let local = try testLattice(PlainItem.self)
        let synced = try testLattice(PlainItem.self)

        let query = try local.attaching(lattice: synced)

        local.add(PlainItem(content: "local item", project: "local"))
        synced.add(PlainItem(content: "synced item", project: "synced"))

        // Query should see both via UNION ALL
        #expect(query.objects(PlainItem.self).count == 2)
        // Each DB sees only its own
        #expect(synced.objects(PlainItem.self).where { $0.project == "synced" }.count == 1)
        #expect(synced.objects(PlainItem.self).where { $0.project == "local" }.count == 0)
    }

    // MARK: - ATTACH with vector fields (the crash scenario)

    @Test func attach_vecInsert_localLattice() async throws {
        let local = try testLattice(VecItem.self)
        let synced = try testLattice(VecItem.self)

        // Attach synced to local — creates UNION ALL TEMP views
        // This may shadow the vec virtual table with a TEMP VIEW
        let query = try local.attaching(lattice: synced)

        // INSERT into local with a vector field
        // This triggers: INSERT INTO main.VecItem + trigger INSERT INTO _VecItem_embedding_vec
        let item = VecItem(content: "local vec item", project: "test", embedding: [0.1, 0.2, 0.3, 0.4, 0.5])
        local.add(item)
        #expect(item.primaryKey != nil)
    }

    @Test func attach_vecInsert_syncedLattice() async throws {
        let local = try testLattice(VecItem.self)
        let synced = try testLattice(VecItem.self)

        let query = try local.attaching(lattice: synced)

        // INSERT into synced directly (no ATTACH views, should work)
        let item = VecItem(content: "synced vec item", project: "test", embedding: [0.1, 0.2, 0.3, 0.4, 0.5])
        synced.add(item)
        #expect(item.primaryKey != nil)
    }

    @Test func attach_nearest_throughUnionAll() async throws {
        let local = try testLattice(VecItem.self)
        let synced = try testLattice(VecItem.self)

        // Pre-populate both DBs before attaching
        local.add(VecItem(content: "local doc", project: "local", embedding: [1.0, 0.0, 0.0, 0.0, 0.0]))
        synced.add(VecItem(content: "synced doc", project: "synced", embedding: [0.0, 1.0, 0.0, 0.0, 0.0]))

        let query = try local.attaching(lattice: synced)

        // Nearest query through the ATTACH'd view
        let results = query.objects(VecItem.self)
            .nearest(to: FloatVector([1.0, 0.0, 0.0, 0.0, 0.0]), on: \.embedding, limit: 5, distance: .cosine)
            .snapshot()

        // Should find at least the local doc
        #expect(results.count >= 1)
    }

    @Test func attach_insertThenNearest() async throws {
        let local = try testLattice(VecItem.self)
        let synced = try testLattice(VecItem.self)

        let query = try local.attaching(lattice: synced)

        // Insert into synced (safe, no TEMP views)
        synced.add(VecItem(content: "synced A", project: "synced", embedding: [1.0, 0.0, 0.0, 0.0, 0.0]))

        // Insert into local (potentially crashes due to vec TEMP VIEW)
        local.add(VecItem(content: "local A", project: "local", embedding: [0.0, 1.0, 0.0, 0.0, 0.0]))

        // Nearest on query lattice
        let results = query.objects(VecItem.self)
            .nearest(to: FloatVector([0.5, 0.5, 0.0, 0.0, 0.0]), on: \.embedding, limit: 5, distance: .cosine)
            .snapshot()

        #expect(results.count >= 1)
    }

    // MARK: - Delete through ATTACH'd view

    @Test func attach_deleteFromSynced_throughQueryLattice() async throws {
        let local = try testLattice(PlainItem.self)
        let synced = try testLattice(PlainItem.self)

        synced.add(PlainItem(content: "to delete", project: "synced"))

        let query = try local.attaching(lattice: synced)

        // Fetch through query (UNION ALL) and delete
        let item = query.objects(PlainItem.self).where { $0.project == "synced" }.first
        #expect(item != nil)
        query.delete(item!)

        #expect(synced.objects(PlainItem.self).count == 0)
        #expect(query.objects(PlainItem.self).count == 0)
    }

    // MARK: - Update through ATTACH'd view

    @Test func attach_updateInSynced_throughQueryLattice() async throws {
        let local = try testLattice(PlainItem.self)
        let synced = try testLattice(PlainItem.self)

        let item = PlainItem(content: "original", project: "synced")
        synced.add(item)

        let query = try local.attaching(lattice: synced)

        // Fetch through query and update
        let fetched = query.objects(PlainItem.self).where { $0.project == "synced" }.first!
        fetched.content = "updated"

        // Verify update persists
        #expect(synced.objects(PlainItem.self).first?.content == "updated")
    }
}

// MARK: - ATT-4: throwing attach/detach

extension AttachTests {
    /// Schema mismatch is now a catchable Swift error instead of a C++
    /// exception terminating the process.
    #if canImport(SQLite3)
    @Test func attach_schemaMismatch_throwsCatchable() async throws {
        var local = try testLattice(PlainItem.self)
        let syncedPath = "\(String.random(length: 32)).sqlite"
        let synced = try testLattice(path: syncedPath, PlainItem.self)
        synced.add(PlainItem(content: "x", project: "y"))

        // Diverge the attached DB's PlainItem schema out-of-band; the
        // pre-attach validation reads columns through synced's live handle,
        // which sees the ALTER immediately (same file).
        let fileURL = FileManager.default.temporaryDirectory.appending(path: syncedPath)
        var db: OpaquePointer?
        #expect(sqlite3_open(fileURL.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "ALTER TABLE PlainItem ADD COLUMN rogue TEXT", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        #expect(throws: LatticeError.self) {
            try local.attach(lattice: synced)
        }
        // The failed attach must leave local fully usable, main-only.
        local.add(PlainItem(content: "still works", project: "post-failure"))
        #expect(local.objects(PlainItem.self).count == 1)
    }
    #endif

    @Test func detach_restoresMainOnlyVisibility() async throws {
        var local = try testLattice(PlainItem.self)
        let synced = try testLattice(PlainItem.self)

        local.add(PlainItem(content: "local item", project: "local"))
        synced.add(PlainItem(content: "synced item", project: "synced"))

        try local.attach(lattice: synced)
        #expect(local.objects(PlainItem.self).count == 2)

        try local.detach(lattice: synced)
        let names = local.objects(PlainItem.self).snapshot().map(\.project)
        #expect(names == ["local"])
    }

    @Test func detach_ofUnattachedLatticeIsNoOp() async throws {
        var local = try testLattice(PlainItem.self)
        let never = try testLattice(PlainItem.self)
        local.add(PlainItem(content: "a", project: "p"))
        try local.detach(lattice: never)
        #expect(local.objects(PlainItem.self).count == 1)
    }

    @Test func attachTwice_isIdempotent() async throws {
        var local = try testLattice(PlainItem.self)
        let synced = try testLattice(PlainItem.self)
        synced.add(PlainItem(content: "s", project: "s"))

        try local.attach(lattice: synced)
        try local.attach(lattice: synced)
        #expect(local.objects(PlainItem.self).count == 1)

        try local.detach(lattice: synced)
        #expect(local.objects(PlainItem.self).count == 0)
    }

    @Test func multiAttach_partialDetach_keepsRemaining() async throws {
        var local = try testLattice(PlainItem.self)
        let a = try testLattice(PlainItem.self)
        let b = try testLattice(PlainItem.self)
        a.add(PlainItem(content: "a", project: "a"))
        b.add(PlainItem(content: "b", project: "b"))

        try local.attach(lattice: a)
        try local.attach(lattice: b)
        #expect(local.objects(PlainItem.self).count == 2)

        try local.detach(lattice: a)
        let projects = local.objects(PlainItem.self).snapshot().map(\.project)
        #expect(projects == ["b"])
    }
}

// MARK: - P0 review fixes: bookkeeping idempotence, path-keyed detach, mixed storage

protocol AttachVenue: VirtualModel {
    var name: String { get }
}

@Model final class AttachRestaurant: AttachVenue {
    var name: String
    init(name: String = "") { self.name = name }
}

@Model final class AttachMuseum: AttachVenue {
    var name: String
    var exhibits: Int
    init(name: String = "", exhibits: Int = 0) { self.name = name; self.exhibits = exhibits }
}

extension AttachTests {
    /// Repeat attach must not double-book the schema; one detach must fully
    /// remove the attachment from polymorphic membership (review finding:
    /// duplicate attachedSchemas entry survived a single detach).
    @Test func attachTwice_detachOnce_restoresBaseSchemaMembership() async throws {
        var l1 = try testLattice(AttachRestaurant.self)
        let l2 = try testLattice(AttachMuseum.self)
        l1.add(AttachRestaurant(name: "R"))
        l2.add(AttachMuseum(name: "M"))

        try l1.attach(lattice: l2)
        try l1.attach(lattice: l2)  // idempotent — no duplicate schema arms
        #expect(l1.objects(AttachVenue.self).count == 2)

        try l1.detach(lattice: l2)
        #expect(l1.objects(AttachVenue.self).count == 1, "Museum must leave polymorphic membership after ONE detach")
        // Second detach is a clean no-op.
        try l1.detach(lattice: l2)
        #expect(l1.objects(AttachVenue.self).count == 1)
    }

    /// Detach is path-keyed like the C++ side: a REOPENED handle over the
    /// attached database detaches it fully, schema included.
    @Test func detachViaReopenedHandle_removesSchema() async throws {
        var l1 = try testLattice(AttachRestaurant.self)
        let path = "reopen_detach_\(String.random(length: 16)).sqlite"
        let l2 = try testLattice(path: path, AttachMuseum.self)
        l2.add(AttachMuseum(name: "M"))

        try l1.attach(lattice: l2)
        #expect(l1.objects(AttachVenue.self).count == 1)

        // Fresh handle over the same file (different backend identity).
        let l2Again = try Lattice(AttachMuseum.self, configuration: .init(
            fileURL: FileManager.default.temporaryDirectory.appending(path: path)))
        try l1.detach(lattice: l2Again)
        #expect(l1.objects(AttachVenue.self).count == 0, "path-keyed detach must remove the schema too")
    }

    /// Mixed storage: a FILE-backed lattice attaching a NAMED-MEMORY lattice
    /// must see the memory rows (core now opens all connections URI-capable;
    /// previously this silently attached an empty literal file).
    @Test func fileLattice_attachesMemoryLattice() async throws {
        var main = try testLattice(PlainItem.self)
        let mem = try Lattice(PlainItem.self, configuration: .init(storage: .memory(named: "attach_mem_\(String.random(length: 8))")))
        mem.add(PlainItem(content: "from-memory", project: "m"))
        main.add(PlainItem(content: "from-file", project: "f"))

        try main.attach(lattice: mem)
        #expect(main.objects(PlainItem.self).count == 2)
        try main.detach(lattice: mem)
        #expect(main.objects(PlainItem.self).count == 1)
    }

    /// Memory names with URI-hostile characters are percent-encoded — they
    /// stay in-memory (no on-disk file) and distinct names stay distinct.
    @Test func memoryName_withHostileCharacters_staysInMemoryAndDistinct() async throws {
        let a = try Lattice(PlainItem.self, configuration: .init(storage: .memory(named: "cache?v=2")))
        let b = try Lattice(PlainItem.self, configuration: .init(storage: .memory(named: "cache?v=3")))
        a.add(PlainItem(content: "a", project: "a"))
        #expect(a.objects(PlainItem.self).count == 1)
        #expect(b.objects(PlainItem.self).count == 0, "distinct hostile names must not collide")
        #expect(!FileManager.default.fileExists(atPath: "cache"), "no on-disk file may appear")
    }
}
