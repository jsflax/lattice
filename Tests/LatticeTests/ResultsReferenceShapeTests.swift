import Foundation
import Testing
@testable import Lattice
#if canImport(MapKit)
import MapKit
#endif

@Model private final class ReferenceShapeItem {
    var category: String = ""
    var label: String = ""
    var rank: Int = 0
    var enabled: Bool = true
    var location: CLLocationCoordinate2D
}

private struct ReferenceShapeRead: Sendable, Equatable {
    let count: Int
    let categories: [String]
    let labels: [String]
    let snapshotRanks: [Int]
    let visibleRanks: [Int]

    init(_ results: TableResults<ReferenceShapeItem>) {
        count = results.count
        let snapshot = results.snapshot()
        categories = snapshot.map(\.category)
        labels = snapshot.map(\.label)
        snapshotRanks = snapshot.map(\.rank)
        // fetchLimit caps the collection's visible range, not an explicit
        // snapshot(). Preserve that existing distinction through the reference.
        visibleRanks = results.indices.compactMap { results.element(at: $0)?.rank }
    }
}

private actor ReferenceShapeReader {
    func read(_ reference: ResultsThreadSafeReference<TableResults<ReferenceShapeItem>>,
              on database: LatticeThreadSafeReference) throws -> ReferenceShapeRead {
        let lattice = try #require(database.resolve())
        defer { lattice.close() }
        #expect(lattice.isolation.map(ObjectIdentifier.init) == ObjectIdentifier(self))
        let results = try #require(reference.resolve(on: lattice))
        return ReferenceShapeRead(results)
    }
}

@Suite("Results Reference Shape Tests")
struct ResultsReferenceShapeTests {
    private func seededLattice(isolation: isolated (any Actor)? = #isolation) throws -> Lattice {
        let lattice = try Lattice(ReferenceShapeItem.self, configuration: .init(
            storage: .memory(named: "reference-shape-\(UUID().uuidString)")))
        let rows: [(String, String, Int, Bool, Double)] = [
            ("alpha", "a", 10, true, 0),
            ("alpha", "a", 20, true, 1),
            ("beta", "b", 30, true, 2),
            ("beta", "c", 40, true, 3),
            ("outside", "z", 50, true, 60),
            ("disabled", "x", 60, false, 0),
        ]
        for (category, label, rank, enabled, coordinate) in rows {
            let item = ReferenceShapeItem()
            item.category = category
            item.label = label
            item.rank = rank
            item.enabled = enabled
            item.location = CLLocationCoordinate2D(latitude: coordinate, longitude: coordinate)
            try lattice.add(item)
        }
        return lattice
    }

    @MainActor @Test func groupingAndDistinctnessSurviveActorRoundTrip() async throws {
        let lattice = try seededLattice()
        defer { lattice.close() }
        let filtered = lattice.objects(ReferenceShapeItem.self).where { $0.enabled == true }
        let grouped = filtered.group(by: \.category).sortedBy(\.category, order: .forward)
        let distinct = filtered.distinct(by: \.label).sortedBy(\.label, order: .forward)
        let combined = filtered.distinct(by: \.label).group(by: \.category)
            .sortedBy(\.category, order: .forward)
        let reader = ReferenceShapeReader()

        let groupedRead = try await reader.read(grouped.sendableReference, on: lattice.sendableReference)
        #expect(groupedRead.categories == ["alpha", "beta", "outside"])
        #expect(groupedRead.count == 3)
        #expect(groupedRead == ReferenceShapeRead(grouped))

        let distinctRead = try await reader.read(distinct.sendableReference, on: lattice.sendableReference)
        #expect(distinctRead.labels == ["a", "b", "c", "z"])
        #expect(distinctRead.count == 4)
        #expect(distinctRead == ReferenceShapeRead(distinct))

        let combinedRead = try await reader.read(combined.sendableReference, on: lattice.sendableReference)
        #expect(combinedRead.categories == ["alpha", "beta", "outside"])
        #expect(combinedRead.count == 3)
        #expect(combinedRead == ReferenceShapeRead(combined))
    }

    @MainActor @Test func boundsSortPredicateAndCapSurviveActorRoundTrip() async throws {
        let lattice = try seededLattice()
        defer { lattice.close() }
        let results = lattice.objects(ReferenceShapeItem.self)
            .where { $0.enabled == true }
            .withinBounds(\.location, minLat: -1, maxLat: 5, minLon: -1, maxLon: 5)
            .sortedBy(\.rank, order: .reverse)
        results._fetchLimit = 3
        let expected = ReferenceShapeRead(results)
        let reader = ReferenceShapeReader()
        let read = try await reader.read(results.sendableReference, on: lattice.sendableReference)

        #expect(read == expected)
        #expect(read.count == 3)
        #expect(read.visibleRanks == [40, 30, 20])
        #expect(read.snapshotRanks == [40, 30, 20, 10])
    }

    @MainActor @Test func fetchCapIsCapturedWhenReferenceIsCreated() async throws {
        let lattice = try seededLattice()
        defer { lattice.close() }
        let results = lattice.objects(ReferenceShapeItem.self)
            .where { $0.enabled == true }
            .sortedBy(\.rank, order: .forward)
        results._fetchLimit = 2
        let reference = results.sendableReference
        results._fetchLimit = 1
        let database = lattice.sendableReference

        // Exercise resolution without actor isolation as well as the custom
        // actor path above. Only references and copied values cross the boundary.
        let read = try await Task.detached {
            let receivingLattice = try #require(database.resolve())
            defer { receivingLattice.close() }
            #expect(receivingLattice.isolation == nil)
            let received = try #require(reference.resolve(on: receivingLattice))
            return ReferenceShapeRead(received)
        }.value

        #expect(results.count == 1)
        #expect(read.count == 2)
        #expect(read.visibleRanks == [10, 20])
        #expect(read.snapshotRanks == [10, 20, 30, 40, 50])
    }
}
