import Foundation
import Testing
@testable import Lattice
@testable import LatticeServerKit

@Model private final class ObserverWireImageRow {
    var text: String = ""
    @NoHistory var live: String = ""
}

@Suite("Observer push query images", .serialized)
final class ObserverPushWireImageTests: BaseTest {
    private func normalized(_ data: Data) throws -> Data {
        try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: data), options: .sortedKeys)
    }
    private func logs(_ data: Data) throws -> [AuditLog] {
        let event = try JSONDecoder().decode(ServerSentEvent.self, from: data)
        guard case .auditLog(let rows) = event else {
            throw RelayAuditImageError.invalidValue("wire kind")
        }
        return rows
    }
    private func encode(_ rows: [AuditLog]) throws -> Data {
        try JSONEncoder().encode(ServerSentEvent.auditLog(rows))
    }
    private func expectStoredNoHistoryIsStillOmitted(_ db: Lattice) {
        let updates = db.eventsAfter(id: 0).snapshot().filter { $0.operation == .update }
        #expect(!updates.isEmpty)
        for row in updates {
            #expect(row.changedFieldsNames?.contains("live") == true)
            if let value = row.changedFields["live"], case .null = value {} else {
                Issue.record("Stored history must retain the original null NoHistory value")
            }
        }
    }

    @Test func exactWireShapeAndCursorNeedNoSQLAfterImageCapture() throws {
        let db = try testLattice(ObserverWireImageRow.self)
        for index in 0..<2 {
            let row = ObserverWireImageRow()
            row.text = "escaped \" \\ \n 🐦 " + String(repeating: "x", count: 2048) + String(index)
            row.live = "initial-\(index)"
            try db.add(row)
        }
        _ = db.eventsAfter(id: 0).snapshot(limit: 2) // Warm the same generation path.
        let ordinaryStart = Lattice.threadSQLStatementCount
        let ordinary = db.eventsAfter(id: 0).snapshot(limit: 2)
        let ordinarySQL = Lattice.threadSQLStatementCount - ordinaryStart
        let imageStart = Lattice.threadSQLStatementCount
        let page = try db._relayAuditImagePage(after: 0, limit: 2)
        let imageSQL = Lattice.threadSQLStatementCount - imageStart
        #expect(imageSQL == ordinarySQL, "Image capture must add no SQL to the same snapshot query")
        #expect(ordinary.count == 2)
        #expect(ordinary.allSatisfy { !$0.isMaterialized })
        let liveStart = Lattice.threadSQLStatementCount
        let baseline = try encode(db.lateBindNoHistory(ordinary))
        let actualLiveReads = Lattice.threadSQLStatementCount - liveStart
        #expect(actualLiveReads > 0, "The existing live encoder must exercise genuine SQL")

        let encodeStart = Lattice.threadSQLStatementCount
        let bound = db.lateBindNoHistory(page)
        let bytes = try encode(bound)
        let last = bound.last?.primaryKey
        let ids = bound.map { $0.globalId }
        let encodingSQL = Lattice.threadSQLStatementCount - encodeStart
        #expect(encodingSQL == 0, "Encoding/cursor/IDs must use only the actual captured image")
        #expect(page.count == 2)
        #expect(last == ordinary.last?.primaryKey)
        #expect(ids == ordinary.map { $0.globalId })
        #expect(try normalized(bytes) == normalized(baseline))
        #expect(ordinary.allSatisfy { !$0.isMaterialized }, "Public live defaults must stay unchanged")
        let decoded = try logs(bytes)
        #expect(decoded.map { $0.changedFields["text"]?.stringValue } == ordinary.map { $0.changedFields["text"]?.stringValue })
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let encodedRows = try #require(object["auditLog"] as? [[String: Any]])
        for (entry, id) in zip(encodedRows, ids) {
            #expect(entry["globalId"] as? String == id?.uuidString.lowercased())
        }
        let cursor = try #require(last)
        #expect(try db._relayAuditImagePage(after: cursor, limit: 2).isEmpty)
    }

    @Test func bookkeepingUsesOneImageWhileOrdinaryModelsStayLiveAndReceiveOwnsItsFlags() throws {
        let db = try testLattice(ObserverWireImageRow.self)
        let row = ObserverWireImageRow(); row.text = "original"; row.live = "initial"
        try db.add(row)
        let ordinary = try #require(db.eventsAfter(id: 0).snapshot(limit: 1).first)
        let page = try db._relayAuditImagePage(after: 0, limit: 1)
        #expect(page.first?.isSynchronized == false)
        ordinary.isSynchronized = true
        #expect(ordinary.isSynchronized)
        #expect(!ordinary.isMaterialized)
        #expect(page.first?.isSynchronized == false, "Wire bookkeeping is the single query image")
        let bytes = try encode(page)
        #expect(try logs(bytes).first?.isSynchronized == false)
        let destination = try testLattice(ObserverWireImageRow.self)
        #expect(try destination.receive(bytes).count == 1)
        #expect(destination.objects(ObserverWireImageRow.self).first?.text == "original")
        let received = try #require(destination.eventsAfter(id: 0).snapshot(limit: 1).first)
        #expect(received.isFromRemote)
        #expect(received.isSynchronized, "The actual global receiver derives its own flags")
    }

    @Test func noHistoryReadsCurrentValueAfterTheCapturedImageAndDoesNotRewriteStoredHistory() throws {
        let db = try testLattice(ObserverWireImageRow.self)
        let row = ObserverWireImageRow(); row.text = "ordinary"; row.live = "v1"
        try db.add(row)
        db.transaction { row.live = "v2" }
        let page = try db._relayAuditImagePage(after: 0, limit: 8)
        #expect(page.filter { $0.operation == .update }.count == 1)
        db.transaction { row.live = "v3" }
        let bindingStart = Lattice.threadSQLStatementCount
        let bound = db.lateBindNoHistory(page)
        let bindingSQL = Lattice.threadSQLStatementCount - bindingStart
        #expect(bindingSQL > 0, "Only the intended current-model NoHistory lookup remains live")
        let encodingStart = Lattice.threadSQLStatementCount
        let bytes = try encode(bound)
        let encodingSQL = Lattice.threadSQLStatementCount - encodingStart
        #expect(encodingSQL == 0)
        let updates = try logs(bytes).filter { $0.operation == .update }
        #expect(updates.count == 1)
        #expect(updates.first?.changedFields["live"]?.stringValue == "v3")
        #expect(bound.map { $0.primaryKey } == page.map { $0.primaryKey })
        expectStoredNoHistoryIsStillOmitted(db)
    }

    @Test func noHistoryGoneRowDropsOnlyTheWireValueAndPreservesCursor() throws {
        let db = try testLattice(ObserverWireImageRow.self)
        let row = ObserverWireImageRow(); row.text = "ordinary"; row.live = "v1"
        try db.add(row)
        db.transaction { row.live = "v2" }
        let page = try db._relayAuditImagePage(after: 0, limit: 8)
        db.delete(ObserverWireImageRow.self)
        let bound = db.lateBindNoHistory(page)
        let encodingStart = Lattice.threadSQLStatementCount
        let bytes = try encode(bound)
        let encodingSQL = Lattice.threadSQLStatementCount - encodingStart
        #expect(encodingSQL == 0)
        let updates = try logs(bytes).filter { $0.operation == .update }
        #expect(updates.count == 1)
        #expect(updates.first?.changedFields["live"] == nil)
        #expect(updates.first?.changedFieldsNames?.contains("live") != true)
        #expect(bound.map { $0.primaryKey } == page.map { $0.primaryKey })
        expectStoredNoHistoryIsStillOmitted(db)
    }

    @Test func aReleasedSupportedQueryImageFailsWithoutLiveFallback() throws {
        let db = try testLattice(ObserverWireImageRow.self)
        let row = ObserverWireImageRow(); row.text = "image"; try db.add(row)
        #expect(db.backend._supportsQueryRowImages)
        let raw = db.backend.objects(table: AuditLog.entityName, where: nil, orderBy: "id ASC",
                                     limit: 1, offset: nil, groupBy: nil, distinctBy: nil, params: [])
        let original = try #require(raw.first)
        let captureStart = Lattice.threadSQLStatementCount
        let copy = try AuditLog._fromRelayQueryImage(original)
        let captureSQL = Lattice.threadSQLStatementCount - captureStart
        #expect(captureSQL == 0, "Actual query-image decoding must never refresh live columns")
        #expect(copy.primaryKey != nil)
        original._releaseQueryRowImage()
        let start = Lattice.threadSQLStatementCount
        #expect(throws: RelayAuditImageError.self) { try AuditLog._fromRelayQueryImage(original) }
        #expect(Lattice.threadSQLStatementCount - start == 0, "A lost image must not authorize a fresh read")
    }
}
