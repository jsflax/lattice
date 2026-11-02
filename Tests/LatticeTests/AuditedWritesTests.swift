import Foundation
import Testing
@testable import Lattice

@Model private final class AuditedWriterItem {
    var value: String = ""
    init(value: String) { self.value = value }
}

@Suite("Explicit audited writer preparation", .serialized)
struct AuditedWritesTests {
    @Test func preparationIsIdempotentAndCannotDisturbACallerTransaction() throws {
        let configuration = Lattice.Configuration(
            fileURL: testTemporaryDirectory.appendingPathComponent("audited-writer-\(UUID().uuidString).sqlite"))
        let db = try Lattice(AuditedWriterItem.self, configuration: configuration)
        defer { db.close(); try? Lattice.delete(for: configuration) }
        #expect(!(try db.prepareForAuditedWrites()))
        #expect(db.objects(AuditLog.self).count == 0)
        try db.withTransaction {
            try db.add(AuditedWriterItem(value: "caller owns this transaction"))
            #expect(throws: LatticeError.self) { try db.prepareForAuditedWrites() }
            #expect(db.objects(AuditedWriterItem.self).count == 1)
        }
        #expect(db.objects(AuditedWriterItem.self).count == 1)
        #expect(db.objects(AuditLog.self).count == 1)
        #expect(!(try db.prepareForAuditedWrites()))
        #expect(db.objects(AuditLog.self).count == 1)
    }
}
