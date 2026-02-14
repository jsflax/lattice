import Foundation
import Lattice
import Testing

@Model final class Article {
    var title: String
    @FullText var content: String
    var embedding: FloatVector

    init(title: String = "", content: String = "", embedding: [Float] = []) {
        self.title = title
        self.content = content
        self.embedding = FloatVector(embedding)
    }
}

@Suite("Full-Text Search Tests")
class FullTextSearchTests: BaseTest {

    @Test func test_BasicFullTextSearch() async throws {
        let lattice = try testLattice(Article.self)

        lattice.add(Article(title: "ML Intro", content: "Introduction to machine learning and neural networks"))
        lattice.add(Article(title: "Cooking", content: "How to cook pasta with tomato sauce"))
        lattice.add(Article(title: "Deep Learning", content: "Deep learning uses neural networks for machine intelligence"))

        let results = lattice.objects(Article.self)
            .matching("machine learning", on: \.content)
            .snapshot()

        #expect(results.count >= 1)
        let titles = results.map(\.object.title)
        #expect(titles.contains("ML Intro"))
    }

    @Test func test_FTS5WithWhereClause() async throws {
        let lattice = try testLattice(Article.self)

        lattice.add(Article(title: "ML Intro", content: "Introduction to machine learning"))
        lattice.add(Article(title: "ML Advanced", content: "Advanced machine learning techniques"))
        lattice.add(Article(title: "Cooking", content: "How to cook pasta"))

        let results = lattice.objects(Article.self)
            .where { $0.title == "ML Advanced" }
            .matching("machine learning", on: \.content)
            .snapshot()

        #expect(results.count == 1)
        #expect(results.first?.object.title == "ML Advanced")
    }

    @Test func test_FTS5UpdateAndDelete() async throws {
        let lattice = try testLattice(Article.self)

        let article = Article(title: "Test", content: "Original content about databases")
        lattice.add(article)

        // Verify original content is searchable
        let before = lattice.objects(Article.self)
            .matching("databases", on: \.content)
            .snapshot()
        #expect(before.count == 1)

        // Update content
        article.content = "Updated content about networking"

        // Old term should no longer match
        let afterOld = lattice.objects(Article.self)
            .matching("databases", on: \.content)
            .snapshot()
        #expect(afterOld.count == 0)

        // New term should match
        let afterNew = lattice.objects(Article.self)
            .matching("networking", on: \.content)
            .snapshot()
        #expect(afterNew.count == 1)

        // Delete the article
        lattice.delete(article)

        let afterDelete = lattice.objects(Article.self)
            .matching("networking", on: \.content)
            .snapshot()
        #expect(afterDelete.count == 0)
    }

    @Test func test_FTS5HybridWithVector() async throws {
        let lattice = try testLattice(Article.self)

        // Create articles with both text and embeddings
        lattice.add(Article(title: "ML Paper", content: "Machine learning algorithms for classification",
                           embedding: [1.0, 0.0, 0.0, 0.0]))
        lattice.add(Article(title: "DL Paper", content: "Deep learning with neural networks",
                           embedding: [0.9, 0.1, 0.0, 0.0]))
        lattice.add(Article(title: "Cooking", content: "Pasta recipes and cooking techniques",
                           embedding: [0.0, 0.0, 1.0, 0.0]))

        let queryVec = FloatVector([1.0, 0.0, 0.0, 0.0])

        // Hybrid search: FTS5 + vector
        let results = lattice.objects(Article.self)
            .matching("learning", on: \.content)
            .nearest(to: queryVec, on: \.embedding, limit: 10, distance: .l2)
            .snapshot()

        // Should find articles matching "learning" AND close to query vector
        #expect(results.count >= 1)
        // Cooking article should be excluded (doesn't match "learning")
        let titles = results.map(\.object.title)
        #expect(!titles.contains("Cooking"))
    }

    @Test func test_FTS5RankScore() async throws {
        let lattice = try testLattice(Article.self)

        lattice.add(Article(title: "Relevant", content: "Machine learning machine learning machine learning"))
        lattice.add(Article(title: "Less Relevant", content: "Introduction to machine learning basics"))

        let results = lattice.objects(Article.self)
            .matching("machine learning", on: \.content)
            .snapshot()

        #expect(results.count == 2)

        // FTS5 rank is negative (lower = better match)
        for result in results {
            let rank = result.distances["content"]
            #expect(rank != nil)
            #expect(rank! < 0) // FTS5 rank is negative
        }
    }

    @Test func test_FTS5NoResults() async throws {
        let lattice = try testLattice(Article.self)

        lattice.add(Article(title: "Test", content: "Some content about databases"))

        let results = lattice.objects(Article.self)
            .matching("nonexistentterm", on: \.content)
            .snapshot()

        #expect(results.isEmpty)
    }

    // MARK: - TextQuery API Tests

    @Test func test_TextQueryAllOf() async throws {
        let lattice = try testLattice(Article.self)

        lattice.add(Article(title: "Both", content: "Machine learning algorithms"))
        lattice.add(Article(title: "One", content: "Machine hardware specs"))
        lattice.add(Article(title: "Neither", content: "Cooking pasta recipes"))

        let results = lattice.objects(Article.self)
            .matching(.allOf("machine", "learning"), on: \.content)
            .snapshot()

        #expect(results.count == 1)
        #expect(results.first?.object.title == "Both")
    }

    @Test func test_TextQueryAnyOf() async throws {
        let lattice = try testLattice(Article.self)

        lattice.add(Article(title: "ML", content: "Machine learning algorithms"))
        lattice.add(Article(title: "Cook", content: "Learning to cook pasta"))
        lattice.add(Article(title: "Neither", content: "Database optimization tips"))

        let results = lattice.objects(Article.self)
            .matching(.anyOf("machine", "cooking"), on: \.content)
            .snapshot()

        let titles = results.map(\.object.title)
        #expect(titles.contains("ML"))
        #expect(titles.contains("Cook"))
        #expect(!titles.contains("Neither"))
    }

    @Test func test_TextQueryPhrase() async throws {
        let lattice = try testLattice(Article.self)

        lattice.add(Article(title: "Phrase", content: "Introduction to machine learning today"))
        lattice.add(Article(title: "Separate", content: "The machine is not learning anything"))

        // Phrase match: "machine learning" as contiguous words
        let results = lattice.objects(Article.self)
            .matching(.phrase("machine learning"), on: \.content)
            .snapshot()

        #expect(results.count == 1)
        #expect(results.first?.object.title == "Phrase")
    }

    @Test func test_TextQueryPrefix() async throws {
        let lattice = try testLattice(Article.self)

        lattice.add(Article(title: "Match1", content: "Algorithms for computation"))
        lattice.add(Article(title: "Match2", content: "Computer science fundamentals"))
        lattice.add(Article(title: "NoMatch", content: "Pasta recipes and cooking"))

        let results = lattice.objects(Article.self)
            .matching(.prefix("comput"), on: \.content)
            .snapshot()

        let titles = results.map(\.object.title)
        #expect(titles.contains("Match1"))
        #expect(titles.contains("Match2"))
        #expect(!titles.contains("NoMatch"))
    }
}
