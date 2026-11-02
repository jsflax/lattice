import Foundation
import Testing
@testable import Lattice

@Model final class IntegerAuditWireRow {
    @Indexed var sequence: Int64 = 0
}

@Suite("Integer audit wire", .serialized)
struct IntegerAuditWireTests {
    private static let values: [Int64] = [
        Int64.min, Int64(Int32.min) - 1, Int64(Int32.min), -1, 0, 1,
        Int64(Int32.max), Int64(Int32.max) + 1,
        7_372_800_000_000_018, -7_372_800_000_000_018, Int64.max,
    ]
    private struct Wire: Decodable {
        let kind: Int
        let value: Int64
    }
    private static func integer(_ value: AnyProperty?) throws -> Int64 {
        switch value {
        case .int(let value): return Int64(value)
        case .int64(let value): return value
        default: throw WireError.missingInteger
        }
    }
    private enum WireError: Error { case missingInteger }

    @Test func swiftIntAndRawAuditNumbersUseLosslessCompatibleTags() throws {
        for value in Self.values {
            let native = try #require(Int(exactly: value))
            let raw = try JSONDecoder().decode(AnyProperty.self, from: Data(String(value).utf8))
            for property in [AnyProperty.int(native), raw] {
                let encoded = try JSONEncoder().encode(property)
                let wire = try JSONDecoder().decode(Wire.self, from: encoded)
                #expect(wire.value == value)
                #expect(wire.kind == (Int32(exactly: value) == nil
                    ? AnyProperty.Kind.int64.rawValue : AnyProperty.Kind.int.rawValue))
                let decoded = try JSONDecoder().decode(AnyProperty.self, from: encoded)
                #expect(try Self.integer(decoded) == value)
            }
        }
    }

    @Test func explicitInt64RetainsItsExistingTagAtEveryBoundary() throws {
        for value in Self.values {
            let encoded = try JSONEncoder().encode(AnyProperty.int64(value))
            let wire = try JSONDecoder().decode(Wire.self, from: encoded)
            #expect(wire.kind == AnyProperty.Kind.int64.rawValue)
            #expect(wire.value == value)
        }
    }

    @Test func managedAuditInsertAndUpdatePreserveSigned64AcrossTwoReceivers() throws {
        let source = try Lattice(IntegerAuditWireRow.self, configuration: .init(storage: .memory()))
        defer { source.close() }
        let relay = try Lattice(IntegerAuditWireRow.self, configuration: .init(storage: .memory()))
        defer { relay.close() }
        let target = try Lattice(IntegerAuditWireRow.self, configuration: .init(storage: .memory()))
        defer { target.close() }
        var rows: [IntegerAuditWireRow] = []
        var expected: [UUID: Int64] = [:]
        for value in Self.values {
            let row = IntegerAuditWireRow(); row.sequence = value
            try source.add(row)
            rows.append(row); expected[try #require(row.globalId)] = value
        }

        func assertRows(_ store: Lattice) throws {
            let current = store.objects(IntegerAuditWireRow.self).snapshot()
            #expect(current.count == expected.count)
            for row in current {
                let id = try #require(row.globalId)
                #expect(row.sequence == expected[id])
            }
        }
        func forward(_ rows: [AuditLog], to destination: Lattice) throws {
            try #require(!rows.isEmpty)
            let frame = try JSONEncoder().encode(ServerSentEvent.auditLog(rows))
            let acknowledged = try destination.receive(frame)
            #expect(Set(acknowledged) == Set(rows.compactMap(\.globalId)))
        }

        let inserted = source.eventsAfter(id: 0).snapshot().filter { $0.tableName == "IntegerAuditWireRow" }
        try #require(inserted.count == Self.values.count)
        try forward(source.lateBindNoHistory(inserted), to: relay)
        try forward(relay.lateBindNoHistory(relay.eventsAfter(id: 0).snapshot()), to: target)
        try assertRows(relay); try assertRows(target)
        let sourceCursor = try #require(inserted.last?.primaryKey)
        let relayCursor = try #require(relay.eventsAfter(id: 0).snapshot().last?.primaryKey)

        try source.withTransaction {
            for (row, value) in zip(rows, Self.values.reversed()) {
                row.sequence = value
                expected[try #require(row.globalId)] = value
            }
        }
        let updates = source.eventsAfter(id: sourceCursor).snapshot()
        try #require(!updates.isEmpty && updates.allSatisfy { $0.operation == .update })
        try forward(source.lateBindNoHistory(updates), to: relay)
        let relayed = relay.eventsAfter(id: relayCursor).snapshot()
        try forward(relay.lateBindNoHistory(relayed), to: target)
        try assertRows(relay); try assertRows(target)
        for event in relayed {
            let id = try #require(event.globalRowId)
            #expect(try Self.integer(event.changedFields["sequence"]) == expected[id])
        }
    }
}
