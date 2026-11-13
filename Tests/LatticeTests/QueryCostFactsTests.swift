import Foundation
import Testing
@testable import Lattice

@Model final class QueryCostFactItem {
    var rank: Int = 0
    var label: String = ""
    var selected: Bool = false
}

func withQueryCostFactStore(rowCount: Int, pageSize: Int = 4,
                           _ body: (Lattice) throws -> Void) throws {
    let directory = testTemporaryDirectory
        .appendingPathComponent("query-cost-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var config = Lattice.Configuration(fileURL: directory.appendingPathComponent("store.sqlite"))
    config.resultsTuning.pageSize = pageSize
    config.resultsTuning.crossProcessBeltIntervalMs = nil
    let db = try Lattice(QueryCostFactItem.self, configuration: config)
    defer { db.close(); try? FileManager.default.removeItem(at: directory) }
    try db.withTransaction {
        for rank in 0..<rowCount {
            let row = QueryCostFactItem()
            row.rank = rank
            row.label = "row-\(rank)"
            row.selected = rank.isMultiple(of: 2)
            try db.add(row)
        }
    }
    try body(db)
}
