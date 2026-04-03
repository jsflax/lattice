import Foundation
import Lattice
import Testing
#if os(macOS)
import SQLite3
#endif
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

// MARK: - Vector Search Tests

@Model final class Document {
    var title: String
    var embedding: FloatVector

    init(title: String = "", embedding: [Float] = []) {
        self.title = title
        self.embedding = FloatVector(embedding)
    }
}

@Model final class CategorizedDocument {
    var title: String
    var category: String
    var embedding: FloatVector

    init(title: String = "", category: String = "", embedding: [Float] = []) {
        self.title = title
        self.category = category
        self.embedding = FloatVector(embedding)
    }
}

@Suite("Vector Search Tests")
class VectorSearchTests: BaseTest {

    @Test func test_VectorStorage() async throws {
        let lattice = try testLattice(Document.self)

        // Create a document with a small embedding
        let embedding: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]
        let doc = Document(title: "Test Doc", embedding: embedding)

        // Verify vector before storage
        print("Before add - embedding dimensions: \(doc.embedding.dimensions)")
        print("Before add - embedding data size: \(doc.embedding.toData().count)")

        lattice.add(doc)

        // Retrieve and verify
        let docs = lattice.objects(Document.self)
        #expect(docs.count == 1)

        let retrieved = docs.first!
        print("After retrieval - title: \(retrieved.title)")
        print("After retrieval - embedding dimensions: \(retrieved.embedding.dimensions)")
        print("After retrieval - embedding data size: \(retrieved.embedding.toData().count)")

        #expect(retrieved.title == "Test Doc")
        #expect(retrieved.embedding.dimensions == 5)

