import Foundation
import Testing
@testable import Lattice

@Model private final class DynamicGroupedItem {
    var scope: String = ""
    var label: String = ""
    var payload: Data = Data()
}

@Suite("Dynamic scalar projection", .serialized)
struct DynamicGroupedCountTests {
    private func withStore(_ body: (Lattice) throws -> Void) throws {
        let directory = testTemporaryDirectory.appendingPathComponent("dynamic-grouped-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try Lattice(DynamicGroupedItem.self, configuration: .init(fileURL: directory.appendingPathComponent("store.sqlite")))
        defer { store.close(); try? FileManager.default.removeItem(at: directory) }
        try body(store)
    }
    private func add(_ store: Lattice, scope: String, label: String, id: UUID = UUID()) throws {
        let row = DynamicGroupedItem(); row.scope = scope; row.label = label
        row.payload = Data(repeating: 7, count: 65_536)
        try store.add(row, preservingGlobalId: id)
    }
    @Test func boundKeysetPagesDoNotHydratePayloadOrCrossScope() throws {
        try withStore { store in
            let scope = "selected ' ? -- \u{2603}"
            var expected: [String] = []
            try store.transaction {
                for index in 1...35 {
                    let id = try #require(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index)))
                    expected.append(id.uuidString.lowercased())
                    try add(store, scope: scope, label: "Seat \(index)", id: id)
                }
                try add(store, scope: "other", label: "Excluded")
            }
            func page(after: String) throws -> [String] {
                try store.dynamicObjects("DynamicGroupedItem")
                    .where("id IN (SELECT id FROM DynamicGroupedItem WHERE scope = ? AND globalId > ? ORDER BY globalId LIMIT 32)")
                    .groupedCounts(by: "globalId", parameters: [.text(scope), .text(after)]).map(\.key).sorted()
            }
            #if DEBUG && !ORBITAL_PERF
            let before = LatticePerf.threadCounters().materializations
            #endif
            let first = try page(after: ""), last = try #require(first.last)
            let second = try page(after: last)
            #expect(first.count == 32 && second.count == 3)
            #expect(first + second == expected)
            let finalKey = try #require(second.last)
            #expect(try page(after: finalKey).isEmpty)
            #if DEBUG && !ORBITAL_PERF
            #expect(LatticePerf.threadCounters().materializations == before)
            #endif
            let rejected = try store.dynamicObjects("DynamicGroupedItem").where("scope = ?")
                .groupedCounts(by: "label", parameters: [.text(scope + "' OR 1=1 --")])
            #expect(rejected.isEmpty)
        }
    }
    @Test func schemaOrderingAndClosedHandleRefuseInsteadOfEmptySuccess() throws {
        try withStore { store in
            try add(store, scope: "one", label: "One")
            for column in ["missing", "label) FROM DynamicGroupedItem; --"] {
                #expect(throws: (any Error).self) {
                    try store.dynamicObjects("DynamicGroupedItem").groupedCounts(by: column)
                }
            }
            #expect(throws: (any Error).self) { try store.dynamicObjects("Missing").groupedCounts(by: "globalId") }
            #expect(throws: (any Error).self) {
                try store.dynamicObjects("DynamicGroupedItem").sortedBy("label").groupedCounts(by: "label")
            }
            let query = store.dynamicObjects("DynamicGroupedItem")
            store.close()
            #expect(throws: (any Error).self) { try query.groupedCounts(by: "label") }
        }
    }
    @Test func liveProjectionSeesOwnTransactionAndRollback() throws {
        struct Abort: Error {}
        try withStore { store in
            try add(store, scope: "selected", label: "Kept")
            let rows = store.dynamicObjects("DynamicGroupedItem").where("scope = ?")
            #expect(throws: Abort.self) {
                try store.transaction {
                    try add(store, scope: "selected", label: "Temporary")
                    let keys = try rows.groupedCounts(by: "label", parameters: [.text("selected")]).map(\.key)
                    #expect(Set(keys) == ["Kept", "Temporary"])
                    throw Abort()
                }
            }
            #expect(try rows.groupedCounts(by: "label", parameters: [.text("selected")]) == [.init(key: "Kept", count: 1)])
        }
    }
}
