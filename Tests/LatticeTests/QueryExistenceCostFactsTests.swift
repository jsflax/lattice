import Foundation
import Testing
@testable import Lattice

@Suite("Query existence statement facts")
struct QueryExistenceCostFactsTests {
    @Test func oneOffFilteredIsEmptyCountsWhileFirstHydratesOnlyAMatch() throws {
        try withQueryCostFactStore(rowCount: 9) { db in
            // The transaction removes cached-count and generation setup from
            // this one-off comparison. It does not represent a warmed render.
            try db.withTransaction {
                let matches = db.objects(QueryCostFactItem.self).where { $0.rank >= 0 }
                let emptyStart = Lattice.threadSQLStatementCount
                let isEmpty = matches.isEmpty
                let emptySQL = Lattice.threadSQLStatementCount - emptyStart
                let firstStart = Lattice.threadSQLStatementCount
                let first = matches.first
                let firstSQL = Lattice.threadSQLStatementCount - firstStart
                #expect(!isEmpty)
                #expect(first?.rank == 0)
                #expect(emptySQL == 1)
                #expect(firstSQL > emptySQL, "Hydrating a live model also reads its registration key")

                let misses = db.objects(QueryCostFactItem.self).where { $0.rank < 0 }
                let missingEmptyStart = Lattice.threadSQLStatementCount
                let missingIsEmpty = misses.isEmpty
                let missingEmptySQL = Lattice.threadSQLStatementCount - missingEmptyStart
                let missingFirstStart = Lattice.threadSQLStatementCount
                let missingFirst = misses.first
                let missingFirstSQL = Lattice.threadSQLStatementCount - missingFirstStart
                #expect(missingIsEmpty && missingFirst == nil)
                #expect(missingEmptySQL == 1 && missingFirstSQL == 1)
                print("QUERY_COST existence_rows=9 matching_is_empty_sql=\(emptySQL) matching_first_sql=\(firstSQL) missing_is_empty_sql=\(missingEmptySQL) missing_first_sql=\(missingFirstSQL)")
            }
        }
    }
}
