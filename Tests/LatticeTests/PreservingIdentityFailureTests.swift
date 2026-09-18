import Foundation
import Testing
@testable import Lattice

@Model private final class PreservingIdentityItem {
    var value: Int = 0
}

@Suite("Checked identity-preserving inserts", .serialized)
struct PreservingIdentityFailureTests {
    @Test func duplicateIdentityThrowsAndRollsBackEarlierWritesWithoutTrapping() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "preserving-identity-\(UUID()).lattice")
        let db = try Lattice(PreservingIdentityItem.self, configuration: .init(fileURL: path))
        defer { db.close(); try? Lattice.delete(for: .init(fileURL: path)) }
        let id = UUID(), first = PreservingIdentityItem(); first.value = 7
        try db.add(first, preservingGlobalId: id)
        var failure: String?
        do {
            try db.withTransaction {
                first.value = 99
                let duplicate = PreservingIdentityItem(); duplicate.value = 42
                try db.add(duplicate, preservingGlobalId: id)
            }
        } catch { failure = String(describing: error) }
        #expect(failure?.localizedCaseInsensitiveContains("unique") == true)
        db.retireAllGenerations()
        #expect(db.objects(PreservingIdentityItem.self).count == 1)
        #expect(db.object(PreservingIdentityItem.self, globalId: id)?.value == 7)
        try db.withTransaction { first.value = 8 }
        #expect(db.object(PreservingIdentityItem.self, globalId: id)?.value == 8)
    }
}
