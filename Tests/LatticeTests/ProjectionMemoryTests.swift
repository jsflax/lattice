import Foundation
import Testing
@testable import Lattice

@Model private final class ProjectedMemoryItem {
    var rank: Int = 0
    var title: String = ""
    var payload: Data = Data()
}

/// Integration tests for the enabling checkpoint; the helper-only foundation
/// remains a separately retained qualification and does not satisfy these.
@Suite("Native Memory Projected Values")
struct ProjectionMemoryTests {
    private func limits(capture: Int = 32 * 1024 * 1024) throws -> ProjectionReadLimits {
        try ProjectionReadLimits(maxRows: 100, maxBytes: 4096, timeout: 5,
                                 maxCaptureBytes: capture)
    }
    private func add(_ db: Lattice, rank: Int, title: String) throws -> ProjectedMemoryItem {
        let row = ProjectedMemoryItem(isolation: nil)
        row.rank = rank; row.title = title; row.payload = Data(repeating: 0x55, count: 64 * 1024)
        try db.add(row)
        return row
    }

    @Test func snapshotSelectsTypedValuesWithoutUnselectedPayload() async throws {
        let db = try Lattice(isolation: nil, ProjectedMemoryItem.self,
                             configuration: .init(storage: .memory()))
        defer { db.close() }
        _ = try add(db, rank: 2, title: "two")
        _ = try add(db, rank: 1, title: "one")
        let projection = try db.objects(ProjectedMemoryItem.self).sortedBy(\.rank)
            .project(\.title, \.rank)
        let values = try await projection.snapshot(limits: limits())
        #expect(values.map(\.0) == ["one", "two"])
        #expect(values.map(\.1) == [1, 2])
    }

    @Test func pausedBatchConsumerKeepsSnapshotWhileLiveWriterChanges() async throws {
        let db = try Lattice(isolation: nil, ProjectedMemoryItem.self,
                             configuration: .init(storage: .memory()))
        defer { db.close() }
        _ = try add(db, rank: 1, title: "one")
        let second = try add(db, rank: 2, title: "two")
        let projection = try db.objects(ProjectedMemoryItem.self).sortedBy(\.rank).project(\.title)
        var iterator = try projection.batches(of: 1, limits: limits()).makeAsyncIterator()
        defer { iterator.cancel() }
        #expect(try await iterator.next() == ["one"])
        second.title = "changed"
        #expect(second.title == "changed")
        #expect(try await iterator.next() == ["two"])
        #expect(try await iterator.next() == nil)
        #expect(try await projection.snapshot(limits: limits()) == ["one", "changed"])
    }

    @Test func namedMemoryProjectionSeesOtherHandlesCommittedValues() async throws {
        let name = "projected-memory-\(UUID().uuidString)"
        let writer = try Lattice(isolation: nil, ProjectedMemoryItem.self,
                                 configuration: .init(storage: .memory(named: name)))
        defer { writer.close() }
        let reader = try Lattice(isolation: nil, ProjectedMemoryItem.self,
                                 configuration: .init(storage: .memory(named: name)))
        defer { reader.close() }
        _ = try add(writer, rank: 7, title: "shared")
        let values = try await reader.objects(ProjectedMemoryItem.self).project(\.title)
            .snapshot(limits: limits())
        #expect(values == ["shared"])
    }

    @Test func captureQuotaMapsToTypedErrorAndLeavesWriterUsable() async throws {
        let db = try Lattice(isolation: nil, ProjectedMemoryItem.self,
                             configuration: .init(storage: .memory()))
        defer { db.close() }
        let row = try add(db, rank: 1, title: "one")
        let projection = try db.objects(ProjectedMemoryItem.self).project(\.title)
        await #expect(throws: ProjectionReadError.captureBudgetExceeded) {
            try await projection.snapshot(limits: limits(capture: 64))
        }
        row.title = "after"
        #expect(try await projection.snapshot(limits: limits()) == ["after"])
    }

    @Test func explicitZeroLimitCompletesAndCancelledPartialSequenceReleases() async throws {
        let db = try Lattice(isolation: nil, ProjectedMemoryItem.self,
                             configuration: .init(storage: .memory()))
        defer { db.close() }
        _ = try add(db, rank: 1, title: "one")
        _ = try add(db, rank: 2, title: "two")
        let projection = try db.objects(ProjectedMemoryItem.self).sortedBy(\.rank).project(\.title)
        #expect(try await projection.snapshot(limit: 0, limits: limits()) == [])
        var iterator = try projection.batches(of: 1, limits: limits()).makeAsyncIterator()
        #expect(try await iterator.next() == ["one"])
        iterator.cancel()
        await #expect(throws: ProjectionReadError.cancelled) { try await iterator.next() }
        #expect(try await projection.snapshot(limits: limits()) == ["one", "two"])
    }
}