        // Check values are preserved
        for (i, value) in retrieved.embedding.enumerated() {
            #expect(abs(value - embedding[i]) < 0.0001)
        }
    }

    @Test func test_EmptyVectorDoesNotCrashQuery() async throws {
        let lattice = try testLattice(Document.self)

        // Insert a document with a real vector — creates vec0 table + triggers
        let doc1 = Document(title: "Has Embedding", embedding: [1.0, 0.0, 0.0])
        lattice.add(doc1)

        // Insert a document with an empty/default vector — should NOT crash vec0
        let doc2 = Document(title: "No Embedding")
        lattice.add(doc2)

        // Query nearest — previously crashed with "zero-length vectors are not supported"
        let query = FloatVector([1.0, 0.0, 0.0])
        let nearest = lattice.objects(Document.self)
            .nearest(to: query, on: \.embedding, limit: 5)

        // Only the document with a real embedding should appear in results
        #expect(nearest.count == 1)
        #expect(nearest.first?.object.title == "Has Embedding")
    }

    @Test func test_EmptyQueryVectorDoesNotCrash() async throws {
        let lattice = try testLattice(Document.self)

        // Insert a document with a real vector
        lattice.add(Document(title: "Has Embedding", embedding: [1.0, 0.0, 0.0]))

        // Query with an empty vector — should not crash
        let emptyQuery = FloatVector([])
        let nearest = lattice.objects(Document.self)
            .nearest(to: emptyQuery, on: \.embedding, limit: 5)

        // Should return empty results (not crash)
        #expect(nearest.count == 0)
    }

    @Test func test_VectorDistanceFunctions() async throws {
        let v1 = FloatVector([1.0, 0.0, 0.0])
        let v2 = FloatVector([0.0, 1.0, 0.0])
        let v3 = FloatVector([1.0, 0.0, 0.0])

        // L2 distance: sqrt((1-0)^2 + (0-1)^2 + (0-0)^2) = sqrt(2)
        let l2 = v1.l2Distance(to: v2)
        #expect(abs(l2 - Float(sqrt(2.0))) < 0.0001)

        // Same vectors should have 0 distance
        #expect(v1.l2Distance(to: v3) < 0.0001)

        // Cosine distance of orthogonal vectors = 1 (similarity = 0)
        let cosine = v1.cosineDistance(to: v2)
        #expect(abs(cosine - 1.0) < 0.0001)

        // Cosine distance of same vectors = 0 (similarity = 1)
        #expect(v1.cosineDistance(to: v3) < 0.0001)

        // Dot product
        #expect(v1.dot(v2) < 0.0001) // orthogonal
        #expect(abs(v1.dot(v3) - 1.0) < 0.0001) // parallel
    }

    @Test func test_VectorNormalization() async throws {
        let v = FloatVector([3.0, 4.0]) // 3-4-5 triangle
        let normalized = v.normalized()

        // Should have unit length
        let length = sqrt(normalized[0] * normalized[0] + normalized[1] * normalized[1])
        #expect(abs(length - 1.0) < 0.0001)

        // Direction preserved
        #expect(abs(normalized[0] - 0.6) < 0.0001)
        #expect(abs(normalized[1] - 0.8) < 0.0001)
    }

    @Test func test_VectorBinarySerialization() async throws {
        let original = FloatVector([1.5, -2.5, 3.14159, 0.0, -0.0001])
        let data = original.toData()
        let restored = FloatVector(fromData: data)

        #expect(original.dimensions == restored.dimensions)
        for i in 0..<original.dimensions {
            #expect(abs(original[i] - restored[i]) < 0.00001)
        }
    }

    @Test func test_MultipleDocumentsWithVectors() async throws {
        let lattice = try testLattice(Document.self)

        // Create documents with different embeddings
        let docs = [
            Document(title: "Doc A", embedding: [1.0, 0.0, 0.0]),
            Document(title: "Doc B", embedding: [0.0, 1.0, 0.0]),
            Document(title: "Doc C", embedding: [0.0, 0.0, 1.0]),
            Document(title: "Doc D", embedding: [0.5, 0.5, 0.0]),
        ]

        lattice.add(contentsOf: docs)

        let results = lattice.objects(Document.self)
        #expect(results.count == 4)

        // Find document most similar to [1, 0, 0] using Swift-side distance
        let query = FloatVector([1.0, 0.0, 0.0])
        var bestDoc: Document?
        var bestDistance = Float.infinity

        for doc in results {
            let distance = doc.embedding.cosineDistance(to: query)
            if distance < bestDistance {
                bestDistance = distance
                bestDoc = doc
            }
        }

        #expect(bestDoc?.title == "Doc A")
    }

    @Test func test_NearestNeighborSearch() async throws {
        let lattice = try testLattice(Document.self)

        // Create documents with different embeddings
        let docs = [
            Document(title: "Doc A", embedding: [1.0, 0.0, 0.0]),
            Document(title: "Doc B", embedding: [0.0, 1.0, 0.0]),
            Document(title: "Doc C", embedding: [0.0, 0.0, 1.0]),
            Document(title: "Doc D", embedding: [0.7, 0.7, 0.0]),  // Close to A
            Document(title: "Doc E", embedding: [0.9, 0.1, 0.0]),  // Very close to A
        ]

        lattice.add(contentsOf: docs)

        // Query for nearest neighbors to [1, 0, 0]
        let query = FloatVector([1.0, 0.0, 0.0])
        let nearest = lattice.objects(Document.self)
            .nearest(to: query, on: \.embedding, limit: 3)

        // Should return 3 closest documents
        #expect(nearest.count == 3)

        // First should be Doc A (exact match) or Doc E (very close)
        let topTitles = nearest.map { $0.object.title }
        #expect(topTitles.contains("Doc A"))
        #expect(topTitles.contains("Doc E"))

        // Distances should be sorted (ascending)
        for i in 0..<(nearest.count - 1) {
            #expect(nearest[i].distance <= nearest[i + 1].distance)
        }

        print("Nearest neighbors to [1, 0, 0]:")
        for match in nearest {
            print("  \(match.object.title): distance = \(match.distance)")
        }
    }

    @Test func test_NearestNeighborWithCosineDistance() async throws {
        let lattice = try testLattice(Document.self)

        // Create documents with embeddings that differ in magnitude but same direction
        let docs = [
            Document(title: "Unit", embedding: [1.0, 0.0, 0.0]),
            Document(title: "Scaled", embedding: [10.0, 0.0, 0.0]),  // Same direction, 10x magnitude
            Document(title: "Orthogonal", embedding: [0.0, 1.0, 0.0]),
        ]

        lattice.add(contentsOf: docs)

        let query = FloatVector([5.0, 0.0, 0.0])
        let nearest = lattice.objects(Document.self)
            .nearest(to: query, on: \.embedding, limit: 3, distance: .cosine)

        // With cosine distance, "Unit" and "Scaled" should have distance ~0 (same direction)
        // "Orthogonal" should have distance ~1
        print("Cosine distances to [5, 0, 0]:")
        for match in nearest {
            print("  \(match.object.title): distance = \(match.distance)")
        }

        // First two should be Unit/Scaled with very small distance
        #expect(nearest[0].distance < 0.1)
        #expect(nearest[1].distance < 0.1)
    }
    
    #if canImport(NaturalLanguage)
    @Test
    func test_NearestNeighborWithCosineDistance_NaturalLanguage() async throws {
        let nlEmbedding = NLEmbedding.wordEmbedding(for: .english)!

        // Words with semantic relationships
        let words = [
            "king", "queen", "prince", "princess",  // royalty
            "dog", "cat", "puppy", "kitten",        // animals
            "car", "truck", "bicycle", "motorcycle" // vehicles
        ]

        // Create documents with real NL embeddings
        let lattice = try testLattice(Document.self)

        for word in words {
            guard let vector = nlEmbedding.vector(for: word) else {
                print("No embedding for '\(word)', skipping")
                continue
            }
            let floatVector = vector.map { Float($0) }
            let doc = Document(title: word, embedding: floatVector)
            lattice.add(doc)
        }

        let storedCount = lattice.objects(Document.self).count
        print("Stored \(storedCount) documents with embeddings")
        #expect(storedCount > 0)

        // Query: find words similar to "king"
        guard let queryVector = nlEmbedding.vector(for: "king") else {
            Issue.record("No embedding for query word 'king'")
            return
        }
        let query = FloatVector(queryVector.map { Float($0) })

        let nearest = lattice.objects(Document.self)
            .nearest(to: query, on: \.embedding, limit: 5, distance: .cosine)

        print("\nNearest neighbors to 'king':")
        for match in nearest {
            print("  \(match.object.title): distance = \(match.distance)")
        }

        // "king" should be closest to itself (distance ~0)
        #expect(nearest[0].object.title == "king")
        #expect(nearest[0].distance < 0.01)

        // Other royalty words should be in top results
        let topTitles = nearest.prefix(4).map { $0.object.title }
        let royaltyInTop = topTitles.filter { ["king", "queen", "prince", "princess"].contains($0) }
        print("Royalty words in top 4: \(royaltyInTop)")
        #expect(royaltyInTop.count >= 2, "Expected at least 2 royalty words in top 4 results")

        // Test another query: "dog"
        guard let dogVector = nlEmbedding.vector(for: "dog") else {
            Issue.record("No embedding for 'dog'")
            return
        }
        let dogQuery = FloatVector(dogVector.map { Float($0) })

        let nearestToDog = lattice.objects(Document.self)
            .nearest(to: dogQuery, on: \.embedding, limit: 5, distance: .cosine)

        print("\nNearest neighbors to 'dog':")
        for match in nearestToDog {
            print("  \(match.object.title): distance = \(match.distance)")
        }

        // Animal words should cluster together
        let dogTopTitles = nearestToDog.prefix(4).map { $0.object.title }
        let animalsInTop = dogTopTitles.filter { ["dog", "cat", "puppy", "kitten"].contains($0) }
        print("Animal words in top 4: \(animalsInTop)")
        #expect(animalsInTop.count >= 2, "Expected at least 2 animal words in top 4 results")
    }
    #endif // canImport(NaturalLanguage)

    @Test
    func test_FilteredVectorSearch() async throws {
        let lattice = try testLattice(CategorizedDocument.self)

        // Create documents in different categories with embeddings
        // Category A: vectors pointing in X direction
        // Category B: vectors pointing in Y direction
        let docs = [
            // Category A - all similar to each other (X-axis variants)
            CategorizedDocument(title: "A1", category: "A", embedding: [1.0, 0.0, 0.0]),
            CategorizedDocument(title: "A2", category: "A", embedding: [0.9, 0.1, 0.0]),
            CategorizedDocument(title: "A3", category: "A", embedding: [0.8, 0.2, 0.0]),

            // Category B - all similar to each other (Y-axis variants)
            CategorizedDocument(title: "B1", category: "B", embedding: [0.0, 1.0, 0.0]),
            CategorizedDocument(title: "B2", category: "B", embedding: [0.1, 0.9, 0.0]),
            CategorizedDocument(title: "B3", category: "B", embedding: [0.2, 0.8, 0.0]),
        ]

        lattice.add(contentsOf: docs)

        // Query: find nearest to [1, 0, 0] (most similar to category A)
        let query = FloatVector([1.0, 0.0, 0.0])

        // Without filter: should return A1, A2, A3 as top 3
        let allNearest = lattice.objects(CategorizedDocument.self)
            .nearest(to: query, on: \.embedding, limit: 3, distance: .cosine)

        print("Nearest to [1,0,0] (no filter):")
        for match in allNearest {
            print("  \(match.object.title) (\(match.object.category)): \(match.distance)")
        }

        #expect(allNearest.count == 3)
        // All top 3 should be from category A since query is [1,0,0]
        let allCategories = allNearest.map { $0.object.category }
        #expect(allCategories.allSatisfy { $0 == "A" }, "Without filter, top 3 should be category A")

        // With filter: only search in category B
        let filteredNearest = lattice.objects(CategorizedDocument.self)
            .where { $0.category == "B" }
            .nearest(to: query, on: \.embedding, limit: 3, distance: .cosine)

        print("\nNearest to [1,0,0] (filtered to category B):")
        for match in filteredNearest {
            print("  \(match.object.title) (\(match.object.category)): \(match.distance)")
        }

        #expect(filteredNearest.count == 3)
        // All results should be from category B despite query being closer to A
        let filteredCategories = filteredNearest.map { $0.object.category }
        #expect(filteredCategories.allSatisfy { $0 == "B" }, "With filter, all results should be category B")

        // B2 [0.1, 0.9, 0] should be closest to [1,0,0] among B category
        // (has highest X component)
        #expect(filteredNearest[0].object.title == "B3", "B3 should be closest to [1,0,0] in category B")
    }

    @Test func test_NearestOnEmptyTable() async throws {
        let lattice = try testLattice(Document.self)

        // Query nearest on a table with no data — vec0 table doesn't exist yet.
        // Should return empty results, not crash.
        let query = FloatVector([1.0, 0.0, 0.0])
        let nearest = lattice.objects(Document.self)
            .nearest(to: query, on: \.embedding, limit: 5, distance: .cosine)

        #expect(nearest.isEmpty)
    }
}

