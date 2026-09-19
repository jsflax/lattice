import Foundation
import Testing
import CxxStdlib
@testable import Lattice

@Model private final class AttachedLifetimeItem {
    var count: Int = 0
    var note: String? = nil
    var payload: Data = Data()
}

@Suite("Attached handle lifetime")
struct AttachedHandleLifetimeTests {
    @Test(arguments: [false, true])
    func retainedModelCannotAccessAReplacementAttachment(sameFile: Bool) throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = packageRoot.appendingPathComponent(".build/attached-lifetime-fixtures")
            .appendingPathComponent(UUID().uuidString)
        for name in ["a", "b"] {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let mainURL = directory.appendingPathComponent("main.sqlite")
        // Core derives the attachment alias from the filename stem. Different
        // parent directories let a new physical store reuse that same alias.
        let firstURL = directory.appendingPathComponent("a/shared.sqlite")
        let secondURL = directory.appendingPathComponent("b/shared.sqlite")

        try exercise(mainURL: mainURL, firstURL: firstURL, secondURL: secondURL,
                     sameFile: sameFile)

        // The exercise has closed and released its handles. Fresh connections
        // distinguish persisted routing from a cached or merely local value.
        let main = try open(mainURL)
        let first = try open(firstURL)
        let second = try open(secondURL)
        defer { main.close(); first.close(); second.close() }
        let mainRow = try #require(main.objects(AttachedLifetimeItem.self).first)
        let firstRow = try #require(first.objects(AttachedLifetimeItem.self).first)
        let secondRow = try #require(second.objects(AttachedLifetimeItem.self).first)
        #expect(mainRow.count == 8)
        #expect(mainRow.note == "main")
        #expect(mainRow.payload == Data([7]))
        let replacement = sameFile ? firstRow : secondRow
        #expect(replacement.count == 23)
        #expect(replacement.note == "fresh-write")
        #expect(replacement.payload == Data([2, 3]))
        if !sameFile {
            #expect(firstRow.count == 11)
            #expect(firstRow.note == "first")
            #expect(firstRow.payload == Data([1]))
        } else {
            #expect(secondRow.count == 22)
            #expect(secondRow.note == "replacement")
            #expect(secondRow.payload == Data([2]))
        }
    }

    private func open(_ url: URL) throws -> Lattice {
        var configuration = Lattice.Configuration(fileURL: url)
        configuration.resultsTuning.crossProcessBeltIntervalMs = nil
        return try Lattice(AttachedLifetimeItem.self, configuration: configuration)
    }

    private func seed(_ store: Lattice, count: Int, note: String, payload: UInt8) throws
        -> AttachedLifetimeItem {
        let row = AttachedLifetimeItem()
        row.count = count
        row.note = note
        row.payload = Data([payload])
        try store.add(row)
        return row
    }

    private func exercise(mainURL: URL, firstURL: URL, secondURL: URL,
                          sameFile: Bool) throws {
        var parent = try open(mainURL)
        let first = try open(firstURL)
        let second = try open(secondURL)
        defer { parent.close(); first.close(); second.close() }
        let mainSeed = try seed(parent, count: 7, note: "main", payload: 7)
        let firstSeed = try seed(first, count: 11, note: "first", payload: 1)
        let secondSeed = try seed(second, count: 22, note: "replacement", payload: 2)
        let mainID = try #require(mainSeed.globalId)
        let firstID = try #require(firstSeed.globalId)
        let secondID = try #require(secondSeed.globalId)
        try #require(firstSeed.primaryKey == secondSeed.primaryKey)
        try #require(firstSeed.primaryKey != nil)

        try parent.attach(lattice: first)
        let stale = try #require(parent.object(AttachedLifetimeItem.self, globalId: firstID))
        let staleBackend = try #require(stale._dynamicObject._ref as? CxxObjectBackend)
        let capturedRoute = staleBackend.tableName
        let capturedPrimaryKey = try #require(stale.primaryKey)
        #expect(!staleBackend.isRowCacheEnabled)
        #expect(stale.count == 11)
        #expect(stale.note == "first")
        #expect(stale.payload == Data([1]))

        try parent.detach(lattice: first)
        if sameFile {
            // The same row/globalId in the same file is still a NEW attachment
            // generation. A stale handle must not refresh itself to that token.
            try first.withTransaction {
                firstSeed.count = 22
                firstSeed.note = "replacement"
                firstSeed.payload = Data([2])
            }
            try parent.attach(lattice: first)
        } else {
            try parent.attach(lattice: second)
        }
        let replacementID = sameFile ? firstID : secondID
        let fresh = try #require(parent.object(AttachedLifetimeItem.self, globalId: replacementID))
        let main = try #require(parent.object(AttachedLifetimeItem.self, globalId: mainID))
        try #require(fresh._dynamicObject._ref.tableName == capturedRoute)
        try #require(fresh.primaryKey == capturedPrimaryKey)
        #expect(fresh !== stale)
        #expect(fresh.count == 22)
        #expect(fresh.note == "replacement")

        // Ordinary Swift properties retain their existing sealed fallback.
        // A recorded native error proves this was route rejection, not a
        // successful read of an old cached value or the replacement store.
        let staleCount = stale.count
        let countError = String(staleBackend.ref.lastQueryErrorMessage())
        #expect(staleCount != 22)
        #expect(countError.contains("attachment"))
        let staleNote = stale.note
        let noteError = String(staleBackend.ref.lastQueryErrorMessage())
        #expect(staleNote == nil)
        #expect(noteError.contains("attachment"))
        let stalePayload = stale.payload
        let payloadError = String(staleBackend.ref.lastQueryErrorMessage())
        #expect(stalePayload.isEmpty)
        #expect(payloadError.contains("attachment"))

        let writes: [(String, () -> Void)] = [
            ("integer", { stale.count = 900 }),
            ("optional value", { stale.note = "stale-write" }),
            ("optional nil", { stale.note = nil }),
            ("data", { stale.payload = Data([9]) }),
            ("increment", { stale.increment("count") })
        ]
        for (operation, write) in writes {
            var bodyEntered = false
            var earlierMainWriteObserved = false
            var returnedAfterStaleWrite = false
            var failure: String?
            do {
                try parent.withTransaction {
                    bodyEntered = true
                    main.count = 99
                    earlierMainWriteObserved = main.count == 99
                    write()
                    returnedAfterStaleWrite = true
                    // A successful getter clears the bridge slot. It must not
                    // clear the transaction's retained first write failure.
                    _ = main.count
                }
            } catch {
                #expect(error is LatticeError)
                failure = String(describing: error)
            }
            #expect(bodyEntered)
            #expect(earlierMainWriteObserved)
            #expect(returnedAfterStaleWrite)
            #expect(failure?.contains("attachment") == true,
                    "\(operation) must preserve the attachment failure")
            #expect(main.count == 7)
            #expect(fresh.count == 22)
            #expect(fresh.note == "replacement")
            #expect(fresh.payload == Data([2]))
        }

        // Fresh replacement handles and the main physical route remain live
        // after every rejected write, including subsequent valid transactions.
        try parent.withTransaction {
            main.count = 8
            fresh.increment("count")
            fresh.note = "fresh-write"
            fresh.payload = Data([2, 3])
        }
        #expect(main.count == 8)
        #expect(fresh.count == 23)
        #expect(fresh.note == "fresh-write")
        withExtendedLifetime(stale) {}
    }
}
