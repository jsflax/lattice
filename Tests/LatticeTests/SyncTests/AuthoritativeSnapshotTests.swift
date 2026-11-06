import Foundation
import Testing
@testable import Lattice

@Model class AuthoritativeSnapshotDate {
    var modifiedAt: Date
    var expiresAt: Date
    init(modifiedAt: Date, expiresAt: Date) {
        self.modifiedAt = modifiedAt; self.expiresAt = expiresAt
    }
}

@Suite("Authoritative snapshot publication", .serialized)
final class AuthoritativeSnapshotTests: BaseTest {
    @Test func completeAuditDatesRoundTripAndSnapshotPublicationIsTransactional() throws {
        let source = try testLattice(AuthoritativeSnapshotDate.self)
        let target = try testLattice(AuthoritativeSnapshotDate.self)
        let date = Date(timeIntervalSince1970: 1_788_921_763.083822)
        try source.add(AuthoritativeSnapshotDate(modifiedAt: date, expiresAt: .distantFuture))
        let initial = try JSONEncoder().encode(ServerSentEvent.auditLog(Array(source.eventsAfter(globalId: nil))))
        _ = try target.receive(initial)
        #expect(target.objects(AuthoritativeSnapshotDate.self).first?.modifiedAt == date)
        #expect(target.objects(AuthoritativeSnapshotDate.self).first?.expiresAt == .distantFuture)
        #expect(throws: (any Error).self) { try source.appendCurrentSnapshots(tables: ["AuthoritativeSnapshotDate"], publicationKey: "once") }
        try source.withTransaction { () throws -> Void in
            #expect(try source.appendCurrentSnapshots(tables: ["AuthoritativeSnapshotDate"], publicationKey: "once") == 1)
            #expect(try source.appendCurrentSnapshots(tables: ["AuthoritativeSnapshotDate"], publicationKey: "once") == 0)
        }
        enum Rollback: Error { case expected }
        #expect(throws: Rollback.self) {
            try source.withTransaction { () throws -> Void in
                #expect(try source.appendCurrentSnapshots(tables: ["AuthoritativeSnapshotDate"], publicationKey: "rollback") == 1)
                throw Rollback.expected
            }
        }
        try source.withTransaction { () throws -> Void in
            #expect(try source.appendCurrentSnapshots(tables: ["AuthoritativeSnapshotDate"], publicationKey: "rollback") == 1)
        }
        #expect(source.objects(AuthoritativeSnapshotDate.self).first?.modifiedAt == date)
        #expect(source.objects(AuthoritativeSnapshotDate.self).first?.expiresAt == .distantFuture)
    }
}
