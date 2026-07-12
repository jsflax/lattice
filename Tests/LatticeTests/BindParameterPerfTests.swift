import Foundation
import Testing
import Lattice

@Suite("Bind Parameter Performance Tests")
class BindParameterPerfTests: BaseTest {

    @Model final class Article {
        @Unique(compoundedWith: \Self.symbol)
        var url: String = ""
        var symbol: String = ""
    }

    private func ms(_ d: Duration) -> Double {
        Double(d.components.attoseconds) / 1_000_000_000_000_000.0
            + Double(d.components.seconds) * 1000.0
    }

    @Test func testInQuery_CursorVsSnapshot() async throws {
        let lattice = try testLattice(Article.self)

        let totalArticles = 10_000
        let symbols = ["NVDA", "AAPL", "TSLA", "META", "AMZN"]
        let allURLs = (0..<totalArticles).map { i in
            "https://financialmodelingprep.com/api/v3/stock_news/\(i)?source=fmp&t=\(String.random(length: 32))"
        }
        try lattice.transaction {
            for (i, url) in allURLs.enumerated() {
                let article = Article()
                article.url = url
                article.symbol = symbols[i % symbols.count]
                try lattice.add(article)
            }
        }
        print("Inserted \(totalArticles) articles")

        let nvdaURLs = stride(from: 0, to: totalArticles, by: symbols.count).map { allURLs[$0] }
        let newURLs = (0..<1_500).map {
            "https://financialmodelingprep.com/api/v3/stock_news/new/\($0)?source=fmp&t=\(String.random(length: 32))"
        }
        let queryURLs = nvdaURLs + newURLs
        print("Query IN set: \(queryURLs.count) URLs, expecting \(nvdaURLs.count) matches")

        // Test 1: .snapshot().map (single query)
        let snapshotStart = ContinuousClock.now
        let snapshotURLs = Set(
            lattice.objects(Article.self)
                .where { $0.symbol == "NVDA" && $0.url.in(queryURLs) }
                .snapshot()
                .map(\.url)
        )
        let snapshotElapsed = ContinuousClock.now - snapshotStart
        print("snapshot().map: \(String(format: "%.1f", ms(snapshotElapsed)))ms, found \(snapshotURLs.count)")

        // Test 2: .map (Cursor-based, batches of 100)
        let cursorStart = ContinuousClock.now
        let cursorURLs = Set(
            lattice.objects(Article.self)
                .where { $0.symbol == "NVDA" && $0.url.in(queryURLs) }
                .map(\.url)
        )
        let cursorElapsed = ContinuousClock.now - cursorStart
        print("cursor .map:    \(String(format: "%.1f", ms(cursorElapsed)))ms, found \(cursorURLs.count)")

        #expect(snapshotURLs.count == nvdaURLs.count)
        #expect(cursorURLs.count == nvdaURLs.count)
        print("Speedup: \(String(format: "%.1f", ms(cursorElapsed) / ms(snapshotElapsed)))x")
    }
}
