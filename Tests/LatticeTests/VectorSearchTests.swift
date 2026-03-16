import Foundation
import Lattice
import Testing
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
