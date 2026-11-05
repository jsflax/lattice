import Foundation
import Testing
@testable import Lattice
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CLatticeTestSQLite)
import CLatticeTestSQLite
#endif

@Model private final class HistoryRoom {
    var title: String = ""
    var owner: HistoryOwner?
    var tools: List<HistoryTool>
}
@Model private final class HistoryOwner { var name: String = "" }
@Model private final class HistoryTool { var label: String = "" }
@Union enum HistoryUnionState {
    case none
    case waiting(reason: String)
}
@Model final class HistoryUnionRoom {
    var state: HistoryUnionState = .none
}

@Suite("Authoritative current history", .serialized)
struct CurrentHistoryTests {
    private func database() throws -> (Lattice, URL) {
        let url = testTemporaryDirectory.appendingPathComponent("current-history-\(UUID()).sqlite")
        return (try Lattice(HistoryRoom.self, HistoryOwner.self, HistoryTool.self,
                            configuration: .init(fileURL: url, busyTimeoutMs: 100)), url)
    }

    private func seed(_ db: Lattice) throws {
        let room = HistoryRoom(); room.title = "before"
        let owner = HistoryOwner(); owner.name = "agent"
        let tool = HistoryTool(); tool.label = "recall"
        try db.withTransaction {
            try db.add(room); try db.add(owner); try db.add(tool)
            room.owner = owner; room.tools.append(tool)
            room.title = "current"
            db.delete(AuditLog.self, where: { $0.operation == .insert })
        }
    }

    private func frame(_ db: Lattice) throws -> Data {
        try JSONEncoder().encode(ServerSentEvent.auditLog(Array(db.eventsAfter(globalId: nil))))
    }

    @Test func repairsAnAlreadyReceivedUpdateTailAndASecondFreshPeer() throws {
        let (source, sourceURL) = try database()
        let (target, targetURL) = try database()
        let (second, secondURL) = try database()
        defer {
            source.close(); target.close(); second.close()
            for url in [sourceURL, targetURL, secondURL] { try? Lattice.delete(for: .init(fileURL: url)) }
        }
        try seed(source)
        #expect(source.objects(AuditLog.self).count == 1)
        let retainedIDs = Set(source.objects(AuditLog.self).compactMap(\.globalId))
        _ = try target.receive(frame(source))
        #expect(target.objects(HistoryRoom.self).isEmpty)
        #expect(throws: LatticeError.self) { try source.ensureCurrentHistory() }
        try source.withTransaction { () throws -> Void in
            #expect(try source.ensureCurrentHistory() == 5)
            #expect(try source.ensureCurrentHistory() == 0)
        }
        #expect(retainedIDs.isSubset(of: Set(source.objects(AuditLog.self).compactMap(\.globalId))))
        _ = try target.receive(frame(source))
        let room = try #require(target.objects(HistoryRoom.self).first)
        #expect(room.title == "current")
        #expect(room.owner?.name == "agent")
        #expect(room.tools.first?.label == "recall")
        let identity = try source.withTransaction { try source.currentIdentitySnapshot() }
        #expect(try target.withTransaction { try target.currentIdentitySnapshot() } == identity)
        #expect(throws: LatticeError.self) { try source.currentIdentitySnapshot() }

        // All model counts stay the same when a relationship is absent.
        enum MissingLink: Error { case rollback }
        #expect(throws: MissingLink.self) {
            try target.withTransaction {
                room.owner = nil
                #expect(try target.currentIdentitySnapshot() != identity)
                throw MissingLink.rollback
            }
        }

        source.delete(AuditLog.self, where: { $0.operation == .insert })
        try source.withTransaction { () throws -> Void in #expect(try source.ensureCurrentHistory() == 5) }
        _ = try second.receive(frame(source))
        let secondRoom = try #require(second.objects(HistoryRoom.self).first)
        #expect(secondRoom.owner?.name == "agent")
        #expect(secondRoom.tools.count == 1)
    }