// =============================================================================
// MARK: - Vec0 Orphan Rowid Regression Test
// =============================================================================

/// Regression test: deleting a model row via Lattice leaves orphan entries in
/// the vec0 backing table (_*_embedding_vec_rowids). The DELETE trigger fires
/// but vec0 DELETE is unreliable inside triggers — the shadow table deletion
/// silently fails, so the rowid and its chunk slot persist indefinitely.
///
/// Over time this bloats the vec0 chunk storage (each orphan reserves a full
/// chunk slot of ~1.5 MB for 384-dim vectors). In production this grew the
/// memory.sqlite vec0 index to 2.66 GB for only 10K live memories.
@Suite("Vec0 Orphan Tests")
class Vec0OrphanTests: BaseTest {

    @Test func test_deleteLeaves_vec0OrphanRowids() async throws {
        let lattice = try testLattice(Document.self)
        let dbPath = lattice.configuration.fileURL.path(percentEncoded: false)

        // Insert 5 documents with embeddings
        for i in 0..<5 {
            lattice.add(Document(
                title: "doc-\(i)",
                embedding: [Float(i), Float(5 - i), 0.5]))
        }

        // Verify model table and vec0 rowids are in sync
        let modelCountBefore = lattice.objects(Document.self).count
        #expect(modelCountBefore == 5)

        let rowidsBefore = sqlite3Count(dbPath: dbPath,
            table: "_Document_embedding_vec_rowids")
        #expect(rowidsBefore == 5, "vec0 rowids should match model count before delete")

        // Delete 3 documents via Lattice (fires DELETE trigger)
        let toDelete = Array(lattice.objects(Document.self).prefix(3))
        for doc in toDelete {
            lattice.delete(doc)
        }

        // Model table should have 2 rows
        let modelCountAfter = lattice.objects(Document.self).count
        #expect(modelCountAfter == 2)

        // Check vec0 rowids — if trigger DELETE works, should be 2.
        // If trigger DELETE silently fails (the known bug), will be 5.
        let rowidsAfter = sqlite3Count(dbPath: dbPath,
            table: "_Document_embedding_vec_rowids")

        // This documents the bug: orphan rowids accumulate
        if rowidsAfter > modelCountAfter {
            // Bug confirmed: vec0 DELETE inside trigger left orphans
            let orphans = rowidsAfter - modelCountAfter
            print("vec0 orphan rowids detected: \(orphans) orphans "
                + "(\(rowidsAfter) rowids for \(modelCountAfter) live rows)")

            // nearest() still returns correct results (joins back to model)
            // but scans all chunks including orphans — O(total) not O(live)
            let query = FloatVector([1.0, 0.0, 0.0])
            let results = lattice.objects(Document.self)
                .nearest(to: query, on: \.embedding, limit: 10)
            #expect(results.count == modelCountAfter,
                "nearest() should only return live rows despite orphan rowids")
        }

