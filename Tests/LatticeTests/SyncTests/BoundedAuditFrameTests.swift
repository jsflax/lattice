import Foundation
import Testing
@testable import Lattice
@testable import LatticeServerKit

@Suite("Encoded audit byte boundaries", .timeLimit(.minutes(1)))
struct BoundedAuditFrameTests {
    private func row(_ ordinal: Int, bytes: Int, binary: Bool = false) -> AuditLog {
        let row = AuditLog()
        row.globalId = UUID()
        row.tableName = "AssetChunk"
        row.operation = .insert
        row.rowId = Int64(ordinal + 1)
        row.primaryKey = Int64(ordinal + 1)
        row.globalRowId = UUID()
        row.changedFields = ["payload": binary ? .data(Data(repeating: 0x35, count: bytes))
                                             : .string(String(repeating: "ab", count: bytes))]
        row.changedFieldsNames = ["payload"]
        row.timestamp = Date(timeIntervalSince1970: 0)
        row.isFromRemote = false
        return row
    }

    @Test func exactBoundaryIncludesEnvelopeAndNoUnsentRow() throws {
        let rows = [row(0, bytes: 128), row(1, bytes: 128)]
        let single = try BoundedAuditFrame.encode(start: 0, maxCount: 1) { rows[$0] }
        let exact = try BoundedAuditFrame.encode(start: 0, maxCount: 2, maximumBytes: single.data.count) { rows[$0] }
        #expect(exact.count == 1 && exact.data.count == single.data.count && exact.lastID == rows[0].primaryKey)
        #expect(throws: BoundedAuditFrame.Failure.self) {
            try BoundedAuditFrame.encode(start: 0, maxCount: 1, maximumBytes: single.data.count - 1) { rows[$0] }
        }
        let decoded = try JSONDecoder().decode(ServerSentEvent.self, from: exact.data)
        guard case let .auditLog(logs) = decoded else { Issue.record("Wrong wire kind"); return }
        #expect(logs.map(\.globalId) == [rows[0].globalId])
    }

    @Test func largeSupportedChunksSplitWithoutDroppingOrDuplicating() throws {
        let rows = (0..<31).map { row($0, bytes: 256 * 1024, binary: true) }
        var offset = 0, frames = 0
        var received: [UUID?] = []
        while offset < rows.count {
            let frame = try BoundedAuditFrame.encode(start: offset, maxCount: rows.count - offset) { rows[$0] }
            try #require(frame.count > 0)
            #expect(frame.data.count <= Lattice.maximumEncodedSyncMessageBytes)
            guard case let .auditLog(logs) = try JSONDecoder().decode(ServerSentEvent.self, from: frame.data) else {
                Issue.record("Wrong wire kind"); return
            }
            received.append(contentsOf: logs.map(\.globalId))
            for log in logs {
                guard let value = log.changedFields["payload"], case let .data(payload) = value else {
                    Issue.record("Binary payload lost its type"); return
                }
                #expect(payload == Data(repeating: 0x35, count: 256 * 1024))
            }
            offset += frame.count
            #expect(frame.lastID == rows[offset - 1].primaryKey)
            frames += 1
        }
        #expect(received == rows.map(\.globalId))
        #expect(frames >= 3)
    }

    @Test func oversizedMiddleRowPreservesPrefixAndFailsAtSameCursor() throws {
        let rows = [row(0, bytes: 16), row(1, bytes: 4096), row(2, bytes: 16)]
        let first = try BoundedAuditFrame.encode(start: 0, maxCount: rows.count, maximumBytes: 1024) { rows[$0] }
        #expect(first.count == 1)
        #expect(throws: BoundedAuditFrame.Failure.self) {
            try BoundedAuditFrame.encode(start: first.count, maxCount: rows.count - first.count, maximumBytes: 1024) { rows[$0] }
        }
    }

    @Test func rowLoadFailureProducesNoSuccessfulPartialFrame() throws {
        let first = row(0, bytes: 16)
        #expect(throws: BoundedAuditFrame.Failure.self) {
            try BoundedAuditFrame.encode(start: 0, maxCount: 2) { index in
                guard index == 0 else { throw BoundedAuditFrame.Failure.missingRow }
                return first
            }
        }
    }

    @Test func endOfTailNeedsNoPriorCountAndDoesNotReadBeyondIt() throws {
        let rows = [row(0, bytes: 16), row(1, bytes: 32)]
        var reads: [Int] = []
        let frame = try BoundedAuditFrame.encode(start: 0, maxCount: 256) { index in
            reads.append(index)
            return index < rows.count ? rows[index] : nil
        }
        #expect(frame.count == rows.count && frame.ids == rows.map(\.globalId))
        #expect(reads == [0, 1, 2])
        var emptyReads = 0
        let empty = try BoundedAuditFrame.encode(start: 0, maxCount: 256) { _ in
            emptyReads += 1
            return nil
        }
        #expect(empty.count == 0 && empty.lastID == nil && empty.ids.isEmpty && emptyReads == 1)
        guard case let .auditLog(logs) = try JSONDecoder().decode(ServerSentEvent.self, from: empty.data) else {
            Issue.record("Wrong empty wire kind"); return
        }
        #expect(logs.isEmpty)
    }

    @Test func queryFailureAfterValidPrefixNeverBecomesSuccessfulEndOfTail() throws {
        let first = row(0, bytes: 16)
        var diagnosticCalled = false
        #expect(throws: BoundedAuditFrame.Failure.self) {
            try BoundedAuditFrame.encode(start: 0, maxCount: 256,
                didPrepare: { _ in diagnosticCalled = true }) { index in
                    if index == 0 { return first }
                    throw BoundedAuditFrame.Failure.queryFailed
                }
        }
        #expect(!diagnosticCalled)
    }
    @Test func filteredRowsAdvanceOnlyScannedPrefixWithinByteBound() throws {
        let rows = [row(0, bytes: 128), row(1, bytes: 4096), row(2, bytes: 128)]
        rows[1].tableName = "PrivateFence"
        let single = try BoundedAuditFrame.encode(start: 0, maxCount: 1) { rows[$0] }
        let first = try BoundedAuditFrame.encode(start: 0, maxCount: 3, maximumBytes: single.data.count,
            including: { $0.tableName != "PrivateFence" }) { rows[$0] }
        #expect(first.count == 1 && first.scannedCount == 2)
        #expect(first.lastID == rows[0].primaryKey && first.scannedLastID == rows[1].primaryKey)
        #expect(first.data.count <= single.data.count) // excluded large row was never encoded
        guard case let .auditLog(visible) = try JSONDecoder().decode(ServerSentEvent.self, from: first.data) else {
            Issue.record("Wrong filtered wire kind"); return
        }
        #expect(visible.map(\.globalId) == [rows[0].globalId])
        let next = try BoundedAuditFrame.encode(start: first.scannedCount, maxCount: 1,
            maximumBytes: single.data.count, including: { $0.tableName != "PrivateFence" }) { rows[$0] }
        #expect(next.ids == [rows[2].globalId] && next.scannedCount == 1)
        let hidden = try BoundedAuditFrame.encode(start: 1, maxCount: 1, maximumBytes: 128,
            including: { _ in false }) { rows[$0] }
        #expect(hidden.count == 0 && hidden.lastID == nil)
        #expect(hidden.scannedCount == 1 && hidden.scannedLastID == rows[1].primaryKey)
        #expect(throws: BoundedAuditFrame.Failure.self) {
            try BoundedAuditFrame.encode(start: 0, maxCount: 2, including: { _ in false }) { index in
                if index == 0 { return rows[0] }
                throw BoundedAuditFrame.Failure.queryFailed
            }
        }
    }

}
