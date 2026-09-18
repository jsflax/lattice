import Foundation
import Testing
@testable import Lattice
#if canImport(MapKit)
import MapKit
#endif

@Model private final class SpatialShapeItem {
    var category: String = ""
    var label: String = ""
    var enabled: Bool = true
    var location: CLLocationCoordinate2D
    var stops: Lattice.List<CLLocationCoordinate2D>
}

@Suite("Spatial query shape parity", .serialized)
@MainActor
struct SpatialQueryShapeTests {
    private func directory() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".build/spatial-shape-fixtures")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    private func add(_ database: Lattice, category: String, label: String,
                     coordinate: Double = 0, enabled: Bool = true) throws -> SpatialShapeItem {
        let item = SpatialShapeItem()
        item.category = category
        item.label = label
        item.enabled = enabled
        item.location = CLLocationCoordinate2D(latitude: coordinate, longitude: coordinate)
        try database.add(item)
        return item
    }

    private func seed(_ database: Lattice) throws {
        try database.withTransaction {
            try add(database, category: "alpha", label: "a")
            try add(database, category: "alpha", label: "a", coordinate: 1)
            try add(database, category: "beta", label: "b", coordinate: 2)
            try add(database, category: "beta", label: "c", coordinate: 3)
            try add(database, category: "outside", label: "z", coordinate: 60)
            try add(database, category: "disabled", label: "x", enabled: false)
        }
    }

    private func bounded(_ database: Lattice) -> TableResults<SpatialShapeItem> {
        database.objects(SpatialShapeItem.self).where { $0.enabled == true }
            .withinBounds(\.location, minLat: -1, maxLat: 5, minLon: -1, maxLon: 5)
    }

    @Test(arguments: [false, true])
    func rowsCountPagesAndProjectionPreserveBothGroupingLevels(fileBacked: Bool) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration: Lattice.Configuration = fileBacked
            ? .init(fileURL: directory.appendingPathComponent("shape.sqlite"))
            : .init(storage: .memory(named: "spatial-shape-\(UUID().uuidString)"))
        configuration.resultsTuning.pageSize = 1
        let database = try Lattice(SpatialShapeItem.self, configuration: configuration)
        defer { database.close() }
        try seed(database)

        let distinct = bounded(database).distinct(by: \.label).sortedBy(\.label)
        #expect(distinct.count == 3)
        #expect(distinct.snapshot().map(\.label) == ["a", "b", "c"])
        #expect(distinct.indices.compactMap { distinct.element(at: $0)?.label } == ["a", "b", "c"])
        #expect(distinct.snapshot(offset: 1).map(\.label) == ["b", "c"])

        let grouped = bounded(database).group(by: \.category).sortedBy(\.category)
        #expect(grouped.count == 2)
        #expect(grouped.snapshot().map(\.category) == ["alpha", "beta"])

        let combined = bounded(database).distinct(by: \.label).group(by: \.category)
            .sortedBy(\.category)
        #expect(combined.count == 2)
        #expect(combined.snapshot().map(\.category) == ["alpha", "beta"])
        #expect(combined.snapshot(limit: 1, offset: 1).map(\.category) == ["beta"])
        combined._fetchLimit = 1
        #expect(combined.count == 1)
        #expect(combined.indices.compactMap { combined.element(at: $0)?.category } == ["alpha"])
        // The visible collection cap does not change explicit snapshot semantics.
        #expect(combined.snapshot().map(\.category) == ["alpha", "beta"])
        if fileBacked {
            let limits = try ProjectionReadLimits(maxRows: 10, maxBytes: 4096, timeout: 10)
            let labels = try await distinct.project(\.label).snapshot(limits: limits)
            #expect(labels == ["a", "b", "c"])
            let categories = try await combined.project(\.category, \.category).snapshot(limits: limits)
            #expect(categories.map { $0.0 } == ["alpha"])
            #expect(categories.map { $0.1 } == ["alpha"])
        }
        #expect(database.backend.lastQueryError() == nil)
    }

    @Test func transactionReadsCountTheirOwnGroupedRowsAndRollbackRestoresMembership() throws {
        let database = try Lattice(SpatialShapeItem.self, configuration: .init(storage: .memory()))
        defer { database.close() }
        try seed(database)
        let results = bounded(database).distinct(by: \.label).group(by: \.category)
            .sortedBy(\.category)
        #expect(results.count == 2)
        struct Rollback: Error {}
        #expect(throws: Rollback.self) {
            try database.withTransaction {
                try add(database, category: "gamma", label: "d")
                #expect(results.count == 3)
                #expect(results.snapshot().map(\.category) == ["alpha", "beta", "gamma"])
                #expect(results.element(at: 2)?.category == "gamma")
                throw Rollback()
            }
        }
        #expect(results.count == 2)
        #expect(results.snapshot().map(\.category) == ["alpha", "beta"])
    }

    @Test func subMicrodegreeBoundsAreNotRoundedIntoAnotherQuery() throws {
        let database = try Lattice(SpatialShapeItem.self, configuration: .init(storage: .memory()))
        defer { database.close() }
        try add(database, category: "origin", label: "zero")
        let excludesOrigin = database.objects(SpatialShapeItem.self)
            .withinBounds(\.location, minLat: -1, maxLat: -0.0000001, minLon: -1, maxLon: 1)
        #expect(excludesOrigin.count == 0)
        #expect(excludesOrigin.snapshot().isEmpty)
        #expect(excludesOrigin.element(at: 0) == nil)
        #expect(bounded(database).count == 1)
        #expect(database.backend.lastQueryError() == nil)
    }

    @Test(arguments: [false, true])
    func attachedScalarAndListQueriesDoNotBorrowEqualLocalIDs(list: Bool) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var local = try Lattice(SpatialShapeItem.self,
            configuration: .init(fileURL: directory.appendingPathComponent("local.sqlite")))
        defer { local.close() }
        let attached = try Lattice(SpatialShapeItem.self,
            configuration: .init(fileURL: directory.appendingPathComponent("attached.sqlite")))
        defer { attached.close() }
        let outside = try add(local, category: "same", label: "local", coordinate: 60)
        let inside = try add(attached, category: "same", label: "attached")
        outside.stops.append(CLLocationCoordinate2D(latitude: 60, longitude: 60))
        inside.stops.append(CLLocationCoordinate2D(latitude: 0, longitude: 0))
        inside.stops.append(CLLocationCoordinate2D(latitude: 1, longitude: 1))
        try #require(outside.primaryKey != nil && outside.primaryKey == inside.primaryKey)
        try local.attach(lattice: attached)
        let results = list
            ? local.objects(SpatialShapeItem.self).withinBounds(\.stops, minLat: -1, maxLat: 5, minLon: -1, maxLon: 5)
            : bounded(local)
        #expect(results.count == 1)
        #expect(results.snapshot().map(\.label) == ["attached"])
        #expect(results.element(at: 0)?.label == "attached")
        let limits = try ProjectionReadLimits(maxRows: 10, maxBytes: 4096, timeout: 10)
        let labels = try await results.project(\.label).snapshot(limits: limits)
        #expect(labels == ["attached"])

        outside.location = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        outside.stops.append(CLLocationCoordinate2D(latitude: 0, longitude: 0))
        #expect(results.count == 2)
        #expect(Set(results.snapshot().map(\.label)) == ["local", "attached"])
        #expect(results.distinct(by: \.category).count == 1)
        #expect(local.backend.lastQueryError() == nil)
    }
}