    @Test func callerFailureRollsBackEveryPublishedBaseline() throws {
        let (db, url) = try database()
        defer { db.close(); try? Lattice.delete(for: .init(fileURL: url)) }
        try seed(db)
        enum Abort: Error { case expected }
        #expect(throws: Abort.self) {
            try db.withTransaction { () throws -> Void in
                #expect(try db.ensureCurrentHistory() == 5)
                throw Abort.expected
            }
        }
        #expect(db.objects(AuditLog.self).count == 1)
        try db.withTransaction { () throws -> Void in #expect(try db.ensureCurrentHistory() == 5) }
    }

    @Test func typedUnionCaseAndPayloadSurviveLiveAndPrunedHistorySync() throws {
        let root = testTemporaryDirectory.appendingPathComponent("history-union-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = try Lattice(HistoryUnionRoom.self, configuration: .init(fileURL: root.appendingPathComponent("source.sqlite")))
        let target = try Lattice(HistoryUnionRoom.self, configuration: .init(fileURL: root.appendingPathComponent("target.sqlite")))
        let fresh = try Lattice(HistoryUnionRoom.self, configuration: .init(fileURL: root.appendingPathComponent("fresh.sqlite")))
        defer { source.close(); target.close(); fresh.close(); try? FileManager.default.removeItem(at: root) }
        let room = HistoryUnionRoom(); room.state = .waiting(reason: "First reason")
        try source.add(room)
        _ = try target.receive(frame(source))
        let received = try #require(target.objects(HistoryUnionRoom.self).first)
        if case .waiting(let reason) = received.state { #expect(reason == "First reason") }
        else { Issue.record("The owned union row did not arrive with its parent") }
        room.state = .none
        _ = try target.receive(frame(source))
        if case .none = received.state {} else { Issue.record("Union case update was not applied") }

        room.state = .waiting(reason: "Retained reason")
        source.delete(AuditLog.self, where: { $0.operation == .insert })
        try source.withTransaction { () throws -> Void in #expect(try source.ensureCurrentHistory() == 2) }
        _ = try fresh.receive(frame(source))
        let restored = try #require(fresh.objects(HistoryUnionRoom.self).first)
        if case .waiting(let reason) = restored.state { #expect(reason == "Retained reason") }
        else { Issue.record("Union payload was lost after pruning its INSERT history") }
        let expected = try source.withTransaction { try source.currentIdentitySnapshot() }
        #expect(try fresh.withTransaction { try fresh.currentIdentitySnapshot() } == expected)
    }

    #if canImport(SQLite3) || canImport(CLatticeTestSQLite)
    @Test func failedLinkPublicationThrowsThroughSealedBridgeAndRollsBackModels() throws {
        let (db, url) = try database()
        defer { db.close(); try? Lattice.delete(for: .init(fileURL: url)) }
        try seed(db)
        var pointer: OpaquePointer?
        #expect(sqlite3_open(url.path, &pointer) == SQLITE_OK)
        let sqlite = try #require(pointer)
        defer { sqlite3_close(sqlite) }
        let trigger = "CREATE TRIGGER fail_history BEFORE INSERT ON AuditLog WHEN NEW.tableName='_HistoryRoom_HistoryOwner_owner' BEGIN SELECT RAISE(ABORT,'blocked relationship snapshot'); END"
        #expect(sqlite3_exec(sqlite, trigger, nil, nil, nil) == SQLITE_OK)
        do {
            try db.withTransaction { try db.ensureCurrentHistory() }
            Issue.record("Expected the link baseline insert to fail")
        } catch {
            #expect(String(describing: error).contains("blocked relationship snapshot"))
        }
        #expect(db.objects(AuditLog.self).count == 1)
        #expect(sqlite3_exec(sqlite, "DROP TRIGGER fail_history", nil, nil, nil) == SQLITE_OK)
        try db.withTransaction { () throws -> Void in #expect(try db.ensureCurrentHistory() == 5) }
    }
    #endif
}
