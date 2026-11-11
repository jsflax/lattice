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
        let oversized = try BoundedAuditFrame.encode(start: 0, maxCount: 2,
            maximumBytes: single.data.count - 1) { rows[$0] }
        #expect(oversized.data.count == single.data.count)
        #expect(oversized.count == 1 && oversized.scannedCount == 1)
        #expect(oversized.lastID == rows[0].primaryKey && oversized.scannedLastID == rows[0].primaryKey)
        #expect(oversized.ids == [rows[0].globalId])
        let decoded = try JSONDecoder().decode(ServerSentEvent.self, from: exact.data)
        guard case let .auditLog(logs) = decoded else { Issue.record("Wrong wire kind"); return }
        #expect(logs.map(\.globalId) == [rows[0].globalId])
        let oversizedDecoded = try JSONDecoder().decode(ServerSentEvent.self, from: oversized.data)
        guard case let .auditLog(oversizedLogs) = oversizedDecoded else { Issue.record("Wrong wire kind"); return }
        #expect(oversizedLogs.map(\.globalId) == [rows[0].globalId])
        #expect(oversizedLogs.first?.changedFields["payload"]?.stringValue == String(repeating: "ab", count: 128))
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

    @Test func oversizedMiddleRowTravelsAloneAndPreservesFollowingRows() throws {
        let rows = [row(0, bytes: 16), row(1, bytes: 4096), row(2, bytes: 16)]
        let first = try BoundedAuditFrame.encode(start: 0, maxCount: rows.count, maximumBytes: 1024) { rows[$0] }
        #expect(first.count == 1 && first.scannedCount == 1 && first.data.count <= 1024)
        let middle = try BoundedAuditFrame.encode(start: first.scannedCount,
            maxCount: rows.count - first.scannedCount, maximumBytes: 1024) { rows[$0] }
        #expect(middle.count == 1 && middle.scannedCount == 1 && middle.data.count > 1024)
        let offset = first.scannedCount + middle.scannedCount
        let last = try BoundedAuditFrame.encode(start: offset,
            maxCount: rows.count - offset, maximumBytes: 1024) { rows[$0] }
        #expect(last.count == 1 && last.scannedCount == 1 && last.data.count <= 1024)
        var received: [UUID?] = []
        for (frame, expectedRow) in zip([first, middle, last], rows) {
            let decoded = try JSONDecoder().decode(ServerSentEvent.self, from: frame.data)
            guard case let .auditLog(logs) = decoded else { Issue.record("Wrong wire kind"); return }
            #expect(logs.count == 1)
            let payload = try #require(logs.first?.changedFields["payload"]?.stringValue)
            let expectedPayload = try #require(expectedRow.changedFields["payload"]?.stringValue)
            #expect(payload == expectedPayload)
            #expect(frame.lastID == expectedRow.primaryKey && frame.scannedLastID == expectedRow.primaryKey)
            #expect(frame.ids == [expectedRow.globalId])
            received.append(contentsOf: logs.map(\.globalId))
        }
        #expect(received == rows.map(\.globalId))
    }

    @Test func coreHardLimitRowTravelsAloneWithEnvelopeHeadroom() throws {
        // LatticeCore's per-row hard limit. Replace with its bridge accessor
        // when the pinned core exports it; this pin currently exposes only the
        // 4 MiB page budget. The relay frame also includes its own envelope.
        let coreMaximumEncodedAuditRowBytes = 8 * 1024 * 1024
        let large = row(0, bytes: 0)
        let encoder = JSONEncoder()
        let emptyRowBytes = try encoder.encode(large).count
        let payloadBytes = coreMaximumEncodedAuditRowBytes - emptyRowBytes
        try #require(payloadBytes > 0)
        large.changedFields = ["payload": .string(String(repeating: "x", count: payloadBytes))]
        let encodedRowBytes = try encoder.encode(large).count
        try #require(encodedRowBytes == coreMaximumEncodedAuditRowBytes)

        let rows = [large, row(1, bytes: 16)]
        let frame = try BoundedAuditFrame.encode(start: 0, maxCount: rows.count) { rows[$0] }
        #expect(frame.count == 1 && frame.scannedCount == 1)
        #expect(frame.data.count > coreMaximumEncodedAuditRowBytes)
        #expect(frame.ids == [large.globalId])
        #expect(frame.lastID == large.primaryKey && frame.scannedLastID == large.primaryKey)
        let decoded = try JSONDecoder().decode(ServerSentEvent.self, from: frame.data)
        guard case let .auditLog(logs) = decoded else { Issue.record("Wrong wire kind"); return }
        let payload = try #require(logs.first?.changedFields["payload"]?.stringValue)
        #expect(logs.count == 1 && payload == String(repeating: "x", count: payloadBytes))

        let next = try BoundedAuditFrame.encode(start: frame.scannedCount,
            maxCount: rows.count - frame.scannedCount) { rows[$0] }
        #expect(next.count == 1 && next.scannedCount == 1)
        #expect(next.ids == [rows[1].globalId])
        #expect(next.data.count <= Lattice.maximumEncodedSyncMessageBytes)
    }

    @Test func oversizedFirstVisibleRowConsumesOnlyItsScannedPrefix() throws {
        let rows = [row(0, bytes: 16), row(1, bytes: 4096), row(2, bytes: 16)]
        rows[0].tableName = "PrivateFence"
        let first = try BoundedAuditFrame.encode(start: 0, maxCount: rows.count, maximumBytes: 1024,
            including: { $0.tableName != "PrivateFence" }) { rows[$0] }
        #expect(first.count == 1 && first.scannedCount == 2 && first.data.count > 1024)
        #expect(first.ids == [rows[1].globalId])
        #expect(first.lastID == rows[1].primaryKey && first.scannedLastID == rows[1].primaryKey)
        let next = try BoundedAuditFrame.encode(start: first.scannedCount,
            maxCount: rows.count - first.scannedCount, maximumBytes: 1024) { rows[$0] }
        #expect(next.ids == [rows[2].globalId] && next.scannedCount == 1)
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
