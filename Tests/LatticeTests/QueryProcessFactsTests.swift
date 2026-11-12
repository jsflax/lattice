import Foundation
import Testing
@testable import Lattice
#if os(Linux)
import Glibc
#else
import Darwin
#endif

@Model private final class QueryVisibilityFactRow {
    var phase: String = "streaming"
    var value: Int = 1
}

private struct QueryVisibilityFactReceipt: Codable {
    struct Row: Codable, Equatable {
        let id: UUID
        let phase: String
        let value: Int

        init(_ row: QueryVisibilityFactRow) throws {
            id = try #require(row.globalId)
            phase = row.phase
            value = row.value
        }

        init(id: UUID, phase: String, value: Int) {
            self.id = id
            self.phase = phase
            self.value = value
        }
    }

    let processID: Int32
    let streaming: [Row]
    let finished: [Row]
    let fullWalk: [Row]
}

// Used by the XCTest child wrapper and by a directly filtered Swift Testing child.
func queryPredicateFactChild(fileURL: URL) throws {
    let path = try #require(ProcessInfo.processInfo.environment["LATTICE_QUERY_FACT_RECEIPT"])
    // A writable fresh open could contend for schema setup. This fact concerns
    // reader visibility during a write, so use the public read-only open path.
    let reader = try Lattice(QueryVisibilityFactRow.self,
                             configuration: .init(fileURL: fileURL, isReadOnly: true))
    defer { reader.close() }
    let streaming = try reader.objects(QueryVisibilityFactRow.self)
        .where { $0.phase == "streaming" }.map { try QueryVisibilityFactReceipt.Row($0) }
    let finished = try reader.objects(QueryVisibilityFactRow.self)
        .where { $0.phase == "finished" }.map { try QueryVisibilityFactReceipt.Row($0) }
    // Deliberately walk the one-row fixture as an independent membership control.
    let fullWalk = try reader.objects(QueryVisibilityFactRow.self)
        .map { try QueryVisibilityFactReceipt.Row($0) }
    let receipt = QueryVisibilityFactReceipt(processID: getpid(), streaming: streaming,
                                             finished: finished, fullWalk: fullWalk)
    try JSONEncoder().encode(receipt).write(to: URL(fileURLWithPath: path), options: .atomic)
}

/// A child must finish normally and write its receipt; a filter miss cannot pass.
enum QueryFactSubprocess {
    static func run(operation: String, filter: String, file: URL, receipt: URL) throws {
        let config = childProcessConfig(filter: filter)
        let (executable, arguments) = try #require(config, "No supported child test runner")
        let log = receipt.appendingPathExtension("log")
        try Data().write(to: log)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("XCTest") {
            environment.removeValue(forKey: key)
        }
        environment["LATTICE_XPROC_CHILD_DB_PATH"] = file.path
        environment["LATTICE_XPROC_CHILD_OP"] = operation
        environment["LATTICE_QUERY_FACT_RECEIPT"] = receipt.path
        child.environment = environment
        child.standardOutput = output
        child.standardError = output
        let exited = DispatchSemaphore(value: 0)
        child.terminationHandler = { _ in exited.signal() }
        try child.run()
        // The semaphore is a process-exit barrier, not a delay before querying.
        let completed = exited.wait(timeout: .now() + 60) == .success
        if !completed && child.isRunning {
            kill(child.processIdentifier, SIGKILL)
        }
        child.waitUntilExit()
        if !completed || child.terminationReason != .exit || child.terminationStatus != 0 {
            let diagnostic = (try? String(contentsOf: log, encoding: .utf8)) ?? "Unreadable child log"
            Issue.record("Query fact child failed: completed=\(completed), status=\(child.terminationStatus)\n\(diagnostic)")
        }
        try #require(completed && child.terminationReason == .exit && child.terminationStatus == 0)
        try #require(FileManager.default.fileExists(atPath: receipt.path), "Child did not execute the requested fact")
    }
}

@Suite("Query process facts")
struct QueryProcessFactsTests {
    @Test(.timeLimit(.minutes(5)))
    func predicateInAnotherProcessSeesCommittedRowWhileWriterIsMidTransaction() throws {
        if let path = ProcessInfo.processInfo.environment["LATTICE_XPROC_CHILD_DB_PATH"] {
            try #require(ProcessInfo.processInfo.environment["LATTICE_XPROC_CHILD_OP"] == "query-predicate-fact")
            try queryPredicateFactChild(fileURL: URL(fileURLWithPath: path))
            return
        }

        let directory = testTemporaryDirectory.appendingPathComponent("query-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.sqlite")
        let writer = try Lattice(QueryVisibilityFactRow.self, configuration: .init(fileURL: file))
        defer { writer.close() }
        let row = QueryVisibilityFactRow()
        try writer.add(row)
        let id = try #require(row.globalId)

        func readFromChild(_ name: String) throws -> QueryVisibilityFactReceipt {
            let receipt = directory.appendingPathComponent("\(name).json")
            try QueryFactSubprocess.run(operation: "query-predicate-fact",
                                        filter: "predicateInAnotherProcessSeesCommittedRowWhileWriterIsMidTransaction",
                                        file: file, receipt: receipt)
            let data = try Data(contentsOf: receipt)
            let decoded = try JSONDecoder().decode(QueryVisibilityFactReceipt.self, from: data)
            #expect(decoded.processID != getpid())
            print("FACT predicate-visibility \(name): \(String(decoding: data, as: UTF8.self))")
            return decoded
        }

        try writer.withTransaction {
            row.phase = "finished"
            row.value = 2
            #expect(writer.objects(QueryVisibilityFactRow.self).where { $0.phase == "finished" }.first?.value == 2)
            // The transaction cannot commit until this child has queried and exited.
            let during = try readFromChild("before-commit")
            let committed = QueryVisibilityFactReceipt.Row(id: id, phase: "streaming", value: 1)
            #expect(during.streaming == [committed])
            #expect(during.finished.isEmpty)
            #expect(during.fullWalk == [committed])
        }

        let after = try readFromChild("after-commit")
        let committed = QueryVisibilityFactReceipt.Row(id: id, phase: "finished", value: 2)
        #expect(after.streaming.isEmpty)
        #expect(after.finished == [committed])
        #expect(after.fullWalk == [committed])
    }
}
