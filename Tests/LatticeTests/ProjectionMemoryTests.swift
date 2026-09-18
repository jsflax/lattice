import Foundation
import Dispatch
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
        let diagnostic = ProjectionMemoryPhaseLog.make()
        let definition = try db.objects(ProjectedMemoryItem.self).sortedBy(\.rank).project(\.title)
        let projection = diagnosedMemoryProjection(definition, operation: 0, diagnostic: diagnostic)
        diagnostic?.record(.sequenceBegin, operation: 0)
        var iterator = try projection.batches(of: 1, limits: limits()).makeAsyncIterator()
        diagnostic?.record(.sequenceReturned, operation: 0)
        defer { iterator.cancel() }
        var completed = false
        // Freeze before iterator/store cleanup on a thrown failure. Each span
        // includes instrumentation and any caller/executor admission delay.
        defer { diagnostic?.finish(unwound: !completed) }
        diagnostic?.record(.firstNextBegin, operation: 0)
        #expect(try await iterator.next() == ["one"])
        diagnostic?.record(.firstNextReturned, operation: 0)
        diagnostic?.record(.writeBegin, operation: 0)
        second.title = "changed"
        diagnostic?.record(.writeReturned, operation: 0)
        diagnostic?.record(.readBegin, operation: 0)
        #expect(second.title == "changed")
        diagnostic?.record(.readReturned, operation: 0)
        diagnostic?.record(.secondNextBegin, operation: 0)
        #expect(try await iterator.next() == ["two"])
        diagnostic?.record(.secondNextReturned, operation: 0)
        diagnostic?.record(.finalNextBegin, operation: 0)
        #expect(try await iterator.next() == nil)
        diagnostic?.record(.finalNextReturned, operation: 0)
        let freshProjection = diagnosedMemoryProjection(definition, operation: 1, diagnostic: diagnostic)
        diagnostic?.record(.snapshotBegin, operation: 1)
        #expect(try await freshProjection.snapshot(limits: limits()) == ["one", "changed"])
        diagnostic?.record(.snapshotReturned, operation: 1)
        completed = true
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

/// Test-only scalar evidence. Two operation deadlines and 32 phase records;
/// default off, one failure/unwind emission, no payload/SQL/path capture.
private final class ProjectionMemoryPhaseLog: @unchecked Sendable {
    enum Stage: String {
        case sequenceBegin, sequenceReturned, firstNextBegin, firstNextReturned
        case writeBegin, writeReturned, readBegin, readReturned
        case secondNextBegin, secondNextReturned, finalNextBegin, finalNextReturned
        case snapshotBegin, snapshotReturned, factoryBegin, factoryReturned, factoryThrew
    }
    private struct Point { let stage: Stage; let operation: Int; let uptime: UInt64 }
    private let lock = NSLock()
    private let started = DispatchTime.now().uptimeNanoseconds
    private var points: [Point] = []
    private var deadlines: [UInt64?] = [nil, nil]
    private var dropped = 0
    private var closed = false

    static func make() -> ProjectionMemoryPhaseLog? {
        ProcessInfo.processInfo.environment["LATTICE_OBSERVER_WORKER_DIAGNOSTICS"] == "1"
            ? ProjectionMemoryPhaseLog() : nil
    }

    func record(_ stage: Stage, operation: Int, deadline: UInt64? = nil) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        precondition((0..<2).contains(operation))
        if let deadline { deadlines[operation] = deadline }
        if points.count < 32 { points.append(Point(stage: stage, operation: operation, uptime: now)) }
        else { dropped += 1 }
    }

    func finish(unwound: Bool) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let snapshot = points, cutoffs = deadlines, omitted = dropped
        lock.unlock()
        guard unwound else { return }
        var lines = ["DIAGNOSTIC ProjectionMemoryPhase: test=pausedBatchConsumer clock=dispatch_uptime cap=32 dropped=\(omitted) failure=unwind"]
        for point in snapshot {
            let deadline = cutoffs[point.operation]
            let remaining = deadline.map { point.uptime <= $0 ? String($0 - point.uptime) : "-" + String(point.uptime - $0) } ?? "unknown"
            lines.append("DIAGNOSTIC ProjectionMemoryPhase: stage=\(point.stage.rawValue) operation=\(point.operation) uptime_ns=\(point.uptime) elapsed_ns=\(point.uptime - started) deadline_ns=\(deadline.map { String($0) } ?? "unknown") remaining_ns=\(remaining)")
        }
        let output = lines.joined(separator: "\n")
        precondition(output.utf8.count <= 16 * 1024, "fixed scalar diagnostic output bound")
        print(output)
    }
}

private func diagnosedMemoryProjection<Value: Sendable>(
    _ definition: ProjectedResults<Value>, operation: Int,
    diagnostic: ProjectionMemoryPhaseLog?
) -> ProjectedResults<Value> {
    guard let diagnostic else { return definition }
    return ProjectedResults(descriptor: definition.descriptor, columns: definition.columns,
        executor: definition.executor, factory: { request in
            diagnostic.record(.factoryBegin, operation: operation, deadline: request.deadlineNanoseconds)
            do {
                let result = try definition.factory(request)
                diagnostic.record(.factoryReturned, operation: operation)
                return result
            } catch {
                diagnostic.record(.factoryThrew, operation: operation)
                throw error
            }
        }, decode: definition.decode)
}
