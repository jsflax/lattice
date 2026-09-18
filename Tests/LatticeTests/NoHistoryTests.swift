import Testing
import Foundation
@testable import Lattice

// @NoHistory (1.8): a column whose UPDATE audit rows record the column name
// but not its value. The quadratic-growth class: a streamed column rewritten
// ~10×/s copied its whole growing body into every audit row.

@Model final class StreamedMessage {
    var author: String = ""
    @NoHistory var text: String = ""
}

@Suite("@NoHistory · trigger shape, delivery, late-binding")
final class NoHistoryTests: BaseTest {

    private func lastUpdate(_ l: Lattice) -> AuditLog? {
        l.objects(AuditLog.self).snapshot()
            .filter { $0.tableName == "StreamedMessage" && $0.operation == .update }
            .max { ($0.primaryKey ?? 0) < ($1.primaryKey ?? 0) }
    }

    @Test func macroExposesTheFlaggedColumn() {
        #expect(StreamedMessage.noHistoryProperties == ["text"])
        #expect(StreamedMessage.indexedProperties.isEmpty)
    }

    @Test func updateAuditRowNamesTheColumnWithoutItsValue() throws {
        let l = try testLattice(StreamedMessage.self)
        let m = StreamedMessage(); m.author = "scout"; m.text = "first"
        try l.add(m)
        // INSERT keeps the value.
        let insert = l.objects(AuditLog.self).snapshot().first { $0.tableName == "StreamedMessage" && $0.operation == .insert }
        #expect(insert?.changedFields["text"]?.stringValue == "first")

        l.transaction { m.text = "first plus a much longer streamed body" }
        let u = try #require(lastUpdate(l))
        #expect(u.changedFieldsNames?.contains("text") == true)
        if let v = u.changedFields["text"] {
            if case .null = v {} else { Issue.record("text value must be null in the audit row, got \(v)") }
        }
        // An ordinary column's update still carries its value.
        l.transaction { m.author = "scout-2" }
        let u2 = try #require(lastUpdate(l))
        #expect(u2.changedFields["author"]?.stringValue == "scout-2")
        #expect(u2.changedFieldsNames?.contains("text") != true)
    }

    @Test(.timeLimit(.minutes(1)))
    func changeStreamAndChangeHeadersStillFireForTheFlaggedColumn() async throws {
        let l = try testLattice(StreamedMessage.self)
        let m = StreamedMessage(); m.text = "a"
        try l.add(m)
        var headers = l.changeHeaders.makeAsyncIterator()
        l.transaction { m.text = "ab" }
        let batch = try await headers.next()
        let h = try #require(batch?.first)
        #expect(h.tableName == "StreamedMessage")
        #expect(h.operation == .update)
        #expect(h.rowId == m.primaryKey)
    }

    @Test func lateBindingFillsTheLiveValueAndDropsAGoneRow() throws {
        let l = try testLattice(StreamedMessage.self)
        let m = StreamedMessage(); m.text = "v1"
        try l.add(m)
        for i in 2...5 { l.transaction { m.text = "v\(i)" } }

        let rows = l.lateBindNoHistory(l.eventsAfter(id: 0).snapshot())
        let updates = rows.filter { $0.operation == .update }
        #expect(updates.count == 4)
        for u in updates { #expect(u.changedFields["text"]?.stringValue == "v5", "latest value at push time") }

        l.delete(StreamedMessage.self)
        let after = l.lateBindNoHistory(l.eventsAfter(id: 0).snapshot())
        for u in after where u.operation == .update {
            #expect(u.changedFields["text"] == nil)
            #expect(u.changedFieldsNames?.contains("text") != true, "never ship a null for a NOT NULL column")
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func aSyncedPeerEndsWithTheFinalValue() async throws {
        let channel = "nohistory_\(String.random(length: 8))"
        let dir = FileManager.default.temporaryDirectory
        let hubURL = dir.appending(path: "nh_hub_\(channel).sqlite")
        let spokeURL = dir.appending(path: "nh_spoke_\(channel).sqlite")
        defer { try? Lattice.delete(for: .init(fileURL: hubURL)); try? Lattice.delete(for: .init(fileURL: spokeURL)) }

        var hubConfig = Lattice.Configuration(fileURL: hubURL)
        hubConfig.ipcTargets = [.init(channel: channel)]
        let hub = try Lattice(StreamedMessage.self, configuration: hubConfig)
        var spokeConfig = Lattice.Configuration(fileURL: spokeURL)
        spokeConfig.ipcTargets = [.init(channel: channel)]
        let spoke = try Lattice(StreamedMessage.self, configuration: spokeConfig)

        let m = StreamedMessage(); m.author = "hub"; m.text = "t0"
        try hub.add(m)
        for i in 1...20 { hub.transaction { m.text = "t\(i)" } }

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if spoke.objects(StreamedMessage.self).snapshot().first?.text == "t20" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(spoke.objects(StreamedMessage.self).snapshot().first?.text == "t20",
                "the peer receives the latest value even though no audit row carried one")
        // The hub's own history never stored the text.
        let hubUpdates = hub.objects(AuditLog.self).snapshot().filter { $0.tableName == "StreamedMessage" && $0.operation == .update }
        #expect(!hubUpdates.isEmpty)
        for u in hubUpdates {
            if let v = u.changedFields["text"] { if case .null = v {} else { Issue.record("hub audit row carries a value: \(v)") } }
        }
    }
}
