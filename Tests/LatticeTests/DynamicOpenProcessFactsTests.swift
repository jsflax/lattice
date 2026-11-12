import Foundation
import Testing
import CLatticeTestSQLite
@testable import Lattice

private struct DynamicOpenFactReceipt: Codable {
    let processID: Int32
    let message: String
    let continuedAfterCatch: Bool
}

func queryDynamicOpenFactChild(fileURL: URL) throws {
    let path = try #require(ProcessInfo.processInfo.environment["LATTICE_QUERY_FACT_RECEIPT"])
    var caughtMessage: String?
    do {
        let unexpected = try Lattice.dynamic(fileURL: fileURL)
        unexpected.close()
    } catch let error as Lattice.Error {
        switch error {
        case .databaseError(let message): caughtMessage = message
        }
    }
    let message = try #require(caughtMessage, "Dynamic open must throw a catchable database error")
    try #require(!message.isEmpty)
    let receipt = DynamicOpenFactReceipt(processID: ProcessInfo.processInfo.processIdentifier,
                                         message: message, continuedAfterCatch: true)
    try JSONEncoder().encode(receipt).write(to: URL(fileURLWithPath: path), options: .atomic)
}

@Suite("Dynamic open process facts")
struct DynamicOpenProcessFactsTests {
    @Test(.timeLimit(.minutes(5)))
    func invalidReadOnlyOpensThrowSwiftErrorsWithoutEndingTheProcess() throws {
        if let path = ProcessInfo.processInfo.environment["LATTICE_XPROC_CHILD_DB_PATH"] {
            try #require(ProcessInfo.processInfo.environment["LATTICE_XPROC_CHILD_OP"] == "query-dynamic-open-fact")
            try queryDynamicOpenFactChild(fileURL: URL(fileURLWithPath: path))
            return
        }

        let directory = testTemporaryDirectory.appendingPathComponent("dynamic-open-facts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for kind in ["missing", "not-a-database", "no-audit-table"] {
            let file = directory.appendingPathComponent("\(kind).sqlite")
            if kind == "not-a-database" {
                try Data("This fixture is not a SQLite database.".utf8).write(to: file)
            } else if kind == "no-audit-table" {
                // A plain SQLite file, never written by Lattice: introspection
                // succeeds but the read-only constructor has no AuditLog table.
                var raw: OpaquePointer?
                let opened = sqlite3_open(file.path, &raw)
                defer { if let raw { sqlite3_close(raw) } }
                try #require(opened == SQLITE_OK)
                let db = try #require(raw)
                let result = sqlite3_exec(db, "CREATE TABLE FactPayload (value INTEGER); INSERT INTO FactPayload VALUES (7)", nil, nil, nil)
                try #require(result == SQLITE_OK)
                try #require(sqlite3_close(db) == SQLITE_OK)
                raw = nil
            }
            let original = kind == "missing" ? nil : try Data(contentsOf: file)
            let receiptURL = directory.appendingPathComponent("\(kind).json")
            try QueryFactSubprocess.run(operation: "query-dynamic-open-fact",
                                        filter: "invalidReadOnlyOpensThrowSwiftErrorsWithoutEndingTheProcess",
                                        file: file, receipt: receiptURL)
            let data = try Data(contentsOf: receiptURL)
            let receipt = try JSONDecoder().decode(DynamicOpenFactReceipt.self, from: data)
            #expect(receipt.processID != ProcessInfo.processInfo.processIdentifier)
            #expect(receipt.continuedAfterCatch)
            #expect(!receipt.message.isEmpty)
            if kind == "no-audit-table" {
                #expect(receipt.message.contains("no such table: AuditLog"))
            }
            if let original {
                #expect(try Data(contentsOf: file) == original)
            } else {
                #expect(!FileManager.default.fileExists(atPath: file.path))
            }
            print("FACT dynamic-open \(kind): \(String(decoding: data, as: UTF8.self))")
        }
    }
}
