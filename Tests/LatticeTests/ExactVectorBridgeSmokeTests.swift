import Foundation
import Testing
import CxxStdlib
import LatticeSwiftCppBridge
@testable import Lattice

@Model private final class ExactBridgeSmokeItem {
    var title: String = ""
    var eligible: Int = 1
    var embedding: FloatVector = FloatVector([])
}

// Internal importer/bridge smoke only. This does not activate public nearest
// query lowering or establish the public exact-search shape contract.
@Suite("Exact vector bridge importer smoke", .serialized, .timeLimit(.minutes(1)))
struct ExactVectorBridgeSmokeTests {
    private func store() throws -> Lattice {
        var configuration = Lattice.Configuration(storage: .memory())
        configuration.busyTimeoutMs = 500
        configuration.resultsTuning.crossProcessBeltIntervalMs = nil
        return try Lattice(ExactBridgeSmokeItem.self, configuration: configuration)
    }

    private func request(k: Int64 = 2) -> lattice.exact_vector_request {
        var native = lattice.exact_vector_request()
        native.setTable(std.string(ExactBridgeSmokeItem.entityName))
        native.setColumn(std.string("embedding"))
        native.setK(k)
        native.setMetric(0) // Core exact_vector_metric::l2
        let components: [Float] = [0, 0, 0, 0]
        for component in components {
            native.addComponent(component)
        }
        return native
    }

    @Test func invalidRequestsRemainDistinctFromSuccessfulEmptyRows() throws {
        let db = try store()
        defer { db.close() }
        let uninitialized = lattice.exact_vector_live_result()
        #expect(uninitialized.statusCode() == 5) // bridge_failure
        #expect(uninitialized.rowCount() == 0)

        let empty = db.cxxLatticeRef.exactNearestRows(request())
        #expect(empty.statusCode() == 0)
        #expect(empty.rowCount() == 0)
        #expect(String(empty.errorMessage()).isEmpty)

        var invalid = request(k: -1)
        invalid.setK(1) // a later valid setter must not erase the first error
        let failed = db.cxxLatticeRef.exactNearestRows(invalid)
        #expect(failed.statusCode() == 1) // invalid_request
        #expect(failed.rowCount() == 0)
        #expect(!String(failed.errorMessage()).isEmpty)

        let zeroLimit = db.cxxLatticeRef.exactNearestRows(request(k: 0))
        #expect(zeroLimit.statusCode() == 0)
        #expect(zeroLimit.rowCount() == 0)
        #expect(failed.statusCode() == 1, "later successful calls cannot clear result status")
    }

    @Test func canonicalVectorWinnerImportsAsALiveModelAndRetainsItsOwnStatus() throws {
        let db = try store()
        defer { db.close() }
        let near = ExactBridgeSmokeItem()
        near.title = "near"
        near.embedding = FloatVector([1, 0, 0, 0])
        let far = ExactBridgeSmokeItem()
        far.title = "far"
        far.embedding = FloatVector([3, 0, 0, 0])
        let excluded = ExactBridgeSmokeItem()
        excluded.title = "excluded-zero-distance"
        excluded.eligible = 0
        excluded.embedding = FloatVector([0, 0, 0, 0])
        try db.withTransaction {
            try db.add(near)
            try db.add(far)
            try db.add(excluded)
        }
        let expectedPrimaryKey = try #require(near.primaryKey)
        let expectedGlobalId = try #require(near.globalId)

        var native = request()
        native.setPredicate(std.string("m.eligible = ?"))
        let eligible = ColumnValue.int64(1).cxxValue
        native.addParameter(eligible)
        var result = db.cxxLatticeRef.exactNearestRows(native)
        try #require(result.statusCode() == 0, "\(String(result.errorMessage()))")
        try #require(result.rowCount() == 2)
        #expect(abs(result.distanceAt(0) - 1) < 0.00001)
        #expect(abs(result.distanceAt(1) - 3) < 0.00001)

        // A result is a copyable value. Object access returns an optional FRT
        // or a legacy value ref; the existing helper normalizes both imports.
        var retained = result
        result = lattice.exact_vector_live_result()
        let row = try #require(_optRef(retained.objectAt(0)))
        try #require(retained.statusCode() == 0)
        #expect(row.managedPrimaryKey() == expectedPrimaryKey)
        #expect(String(row.getString(named: std.string("title"))) == "near")
        let backend = CxxObjectBackend(row)
        #expect(backend.getData(named: "embedding") == FloatVector([1, 0, 0, 0]).toData())
        #expect(!backend.isRowCacheEnabled)
        let model = ExactBridgeSmokeItem(dynamicObject: row)
        #expect(model.primaryKey == expectedPrimaryKey)
        #expect(model.globalId == expectedGlobalId)
        #expect(!model.isMaterialized)

        _ = retained.distanceAt(-1)
        #expect(retained.statusCode() == 1)
        let absent = _optRef(retained.objectAt(0))
        #expect(absent == nil)
        #expect(retained.statusCode() == 1)
        // Releasing both result payloads must not invalidate the separately
        // retained object. Its ordinary Swift fields remain live and writable.
        try db.withTransaction { near.title = "changed-through-original" }
        #expect(model.title == "changed-through-original")
        try db.withTransaction { model.title = "changed-through-exact-model" }
        #expect(near.title == "changed-through-exact-model")
        #expect(far.title == "far")
        #expect(excluded.title == "excluded-zero-distance")
        #expect(db.lastQueryError() == nil)
        withExtendedLifetime(model) {}
    }
}