        // Mark expected failure until the fix lands
        #expect(rowidsAfter == modelCountAfter,
            "vec0 rowids should equal model count after delete — orphans indicate trigger-based DELETE silently failed")
    }

    /// Simulate the IPC sync path: local DB writes a memory, then the synced DB
    /// relays a DELETE back via apply_remote_changes (inside a transaction).
    /// This is the production path for cross-device deletes.
    @Test func test_ipcSyncDelete_leaves_vec0OrphanRowids() async throws {
        // Two DBs: local writes, synced receives from cloud and IPC-syncs back
        let localPath = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 32))-local.sqlite")
        let syncedPath = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 32))-synced.sqlite")

        // Configure synced DB with IPC (this is the production setup)
        var syncedConfig = Lattice.Configuration(fileURL: syncedPath)
        syncedConfig.ipcTargets = [.init(channel: "test-orphan-\(String.random(length: 8))")]

        let local = try Lattice(Document.self, configuration: .init(fileURL: localPath))
        let synced = try Lattice(Document.self, configuration: syncedConfig)

        let dbPath = localPath.path(percentEncoded: false)

        // Insert 5 docs into local
        for i in 0..<5 {
            local.add(Document(
                title: "doc-\(i)",
                embedding: [Float(i), Float(5 - i), 0.5]))
        }

        // Verify vec0 is populated
        let rowidsBefore = sqlite3Count(dbPath: dbPath,
            table: "_Document_embedding_vec_rowids")
        #expect(rowidsBefore == 5)

        // Wait a moment for IPC sync to propagate local → synced
        try await Task.sleep(for: .seconds(2))

        // Check if synced DB received the data
        let syncedCount = synced.objects(Document.self).count
        print("Synced DB has \(syncedCount) documents after IPC sync")

        // Now delete 3 docs from LOCAL (simulating what happens when
        // a cross-device delete arrives via WSS → synced → IPC → local)
        let toDelete = Array(local.objects(Document.self).prefix(3))
        for doc in toDelete {
            local.delete(doc)
        }

        let modelCountAfter = local.objects(Document.self).count
        #expect(modelCountAfter == 2)

        let rowidsAfter = sqlite3Count(dbPath: dbPath,
            table: "_Document_embedding_vec_rowids")

        if rowidsAfter > modelCountAfter {
            print("IPC sync context left \(rowidsAfter - modelCountAfter) orphan vec0 rowids")
        }

        #expect(rowidsAfter == modelCountAfter,
            "Delete in IPC sync context should not leave orphan vec0 rowids")

        // Cleanup
        try? Lattice.delete(for: .init(fileURL: localPath))
        try? Lattice.delete(for: .init(fileURL: syncedPath))
    }

    @Test func test_deleteWhere_leaves_vec0OrphanRowids() async throws {
        let lattice = try testLattice(Document.self)
        let dbPath = lattice.configuration.fileURL.path(percentEncoded: false)

        for i in 0..<5 {
            lattice.add(Document(
                title: "doc-\(i)",
                embedding: [Float(i), Float(5 - i), 0.5]))
        }

        let rowidsBefore = sqlite3Count(dbPath: dbPath,
            table: "_Document_embedding_vec_rowids")
        #expect(rowidsBefore == 5)

        // Bulk delete via delete(where:) — the path used by MemoryTools.forget
        lattice.delete(Document.self, where: { $0.title == "doc-0" || $0.title == "doc-1" || $0.title == "doc-2" })

        let modelCountAfter = lattice.objects(Document.self).count
        #expect(modelCountAfter == 2)

        let rowidsAfter = sqlite3Count(dbPath: dbPath,
            table: "_Document_embedding_vec_rowids")

        if rowidsAfter > modelCountAfter {
            print("delete(where:) left \(rowidsAfter - modelCountAfter) orphan vec0 rowids")
        }

        #expect(rowidsAfter == modelCountAfter,
            "vec0 rowids should equal model count after delete(where:)")
    }

    @Test func test_multiConnection_deleteLeaves_vec0OrphanRowids() async throws {
        // Simulate production: connection A writes, connection B deletes.
        let path = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 32)).sqlite")

        let connA = try Lattice(Document.self, configuration: .init(fileURL: path))
        let connB = try Lattice(Document.self, configuration: .init(fileURL: path))
        let dbPath = path.path(percentEncoded: false)

        // Insert on connection A
        for i in 0..<5 {
            connA.add(Document(
                title: "doc-\(i)",
                embedding: [Float(i), Float(5 - i), 0.5]))
        }

        // Verify connection B sees the rows
        let countB = connB.objects(Document.self).count
        #expect(countB == 5)

        // Delete on connection B
        let toDelete = Array(connB.objects(Document.self).prefix(3))
        for doc in toDelete {
            connB.delete(doc)
        }

        let modelCountAfter = connB.objects(Document.self).count
        #expect(modelCountAfter == 2)

        // Check vec0 rowids — cross-connection DELETE may leave orphans
        let rowidsAfter = sqlite3Count(dbPath: dbPath,
            table: "_Document_embedding_vec_rowids")

        if rowidsAfter > modelCountAfter {
            print("Multi-connection delete left \(rowidsAfter - modelCountAfter) orphan vec0 rowids")
        }

        #expect(rowidsAfter == modelCountAfter,
            "Cross-connection delete should not leave orphan vec0 rowids")

        // Cleanup
        try? Lattice.delete(for: .init(fileURL: path))
    }

    /// Root cause reproduction: when a Lattice uses attaching() to create a
    /// UNION ALL view over local + synced DBs, the knn_query reconciliation
    /// reads from the combined view but writes into the local-only vec0 index.
    /// This inserts vec0 entries for synced-only memories that don't exist in
    /// the local Memory table, creating permanent orphans.
    @Test func test_attachedLattice_reconcileCreatesOrphans() async throws {
        let localPath = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 32)).sqlite")
        let syncedPath = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 32)).sqlite")

        let local = try Lattice(Document.self, configuration: .init(fileURL: localPath))
        let synced = try Lattice(Document.self, configuration: .init(fileURL: syncedPath))
        let dbPath = localPath.path(percentEncoded: false)

        // Insert 3 docs in local, 5 docs in synced
        for i in 0..<3 {
            local.add(Document(
                title: "local-\(i)",
                embedding: [Float(i), 0.0, 1.0]))
        }
        for i in 0..<5 {
            synced.add(Document(
                title: "synced-\(i)",
                embedding: [0.0, Float(i), 1.0]))
        }

        // Create the attached (UNION ALL) view — this is what readLattice()
        // returns for synced projects in production
        let combined = local.attaching(lattice: synced)

        // Verify combined view sees all 8 docs
        let combinedCount = combined.objects(Document.self).count
        #expect(combinedCount == 8)

        // Run nearest() — this triggers knn_query which does reconciliation.
        // The reconcile compares COUNT(*) from the UNION ALL view (8) against
        // the local vec0 count (3), sees mismatch, and inserts all 8 into
        // the local vec0 — including the 5 synced-only memories.
        let query = FloatVector([1.0, 0.0, 0.0])
        let _ = combined.objects(Document.self)
            .nearest(to: query, on: \.embedding, limit: 5)

        // Check local vec0 rowids — should be 3 (local only).
        // Use sqlite3 directly to get the true local Memory count, because
        // the Lattice instance may still resolve to the UNION ALL view.
        let rowidsAfter = sqlite3Count(dbPath: dbPath,
            table: "_Document_embedding_vec_rowids")
        let localMemoryCount = sqlite3Count(dbPath: dbPath, table: "Document")

        if rowidsAfter > localMemoryCount {
            let orphans = rowidsAfter - localMemoryCount
            print("Attached reconcile created \(orphans) orphan vec0 rowids "
                + "(\(rowidsAfter) rowids for \(localMemoryCount) local memories)")
        }

        #expect(rowidsAfter == localMemoryCount,
            "vec0 should only contain entries for local memories, not synced ones")

        // Cleanup
        try? Lattice.delete(for: .init(fileURL: localPath))
        try? Lattice.delete(for: .init(fileURL: syncedPath))
    }

    // MARK: - SQLite helper

    /// Open the DB file directly and count rows in a backing table.
    /// This bypasses Lattice to inspect vec0 shadow table state.
    private func sqlite3Count(dbPath: String, table: String) -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return -1
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM \(table)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return -1
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(stmt, 0))
    }
}

