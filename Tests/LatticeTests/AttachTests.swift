import Foundation
import Lattice
import Testing

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
        let query = local.attaching(lattice: synced)

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
        let query = local.attaching(lattice: synced)

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

        let query = local.attaching(lattice: synced)

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
        let query = local.attaching(lattice: synced)

        // INSERT into local with a vector field
        // This triggers: INSERT INTO main.VecItem + trigger INSERT INTO _VecItem_embedding_vec
        let item = VecItem(content: "local vec item", project: "test", embedding: [0.1, 0.2, 0.3, 0.4, 0.5])
        local.add(item)
        #expect(item.primaryKey != nil)
    }

    @Test func attach_vecInsert_syncedLattice() async throws {
        let local = try testLattice(VecItem.self)
        let synced = try testLattice(VecItem.self)

        let query = local.attaching(lattice: synced)

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

        let query = local.attaching(lattice: synced)

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

        let query = local.attaching(lattice: synced)

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

        let query = local.attaching(lattice: synced)

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

        let query = local.attaching(lattice: synced)

        // Fetch through query and update
        let fetched = query.objects(PlainItem.self).where { $0.project == "synced" }.first!
        fetched.content = "updated"

        // Verify update persists
        #expect(synced.objects(PlainItem.self).first?.content == "updated")
    }
}
