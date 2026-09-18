import Foundation
import Dispatch
import Testing
@testable import Lattice
#if canImport(MapKit)
import MapKit
#endif

@Model private final class ProjectionShapeItem {
    @Property(name: "stored_rank") var rank: Int = 0
    @Property(name: "category_name") var category: String = ""
    var label: String = ""
    var payload: Data = Data()
    var enabled: Bool = true
    var location: CLLocationCoordinate2D
    var tags: [String] = []
    var computedRank: Int { rank + 1 }
    @Transient var transientRank: Int = 0
}

@Suite("Projection query capture")
struct ProjectionQueryShapeTests {
    private func store() throws -> Lattice {
        try Lattice(ProjectionShapeItem.self, configuration: .init(storage: .memory()))
    }

    private func requireSendable<T: Sendable>(_ value: T) {}

    @Test func limitsRejectMalformedAndUnrepresentableValues() throws {
        for count in [0, -1, Int.min] {
            #expect(throws: ProjectionReadError.self) {
                try ProjectionReadLimits(maxRows: count, maxBytes: 1, timeout: 1)
            }
            #expect(throws: ProjectionReadError.self) {
                try ProjectionReadLimits(maxRows: 1, maxBytes: count, timeout: 1)
            }
        }
        for timeout in [0.0, -1.0, Double.nan, Double.infinity, -Double.infinity, Double.greatestFiniteMagnitude] {
            #expect(throws: ProjectionReadError.self) {
                try ProjectionReadLimits(maxRows: 1, maxBytes: 1, timeout: timeout)
            }
        }
        let limits = try ProjectionReadLimits(maxRows: Int.max, maxBytes: Int.max, timeout: 0.25)
        #expect(limits.maxRows == Int.max && limits.maxBytes == Int.max)
        #expect(limits.timeout == 0.25)
        #expect(try limits.deadline(startingAt: 50) == 250_000_050)
        #expect(throws: ProjectionReadError.self) {
            try limits.deadline(startingAt: UInt64.max)
        }
        let subnanosecond = try ProjectionReadLimits(maxRows: 1, maxBytes: 1, timeout: 0.000_000_000_1)
        #expect(try subnanosecond.deadline(startingAt: 10) == 11)
        requireSendable(limits)
    }

    @Test func capturesMappedSchemaSortGroupDistinctAndCapWithoutFetching() throws {
        let db = try store()
        defer { db.close() }
        let results = db.objects(ProjectionShapeItem.self).where { $0.enabled == true }
            .group(by: \.category).distinct(by: \.label).sortedBy(\.rank, order: .reverse)
        results._fetchLimit = 7
        let descriptor = try results._projectionDescriptor
        #expect(descriptor.backend.identityHash == db.backend.identityHash)
        #expect(descriptor.schema.table == ProjectionShapeItem.entityName)
        #expect(descriptor.schema.scalarColumns == ["id", "globalId", "stored_rank", "category_name", "label", "payload", "enabled"])
        #expect(descriptor.schema.boundsColumns == ["location"])
        #expect(descriptor.schema.declaredColumns.contains("tags"))
        #expect(descriptor.sort == ProjectionSort(column: "stored_rank", direction: .descending))
        #expect(descriptor.orderBySQL == "stored_rank DESC, id ASC")
        #expect(descriptor.groupBy == "category_name")
        #expect(descriptor.distinctBy == "label")
        #expect(descriptor.fetchLimit == 7)
        #expect(descriptor.predicateColumns == ["enabled"])
        #expect(descriptor.bounds == nil)
        #expect(!descriptor.hasAttachedStores)
        results._fetchLimit = 2
        #expect(descriptor.fetchLimit == 7)
        #expect(try results._projectionDescriptor.fetchLimit == 2)
        #expect(results._shapeState.fillCounts.offset == 0)
        #expect(results._shapeState.fillCounts.keyset == 0)
        requireSendable(descriptor)
    }

    @Test func capturesPredicateAndPositionalBindingsWithoutChangingValues() throws {
        let db = try store()
        defer { db.close() }
        let ranks = Array(0..<80)
        let categories = (0..<80).map { "é\u{0}-\($0)" }
        let payload = Data([0, 255, 65, 0])
        let results = db.objects(ProjectionShapeItem.self).where {
            $0.rank.in(ranks) && $0.payload == payload && $0.category.in(categories)
        }
        let descriptor = try results._projectionDescriptor
        let predicate = try #require(results.whereStatement)
        let rendered = predicate._parameterizedPredicate()
        #expect(descriptor.whereSQL == rendered.sql)
        #expect(descriptor.bindings.count == 3)
        #expect(descriptor.bindings[1] == .blob(payload))
        guard case .text(let rankJSON) = descriptor.bindings[0],
              case .text(let categoryJSON) = descriptor.bindings[2] else {
            Issue.record("bound collection positions were lost")
            return
        }
        #expect(try JSONDecoder().decode([Int].self, from: Data(rankJSON.utf8)) == ranks)
        #expect(try JSONDecoder().decode([String].self, from: Data(categoryJSON.utf8)) == categories)
        #expect(descriptor.predicateColumns == ["stored_rank", "payload", "category_name"])
        #expect(descriptor.sort == nil)
        #expect(descriptor.orderBySQL == "id ASC")
    }

    @Test func boundsKeepLiteralPredicateChannelAndQualifiedTiebreaker() throws {
        let db = try store()
        defer { db.close() }
        let results = db.objects(ProjectionShapeItem.self).where { $0.rank.in(Array(0..<80)) }
            .withinBounds(\.location, minLat: -1, maxLat: 2, minLon: -3, maxLon: 4)
            .group(by: \.category).distinct(by: \.label).sortedBy(\.rank)
        let descriptor = try results._projectionDescriptor
        #expect(descriptor.whereSQL == results.whereStatement?.predicate)
        #expect(descriptor.bindings.isEmpty)
        #expect(descriptor.bounds == BoundsConstraintParam(column: "location", minLat: -1, maxLat: 2, minLon: -3, maxLon: 4))
        #expect(descriptor.orderBySQL == "\"ProjectionShapeItem\".\"stored_rank\" ASC, \"ProjectionShapeItem\".\"id\" ASC")
        #expect(descriptor.groupBy == "category_name" && descriptor.distinctBy == "label")
    }

    @Test func selectedFieldsUseGeneratedStoredMappingAndSchemaValidation() throws {
        let schema = try ProjectionStoredSchema(ProjectionShapeItem.self)
        #expect(try schema.column(for: \ProjectionShapeItem.rank, on: ProjectionShapeItem.self) == "stored_rank")
        #expect(try schema.column(for: \ProjectionShapeItem.primaryKey, on: ProjectionShapeItem.self) == "id")
        #expect(try schema.column(for: \ProjectionShapeItem.globalId, on: ProjectionShapeItem.self) == "globalId")
        #expect(throws: ProjectionReadError.self) {
            try schema.column(for: \ProjectionShapeItem.computedRank, on: ProjectionShapeItem.self)
        }
        #expect(throws: ProjectionReadError.self) {
            try schema.column(for: \ProjectionShapeItem.transientRank, on: ProjectionShapeItem.self)
        }
        #expect(throws: ProjectionReadError.self) {
            try schema.column(for: \ProjectionShapeItem.category.count, on: ProjectionShapeItem.self)
        }
        #expect(throws: ProjectionReadError.invalidField("tags")) { try schema.requireScalar("tags") }
        #expect(throws: ProjectionReadError.invalidField("rank")) { try schema.requireScalar("rank") }
    }

    @Test func requestCombinesExplicitCapWithoutSilentlyUsingBudgetAsLimit() throws {
        let db = try store()
        defer { db.close() }
        let results = db.objects(ProjectionShapeItem.self)
        results._fetchLimit = 9
        let descriptor = try results._projectionDescriptor
        let limits = try ProjectionReadLimits(maxRows: 2, maxBytes: 1024, timeout: 1)
        let operationID = UUID()
        let before = DispatchTime.now().uptimeNanoseconds
        let request = try ProjectionReadRequest(descriptor: descriptor, selectedColumns: ["stored_rank", "label", "stored_rank"],
                                                limits: limits, limit: 5, operationID: operationID)
        let after = DispatchTime.now().uptimeNanoseconds
        #expect(request.selectedColumns == ["stored_rank", "label", "stored_rank"])
        #expect(request.operationID == operationID)
        #expect(request.effectiveLimit == 5)
        #expect(request.deadlineNanoseconds >= before + 1_000_000_000)
        #expect(request.deadlineNanoseconds <= after + 1_000_000_000)
        let copy = request
        #expect(copy.deadlineNanoseconds == request.deadlineNanoseconds)
        let zero = try ProjectionReadRequest(descriptor: descriptor, selectedColumns: ["id"], limits: limits, limit: 0)
        #expect(zero.effectiveLimit == 0)
        let capped = try ProjectionReadRequest(descriptor: descriptor, selectedColumns: ["id"], limits: limits)
        #expect(capped.effectiveLimit == 9)
        #expect(throws: ProjectionReadError.self) {
            try ProjectionReadRequest(descriptor: descriptor, selectedColumns: ["id"], limits: limits, limit: -1)
        }
        #expect(throws: ProjectionReadError.self) {
            try ProjectionReadRequest(descriptor: descriptor, selectedColumns: [], limits: limits)
        }
        #expect(throws: ProjectionReadError.invalidField("location")) {
            try ProjectionReadRequest(descriptor: descriptor, selectedColumns: ["location"], limits: limits)
        }
        results._fetchLimit = nil
        let uncapped = try ProjectionReadRequest(descriptor: results._projectionDescriptor, selectedColumns: ["id"], limits: limits)
        #expect(uncapped.effectiveLimit == nil)
        requireSendable(request)
    }

    @Test func unknownPredicateDependenciesStayUnknownAndInvalidShapeNamesFail() throws {
        let db = try store()
        defer { db.close() }
        let schema = try ProjectionStoredSchema(ProjectionShapeItem.self)
        let sql = "id IN (SELECT id FROM OtherTable)"
        let descriptor = try ProjectionQueryDescriptor(
            backend: db.backend, schema: schema, whereSQL: sql, parameters: [], sort: nil,
            orderBySQL: "id ASC", bounds: nil, groupBy: nil, distinctBy: nil,
            fetchLimit: nil, hasAttachedStores: false)
        #expect(descriptor.whereSQL == sql)
        #expect(descriptor.predicateColumns == nil)
        for badResults in [
            TableResults<ProjectionShapeItem>(db, sortStatement: KeyPathSort<ProjectionShapeItem>(column: "missing", order: .forward)),
            TableResults<ProjectionShapeItem>(db, groupByColumn: "missing"),
            TableResults<ProjectionShapeItem>(db, distinctByColumn: "tags"),
            TableResults<ProjectionShapeItem>(db, boundsConstraint: BoundsConstraint(propertyName: "stored_rank", minLat: 0, maxLat: 1, minLon: 0, maxLon: 1)),
            TableResults<ProjectionShapeItem>(db, boundsConstraint: BoundsConstraint(propertyName: "location", minLat: .nan, maxLat: 1, minLon: 0, maxLon: 1)),
        ] {
            #expect(throws: ProjectionReadError.self) { try badResults._projectionDescriptor }
        }
        let negative = db.objects(ProjectionShapeItem.self)
        negative._fetchLimit = -1
        #expect(throws: ProjectionReadError.self) { try negative._projectionDescriptor }
    }
}
