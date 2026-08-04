import Foundation
import Testing
@testable import Lattice

// deleteNoRelay — the admin tombstone purge primitive. The property under
// test is NOT "rows get deleted" but "the deletes cannot escape": each one
// must be logged as a marker-carrying DELETE entry (which WSS receivers
// skip-and-ack), and the audit TRIGGER must not have also written a normal
// DELETE entry alongside it — a stray unmarked entry would relay to every
// member's spoke, classify into their spoke→hub sync sets, and cascade into
// their personal hubs.

@Model private final class PurgeDoc {
    var content: String = ""
    var deleted: Bool = false
    init(content: String = "", deleted: Bool = false) {
        self.content = content
        self.deleted = deleted
    }
}

private func tempLattice() throws -> Lattice {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "no-relay-\(UUID().uuidString).sqlite")
    return try Lattice(PurgeDoc.self, configuration: .init(fileURL: url))
}

@Test func deleteNoRelay_removesRowsAndWritesOnlyMarkedEntries() throws {
    let lattice = try tempLattice()
    var purgeIds: [UUID] = []
    for i in 0..<5 {
        let doc = PurgeDoc(content: "doc \(i)", deleted: i < 3)
        try lattice.add(doc)
        if doc.deleted { purgeIds.append(doc.globalId!) }
    }
    let entriesBefore = lattice.count(AuditLog.self)

    let deleted = lattice.deleteNoRelay(PurgeDoc.self, globalIds: purgeIds)

    #expect(deleted == 3)
    #expect(lattice.count(PurgeDoc.self) == 2)
    #expect(!lattice.objects(PurgeDoc.self).snapshot().contains { $0.deleted })

    // Exactly one NEW entry per purged row, every one marked, and NONE of
    // them trigger-written. The trigger writes full-row changedFields; the
    // marked synthesis writes '{}' + the marker name — so an unmarked
    // DELETE for a purged row is the trigger firing, i.e. the fleet-wide
    // relay leak.
    let newEntries = lattice.objects(AuditLog.self).snapshot()
        .filter { ($0.primaryKey ?? 0) > Int64(entriesBefore) }
    let deletes = newEntries.filter { $0.operation == .delete }
    #expect(deletes.count == 3, "expected 3 DELETE entries, got \(deletes.count)")
    for entry in deletes {
        let names = (entry.changedFieldsNames ?? []).compactMap { $0 }
        #expect(names.contains("__lattice_filter_removal"),
                "UNMARKED delete entry for \(entry.globalRowId?.uuidString ?? "?") — this would relay fleet-wide")
    }
    #expect(newEntries.count == deletes.count,
            "unexpected extra audit entries: \(newEntries.map { $0.operation.rawValue })")
}

@Test func deleteNoRelay_missingIdsAreCountedHonestly() throws {
    let lattice = try tempLattice()
    let doc = PurgeDoc(content: "real")
    try lattice.add(doc)

    let deleted = lattice.deleteNoRelay(PurgeDoc.self,
                                        globalIds: [doc.globalId!, UUID(), UUID()])
    #expect(deleted == 1, "phantom ids must not inflate the count or write entries")
    // No marked entries for rows that never existed.
    let markers = lattice.objects(AuditLog.self).snapshot()
        .filter { $0.operation == .delete }
    #expect(markers.count == 1)
}

@Test func deleteNoRelay_emptyInputIsANoOp() throws {
    let lattice = try tempLattice()
    try lattice.add(PurgeDoc(content: "keep"))
    let before = lattice.count(AuditLog.self)
    #expect(lattice.deleteNoRelay(PurgeDoc.self, globalIds: []) == 0)
    #expect(lattice.count(AuditLog.self) == before)
    #expect(lattice.count(PurgeDoc.self) == 1)
}

@Test func deleteNoRelay_restoresThePreexistingSyncDisabledState() throws {
    // The purge toggles _SyncControl.disabled around its writes. A user (or
    // maintenance op) who deliberately disabled auditing must find it STILL
    // disabled afterwards — and the normal case must come back enabled, or
    // every subsequent write on this store silently stops syncing.
    let lattice = try tempLattice()
    let doc = PurgeDoc(content: "x")
    try lattice.add(doc)
    lattice.deleteNoRelay(PurgeDoc.self, globalIds: [doc.globalId!])

    // Auditing must be live again: a fresh insert gets a trigger entry.
    let before = lattice.count(AuditLog.self)
    try lattice.add(PurgeDoc(content: "after"))
    #expect(lattice.count(AuditLog.self) == before + 1,
            "audit triggers stayed disabled after the purge — all writes on this store now silently skip sync")
}
