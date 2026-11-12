import Foundation
import Testing
@testable import Lattice

@Suite("Transaction iteration facts")
struct TransactionIterationFactsTests {
    @Test func transactionBatchesAndExplicitStableKeyWalkReturnTheSameRows() throws {
        try withQueryCostFactStore(rowCount: 9) { db in
            try db.withTransaction {
                let results = db.objects(QueryCostFactItem.self).sortedBy(\.rank)
                let iteratorStart = Lattice.threadSQLStatementCount
                var rows: [QueryCostFactItem] = []
                for row in results { rows.append(row) }
                let iteratorSQL = Lattice.threadSQLStatementCount - iteratorStart
                #expect(rows.count == 9)
                #expect(iteratorSQL == 3, "Nine rows at page size four require three batch queries")
                let ranks = rows.map(\.rank)
                let ids = rows.map(\.globalId)
                #expect(ranks == Array(0..<9))
                #expect(ids.allSatisfy { $0 != nil })

                // A caller can use a stable, unique scalar key inside the
                // transaction too. This fixture never changes that key during
                // either walk; it does not promise behavior under key mutation.
                let keysetStart = Lattice.threadSQLStatementCount
                var keysetRanks: [Int] = []
                var keysetIDs: [UUID?] = []
                var lastRank = -1
                while true {
                    let page = db.objects(QueryCostFactItem.self)
                        .where { $0.rank > lastRank }
                        .sortedBy(\.rank)
                        .materializedSnapshot(limit: 4)
                    keysetRanks.append(contentsOf: page.map(\.rank))
                    keysetIDs.append(contentsOf: page.map(\.globalId))
                    guard page.count == 4, let last = page.last else { break }
                    lastRank = last.rank
                }
                let keysetSQL = Lattice.threadSQLStatementCount - keysetStart
                #expect(keysetRanks == ranks)
                #expect(keysetIDs == ids)
                #expect(keysetSQL == 3)
                // Statement counts do not measure rows skipped by OFFSET or
                // SQLite VM work. They cannot establish equal query cost.
                print("QUERY_COST transaction_rows=9 page_size=4 iterator_sql=\(iteratorSQL) stable_key_sql=\(keysetSQL)")
            }
        }
    }
}