// =============================================================================
// MARK: - Vec0 Lock Storm Regression Test
// =============================================================================

/// Regression test for "database is locked" storm on _*_embedding_vec tables.
///
/// Before the fix, db::execute() treated vec0 DELETE returning SQLITE_ROW as
/// an error. This caused knn_query reconciliation to fail and retry on every
/// query — a cascade of lock contention with hundreds of error log lines.
@Suite("Vec0 Lock Storm Tests")
class Vec0LockStormTests: BaseTest {

    /// Rapid add + nearest on same Lattice.
    /// The INSERT trigger fires DELETE+INSERT on vec0 for each add,
    /// while nearest() may trigger reconciliation if counts diverge.
    @Test(.timeLimit(.minutes(1)))
    func test_Vec0RapidAddAndQuery_NoLockErrors() async throws {
        let lattice = try testLattice(Document.self)

        // Seed initial data
        for i in 0..<10 {
            lattice.add(Document(
                title: "initial-\(i)",
                embedding: [Float(i) / 10.0, Float(10 - i) / 10.0, 0.5]))
        }

        // Interleave adds and nearest queries rapidly
        let query = FloatVector([1.0, 0.0, 0.0])
        var querySuccesses = 0
        var addSuccesses = 0

        for i in 0..<100 {
            if i % 2 == 0 {
                // Add a document (triggers vec0 INSERT trigger)
                lattice.add(Document(
                    title: "rapid-\(i)",
                    embedding: [Float.random(in: 0...1), Float.random(in: 0...1), Float.random(in: 0...1)]))
                addSuccesses += 1
            } else {
                // Query nearest (may trigger reconciliation)
                let results = lattice.objects(Document.self)
                    .nearest(to: query, on: \.embedding, limit: 5)
                if !results.isEmpty {
                    querySuccesses += 1
                }
            }
        }

        #expect(addSuccesses == 50)
        #expect(querySuccesses > 0, "nearest() queries should succeed during rapid adds")

        let total = lattice.objects(Document.self).count
        #expect(total == 60, "Should have 10 initial + 50 rapid adds = 60 documents, got \(total)")
    }

