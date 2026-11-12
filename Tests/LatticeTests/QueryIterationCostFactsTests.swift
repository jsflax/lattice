import Foundation
import Testing
@testable import Lattice

@Suite("Query iteration statement facts")
struct QueryIterationCostFactsTests {
    // All counter intervals are synchronous: the thread-local SQL funnel
    // counter excludes statements issued by other concurrently running tests.
    @Test func iterationLeavesScalarReadsLiveUnlessMaterialized() throws {
        try withQueryCostFactStore(rowCount: 9) { db in
            let results = db.objects(QueryCostFactItem.self).sortedBy(\.rank)
            _ = results.materializedSnapshot(limit: 1) // Exclude initial reader setup.

            let iterationStart = Lattice.threadSQLStatementCount
            var live: [QueryCostFactItem] = []
            for row in results { live.append(row) }
            let iterationSQL = Lattice.threadSQLStatementCount - iterationStart
            #expect(live.count == 9)
            #expect(iterationSQL > 0)
            #expect(live.allSatisfy { !$0.isMaterialized })

            let fieldsStart = Lattice.threadSQLStatementCount
            let liveRanks = live.map(\.rank)
            let liveLabels = live.map(\.label)
            let liveSelected = live.map(\.selected)
            let liveFieldSQL = Lattice.threadSQLStatementCount - fieldsStart
            #expect(liveRanks == Array(0..<9))
            #expect(liveLabels == (0..<9).map { "row-\($0)" })
            #expect(liveSelected == (0..<9).map { $0.isMultiple(of: 2) })
            #expect(liveFieldSQL == 27, "Each of three live scalar reads per row issues one statement")

            let snapshotStart = Lattice.threadSQLStatementCount
            let materialized = results.materializedSnapshot()
            let snapshotSQL = Lattice.threadSQLStatementCount - snapshotStart
            #expect(materialized.count == 9)
            #expect(materialized.allSatisfy(\.isMaterialized))
            let cachedStart = Lattice.threadSQLStatementCount
            let cachedRanks = materialized.map(\.rank)
            let cachedLabels = materialized.map(\.label)
            let cachedSelected = materialized.map(\.selected)
            let cachedFieldSQL = Lattice.threadSQLStatementCount - cachedStart
            #expect(cachedRanks == liveRanks && cachedLabels == liveLabels && cachedSelected == liveSelected)
            #expect(cachedFieldSQL == 0)
            print("QUERY_COST scalar_rows=9 fields_per_row=3 iterator_sql=\(iterationSQL) live_field_sql=\(liveFieldSQL) materialized_snapshot_sql=\(snapshotSQL) materialized_field_sql=\(cachedFieldSQL)")
        }
    }
}
