import Foundation
import Testing
@testable import Lattice

private protocol VirtualRoutePlace: VirtualModel {
    var name: String { get }
    var country: String { get }
    var rank: Int { get }
}

@Model private final class VirtualRouteCafe: VirtualRoutePlace {
    var name: String = ""
    var country: String = ""
    var rank: Int = 0
}

@Model private final class VirtualRouteMuseum: VirtualRoutePlace {
    var name: String = ""
    var country: String = ""
    var rank: Int = 0
}

@Suite("Virtual Results Physical Routes")
struct VirtualResultsRouteTests {
    // The TaskLocal selects the two real implementations on the same host;
    // no fake row backend can conceal a union's logical/physical distinction.
    @Test(arguments: [false, true])
    func ordinaryMainModelsHydrateOnBothPaths(forceCompat: Bool) throws {
        try withFixture { localURL, _ in
            let local = try Lattice(isolation: nil, VirtualRouteCafe.self, VirtualRouteMuseum.self,
                                    configuration: .init(fileURL: localURL))
            defer { local.close() }
            let cafe = makeCafe("Cafe", rank: 1)
            let museum = makeMuseum("Museum", rank: 2)
            try local.add(cafe)
            try local.add(museum)

            try Lattice.$_forceCompatPaths.withValue(forceCompat) {
                let results = local.objects(VirtualRoutePlace.self)
                    .sortedBy(\.rank, order: .forward)
                assertImplementation(results, forceCompat: forceCompat)
                let rows = results.snapshot()
                try #require(rows.count == 2)
                let hydratedCafe = try #require(rows[0] as? VirtualRouteCafe)
                let hydratedMuseum = try #require(rows[1] as? VirtualRouteMuseum)
                #expect(hydratedCafe.globalId == cafe.globalId)
                #expect(hydratedMuseum.globalId == museum.globalId)
                #expect(hydratedCafe.asRefType.logicalModelTableName == VirtualRouteCafe.entityName)
                #expect(hydratedMuseum.asRefType.logicalModelTableName == VirtualRouteMuseum.entityName)
                #expect(rows.map(\.name) == ["Cafe", "Museum"])
            }
        }
    }