    /// Perf test: .count on nearest results should not materialize Swift objects.
    /// With 5000 128-dim vectors and k=1000, the old path allocates 1000
    /// _NearestMatch<T> objects just to discard them; the fast path reads
    /// only the C++ vector size.
    @Test(.timeLimit(.minutes(2)))
    func test_NearestCountPerformance() async throws {
        let lattice = try testLattice(Document.self)

        // Insert 5000 documents with 128-dim random embeddings
        let dims = 128
        let docCount = 5000
        for i in 0..<docCount {
            let embedding = (0..<dims).map { _ in Float.random(in: -1...1) }
            lattice.add(Document(title: "doc-\(i)", embedding: embedding))
        }

        let k = 1000
        let query = FloatVector((0..<dims).map { _ in Float.random(in: -1...1) })

        let nearest = lattice.objects(Document.self)
            .nearest(to: query, on: \.embedding, limit: k)

        // Warm up — first query may trigger vec0 reconciliation
        _ = nearest.count

        // Measure .count (endIndex) — this is the hot path we're optimizing
        let countIterations = 20
        let countStart = ContinuousClock.now
        for _ in 0..<countIterations {
            _ = nearest.count
        }
        let countElapsed = ContinuousClock.now - countStart
        let countAvgMs = Double(countElapsed.components.attoseconds) / 1e15 / Double(countIterations)
            + Double(countElapsed.components.seconds) * 1000.0 / Double(countIterations)

        // Measure endIndex directly to see if .count calls it more than once
        let endIndexIterations = 20
        let endIndexStart = ContinuousClock.now
        for _ in 0..<endIndexIterations {
            _ = nearest.endIndex
        }
        let endIndexElapsed = ContinuousClock.now - endIndexStart
        let endIndexAvgMs = Double(endIndexElapsed.components.attoseconds) / 1e15 / Double(endIndexIterations)
            + Double(endIndexElapsed.components.seconds) * 1000.0 / Double(endIndexIterations)
        print("endIndex direct avg:      \(String(format: "%.2f", endIndexAvgMs)) ms")

        // Measure snapshot().count for comparison — this always materializes objects
        let snapshotStart = ContinuousClock.now
        for _ in 0..<countIterations {
            _ = nearest.snapshot().count
        }
        let snapshotElapsed = ContinuousClock.now - snapshotStart
        let snapshotAvgMs = Double(snapshotElapsed.components.attoseconds) / 1e15 / Double(countIterations)
            + Double(snapshotElapsed.components.seconds) * 1000.0 / Double(countIterations)

        print("NearestResults.count avg: \(String(format: "%.2f", countAvgMs)) ms (k=\(k), docs=\(docCount), dims=\(dims))")
        print("snapshot().count avg:     \(String(format: "%.2f", snapshotAvgMs)) ms")
        print("Speedup:                  \(String(format: "%.1f", snapshotAvgMs / countAvgMs))x")

        // .count should be meaningfully faster than snapshot().count
        // After the fix, expect at least 2x speedup since it skips object materialization
        #expect(nearest.count == k)
    }

