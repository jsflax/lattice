import Foundation
import Testing
@testable import Lattice

@Model private final class CoarseInvalidationItem {
    var rank: Int = 0
}

private enum CoarseInvalidationTestFailure: Error { case rollback }

@Suite("Payload-free invalidation bridge", .serialized)
struct CoarseInvalidationBackendTests {
    @Test func oneCommitHintForManyRowsAndNoHintAfterRemoval() throws {
        let db = try Lattice(CoarseInvalidationItem.self,
                             configuration: .init(storage: .memory()))
        defer { db.close() }
        let backend = try #require(db.backend as? any CoarseInvalidationBackend)
        let reasons = LockedBox<[InvalidationReason]>([])
        let token = try backend._addCoarseInvalidationHook { reason in
            reasons.withLock { $0.append(reason) }
        }
        defer { try? backend._removeCoarseInvalidationHook(token) }
        try db.withTransaction {
            for rank in 0..<100 {
                let item = CoarseInvalidationItem()
                item.rank = rank
                try db.add(item)
            }
        }
        #expect(reasons.withLock { $0 } == [.commit])

        #expect(throws: CoarseInvalidationTestFailure.self) {
            try db.withTransaction {
                try db.add(CoarseInvalidationItem())
                throw CoarseInvalidationTestFailure.rollback
            }
        }
        #expect(reasons.withLock { $0 } == [.commit, .rollback])
        try backend._removeCoarseInvalidationHook(token)
        try backend._removeCoarseInvalidationHook(token)
        try db.withTransaction { try db.add(CoarseInvalidationItem()) }
        #expect(reasons.withLock { $0 } == [.commit, .rollback])
    }

    @Test func closedRegistrationThrowsInsteadOfReturningAnInertToken() throws {
        let db = try Lattice(CoarseInvalidationItem.self,
                             configuration: .init(storage: .memory()))
        let backend = try #require(db.backend as? any CoarseInvalidationBackend)
        db.close()
        #expect(throws: CoarseInvalidationError.registrationFailed) {
            try backend._addCoarseInvalidationHook { _ in
                Issue.record("closed database must not notify")
            }
        }
    }
}