    @Test(arguments: [false, true])
    func attachedOnlyTypeKeepsFilteringPaginationAndPhysicalWrites(forceCompat: Bool) throws {
        try withFixture { localURL, attachedURL in
            try readAttachedOnly(localURL: localURL, attachedURL: attachedURL, forceCompat: forceCompat)

            // Reopen after all query/writer handles close: the mutation must
            // have reached the attached file, not just a cached model.
            let attached = try Lattice(isolation: nil, VirtualRouteMuseum.self,
                                       configuration: .init(fileURL: attachedURL))
            defer { attached.close() }
            #expect(attached.objects(VirtualRouteMuseum.self).sortedBy(\.rank)
                .snapshot().map(\.name) == ["Attached changed", "Hidden", "Later"])
            let local = try Lattice(isolation: nil, VirtualRouteCafe.self,
                                    configuration: .init(fileURL: localURL))
            defer { local.close() }
            #expect(local.objects(VirtualRouteCafe.self).first?.name == "Local")
        }
    }

    private func readAttachedOnly(localURL: URL, attachedURL: URL, forceCompat: Bool) throws {
        var local = try Lattice(isolation: nil, VirtualRouteCafe.self,
                                configuration: .init(fileURL: localURL))
        defer { local.close() }
        let attached = try Lattice(isolation: nil, VirtualRouteMuseum.self,
                                   configuration: .init(fileURL: attachedURL))
        defer { attached.close() }
        let cafe = makeCafe("Local", rank: 1)
        let museum = makeMuseum("Attached", rank: 2)
        try local.add(cafe)
        try attached.add(museum)
        try attached.add(makeMuseum("Hidden", rank: 3, country: "Other"))
        try attached.add(makeMuseum("Later", rank: 4))
        try #require(cafe.primaryKey != nil)
        try #require(cafe.primaryKey == museum.primaryKey)
        try local.attach(lattice: attached)

        try Lattice.$_forceCompatPaths.withValue(forceCompat) {
            var results = local.objects(VirtualRoutePlace.self)
            results = results.where { $0.country == "Match" }.sortedBy(\.rank, order: .forward)
            assertImplementation(results, forceCompat: forceCompat)
            #expect(results.count == 3)
            #expect(results.snapshot().map(\.name) == ["Local", "Attached", "Later"])
            let page = results.snapshot(limit: 1, offset: 1)
            try #require(page.count == 1)
            let hydrated = try #require(page[0] as? VirtualRouteMuseum)
            #expect(hydrated.globalId == museum.globalId)
            #expect(hydrated.asRefType.logicalModelTableName == VirtualRouteMuseum.entityName)
            #expect(hydrated.asRefType.tableName != hydrated.asRefType.logicalModelTableName)
            hydrated.name = "Attached changed"
            #expect(cafe.name == "Local")
            #expect(results.snapshot(limit: 1, offset: 2).first?.name == "Later")
        }
    }

    @Test(arguments: [false, true])
    func replicasWithEqualLocalAndGlobalIDsRemainDistinctPhysicalRows(forceCompat: Bool) throws {
        try withFixture { localURL, attachedURL in
            try readReplicas(localURL: localURL, attachedURL: attachedURL, forceCompat: forceCompat)

            let local = try Lattice(isolation: nil, VirtualRouteCafe.self, VirtualRouteMuseum.self,
                                    configuration: .init(fileURL: localURL))
            defer { local.close() }
            let attached = try Lattice(isolation: nil, VirtualRouteMuseum.self,
                                       configuration: .init(fileURL: attachedURL))
            defer { attached.close() }
            #expect(local.objects(VirtualRouteMuseum.self).first?.name == "Main museum")
            #expect(attached.objects(VirtualRouteMuseum.self).first?.name == "Replica changed")
            #expect(local.objects(VirtualRouteCafe.self).first?.name == "Cafe")
        }
    }

    private func readReplicas(localURL: URL, attachedURL: URL, forceCompat: Bool) throws {
        var local = try Lattice(isolation: nil, VirtualRouteCafe.self, VirtualRouteMuseum.self,
                                configuration: .init(fileURL: localURL))
        defer { local.close() }
        let attached = try Lattice(isolation: nil, VirtualRouteMuseum.self,
                                   configuration: .init(fileURL: attachedURL))
        defer { attached.close() }
        let sharedID = UUID()
        let original = makeMuseum("Main museum", rank: 1)
        let replica = makeMuseum("Replica", rank: 2)
        try local.add(makeCafe("Cafe", rank: 0))
        try local.add(original, preservingGlobalId: sharedID)
        try attached.add(replica, preservingGlobalId: sharedID)
        try #require(original.primaryKey != nil)
        try #require(original.primaryKey == replica.primaryKey)
        try local.attach(lattice: attached)

        try Lattice.$_forceCompatPaths.withValue(forceCompat) {
            var results = local.objects(VirtualRoutePlace.self)
            results = results.where { $0.country == "Match" }.sortedBy(\.rank, order: .forward)
            assertImplementation(results, forceCompat: forceCompat)
            #expect(results.count == 3)
            let rows = results.snapshot()
            try #require(rows.count == 3)
            #expect(rows.map(\.name) == ["Cafe", "Main museum", "Replica"])
            let hydratedMain = try #require(rows[1] as? VirtualRouteMuseum)
            let hydratedReplica = try #require(rows[2] as? VirtualRouteMuseum)
            #expect(hydratedMain.globalId == sharedID)
            #expect(hydratedReplica.globalId == sharedID)
            #expect(hydratedMain.primaryKey == hydratedReplica.primaryKey)
            #expect(hydratedMain.asRefType.logicalModelTableName == VirtualRouteMuseum.entityName)
            #expect(hydratedReplica.asRefType.logicalModelTableName == VirtualRouteMuseum.entityName)
            #expect(hydratedMain.asRefType.tableName != hydratedReplica.asRefType.tableName)
            #expect(hydratedMain !== hydratedReplica)
            #expect(results.snapshot(limit: 1, offset: 1).first?.name == "Main museum")
            #expect(results.snapshot(limit: 1, offset: 2).first?.name == "Replica")
            hydratedReplica.name = "Replica changed"
            #expect(hydratedMain.name == "Main museum")
            #expect(results.snapshot(limit: 1, offset: 2).first?.name == "Replica changed")
        }
    }

    private func assertImplementation(_ results: any VirtualResults<VirtualRoutePlace>, forceCompat: Bool) {
        let name = String(describing: type(of: results))
        #expect(name.hasPrefix(forceCompat ? "_VirtualResultsCompat<" : "_VirtualResults<"))
    }

    private func makeCafe(_ name: String, rank: Int) -> VirtualRouteCafe {
        let row = VirtualRouteCafe(isolation: nil)
        row.name = name
        row.country = "Match"
        row.rank = rank
        return row
    }

    private func makeMuseum(_ name: String, rank: Int, country: String = "Match") -> VirtualRouteMuseum {
        let row = VirtualRouteMuseum(isolation: nil)
        row.name = name
        row.country = country
        row.rank = rank
        return row
    }

    private func withFixture(_ body: (URL, URL) throws -> Void) throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = packageRoot.appendingPathComponent(".build/virtual-route-fixtures")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A dotted alias must remain native route metadata; a Swift split(".")
        // discriminator would be incorrect for physical routes of this shape.
        try body(directory.appendingPathComponent("main.sqlite"),
                 directory.appendingPathComponent("attached.part.sqlite"))
    }
}