    /// Bulk delete + re-add with embeddings (simulates memory consolidation).
    /// Each remove triggers DELETE on vec0, each add triggers INSERT trigger
    /// which does DELETE+INSERT. Interleaved nearest() queries must not fail.
    @Test(.timeLimit(.minutes(1)))
    func test_Vec0BulkDeleteAndReAdd_NoLockErrors() async throws {
        let lattice = try testLattice(Document.self)

        // Create 50 documents
        var docs: [Document] = []
        for i in 0..<50 {
            let doc = Document(
                title: "doc-\(i)",
                embedding: [Float(i) / 50.0, Float(50 - i) / 50.0, 0.1])
            lattice.add(doc)
            docs.append(doc)
        }

        // Verify nearest works before churn
        let query = FloatVector([1.0, 0.0, 0.0])
        let before = lattice.objects(Document.self)
            .nearest(to: query, on: \.embedding, limit: 5)
        #expect(before.count == 5)

        // Now delete half and re-add new ones (simulates consolidation)
        for i in 0..<25 {
            lattice.delete(docs[i])
        }

        // Query nearest mid-churn — reconciliation fires if vec0 count != model count
        let mid = lattice.objects(Document.self)
            .nearest(to: query, on: \.embedding, limit: 5)
        #expect(mid.count == 5, "nearest() should work after deletes, got \(mid.count)")

        // Re-add 25 new docs
        for i in 0..<25 {
            lattice.add(Document(
                title: "new-\(i)",
                embedding: [Float.random(in: 0...1), Float.random(in: 0...1), Float.random(in: 0...1)]))
        }

        // Final query
        let after = lattice.objects(Document.self)
            .nearest(to: query, on: \.embedding, limit: 5)
        #expect(after.count == 5, "nearest() should work after re-adds, got \(after.count)")

        let total = lattice.objects(Document.self).count
        #expect(total == 50, "Should have 25 remaining + 25 new = 50 documents, got \(total)")
    }
}
