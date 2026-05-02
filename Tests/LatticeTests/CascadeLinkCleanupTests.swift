import Testing
import Foundation
import Lattice

// MARK: - Test models

@Model final class CascadeRoom {
    var code: String = ""
    var owner: CascadeUser?
}

@Model final class CascadeUser {
    var nick: String = ""
}

@Model final class CascadePost {
    var text: String = ""
    var author: CascadeUser?
}

/// Cascade-cleanup invariant for `lattice_db::remove(...)`: deleting a
/// model row MUST clean up every link table entry referencing it as
/// `rhs`, both as a row removal in the link table itself and as a
/// matching `_<Parent>_<Child>_<prop>` AuditLog DELETE entry. Without
/// the audit row the cleanup never reaches peers — they sync the
/// primary `Member DELETE` but keep an orphaned `_Session_Member_host`
/// pointing at a Member that no longer exists. Following the orphan
/// via `session.host?` SIGSEGVs in
/// `swift_lattice::get_properties_for_table`: `dynamic_object::get_object`
/// calls `m->table_name()` on a nullptr `cached_object_` because
/// `find_by_global_id` returns empty for the dangling rhs.
///
/// Reproduced in the wild via ClaudeCodeIRC: alice (host) + bob (peer)
/// + both `/leave` left bob's lattice with an orphan
/// `_Session_Member_host` row pointing at alice's deleted Member.
class CascadeLinkCleanupTests: BaseTest {

    /// Direct cascade check: after deleting the linked User, an
    /// AuditLog DELETE for the link table must exist. The INSERT
    /// audit (set when the link was assigned) is the baseline — the
    /// DELETE entry is what actually drives sync of the cleanup.
    @Test func deletingTarget_linkTableHasMatchingDeleteAudit() throws {
        let lattice = try testLattice(
            CascadeRoom.self, CascadeUser.self, CascadePost.self)

        let user = CascadeUser()
        user.nick = "alice"
        lattice.add(user)

        let room = CascadeRoom()
        room.code = "abc"
        lattice.add(room)
        room.owner = user

        // Sanity: link table has the row before delete.
        let beforeAudits = lattice.objects(AuditLog.self)
            .where { $0.tableName == "_CascadeRoom_CascadeUser_owner" }
            .where { $0.operation == .insert }
            .count
        #expect(beforeAudits >= 1, "Link INSERT trigger should have fired when room.owner was set.")

        lattice.delete(user)

        // After delete, all audits for the link table:
        let allAudits = Array(lattice.objects(AuditLog.self)
            .where { $0.tableName == "_CascadeRoom_CascadeUser_owner" })
        let opSummary = allAudits.map { "\($0.operation)" }.joined(separator: ",")
        #expect(allAudits.contains { $0.operation == .delete },
                "Link table should have a DELETE audit row after the linked User was deleted. Saw operations: [\(opSummary)]")
    }

    /// Reading `room.owner?` after the linked User is deleted must not
    /// crash and must report nil. Today this SIGSEGVs because the
    /// cascade DELETE on the link table doesn't run (see below), so the
    /// `_CascadeRoom_CascadeUser_owner` row survives, points at a
    /// missing User, and `dynamic_object::get_object` faults on
    /// `m->table_name()` with `cached_object_ == nullptr`.
    @Test func readingLinkAfterTargetDeleted_doesNotCrash() throws {
        let lattice = try testLattice(
            CascadeRoom.self, CascadeUser.self, CascadePost.self)

        let user = CascadeUser()
        user.nick = "alice"
        lattice.add(user)

        let room = CascadeRoom()
        room.code = "abc"
        lattice.add(room)
        room.owner = user

        #expect(room.owner?.nick == "alice")

        lattice.delete(user)

        // Re-fetch to escape any stale cached link state on the in-memory
        // instance and exercise the same path peers hit when reopening
        // their persisted lattice.
        let refetched = lattice.objects(CascadeRoom.self)
            .first { $0.code == "abc" }
        #expect(refetched != nil)
        #expect(refetched?.owner == nil,
                "Expected owner to be nil after deleting the linked User; instead the read crashes or returns a dangling reference.")
    }

    /// Direct: after deleting a User, the `_CascadeRoom_CascadeUser_owner`
    /// AuditLog DELETE entry MUST exist. That row is the wire signal
    /// that drives sync; without it peers never learn the link is
    /// gone.
    @Test func deletingTarget_emitsLinkTableAuditDelete() throws {
        let lattice = try testLattice(
            CascadeRoom.self, CascadeUser.self, CascadePost.self)

        let user = CascadeUser()
        user.nick = "alice"
        lattice.add(user)

        let room = CascadeRoom()
        room.code = "abc"
        lattice.add(room)
        room.owner = user

        lattice.delete(user)

        let linkDeletes = lattice.objects(AuditLog.self)
            .where { $0.tableName == "_CascadeRoom_CascadeUser_owner" }
            .where { $0.operation == .delete }
        #expect(linkDeletes.count == 1,
                "Expected one AuditLog DELETE for _CascadeRoom_CascadeUser_owner after deleting the linked User; without it, peers can't sync the link removal. count=\(linkDeletes.count)")
    }

    /// Cascade audit framing: when `lattice.delete(target)` cascades to
    /// link tables, the parent DELETE and every dependent link-table
    /// DELETE must surface in the same `changeStream` yield. Relays
    /// that re-frame audit rows by tailing changeStream (e.g.
    /// ClaudeCodeIRC's `RoomSyncServer.broadcastEntries`) ship one
    /// frame per yield; if the cascade is split across yields, the
    /// peer applies the parent DELETE in a separate transaction from
    /// the link DELETE, opening a window where reading the link from
    /// the peer hits a non-null FK pointing at a row that's gone —
    /// SIGSEGV in `dynamic_object::get_object`.
    @Test func cascadeAudits_arriveInSingleChangeStreamYield() async throws {
        struct DeleteAudit: Sendable { let table: String }
        struct YieldBatch: Sendable { let index: Int; let deletes: [DeleteAudit] }

        let lattice = try testLattice(
            CascadeRoom.self, CascadeUser.self, CascadePost.self)

        let user = CascadeUser()
        user.nick = "alice"
        lattice.add(user)

        let room = CascadeRoom()
        room.code = "r1"
        lattice.add(room)
        room.owner = user

        let post = CascadePost()
        post.text = "hi"
        lattice.add(post)
        post.author = user

        let latticeRef = lattice.sendableReference
        let observation: Task<[YieldBatch], Never> = Task.detached {
            guard let l = latticeRef.resolve() else { return [] }
            var batches: [YieldBatch] = []
            var idx = 0
            for await refs in l.changeStream {
                let resolved = refs.compactMap { $0.resolve(on: l) }
                let deletes = resolved
                    .filter { $0.operation == .delete }
                    .map { DeleteAudit(table: $0.tableName) }
                if !deletes.isEmpty {
                    batches.append(YieldBatch(index: idx, deletes: deletes))
                    idx += 1
                }
                let tables = batches.flatMap { $0.deletes }.map { $0.table }
                let hasUserDelete = tables.contains("CascadeUser")
                let hasLinkDelete = tables.contains { $0.hasPrefix("_") && $0.contains("CascadeUser") }
                if hasUserDelete && hasLinkDelete { return batches }
            }
            return batches
        }
        // Yield so the observer is wired before the triggering write.
        await Task.yield()

        lattice.delete(user)

        let batches = await observation.value

        for batch in batches {
            let summary = batch.deletes.map { $0.table }.joined(separator: ",")
            print("[cascade-yield \(batch.index)] \(summary)")
        }

        let allDeletes = batches.flatMap { $0.deletes }
        let userCount = allDeletes.filter { $0.table == "CascadeUser" }.count
        let roomLinkCount = allDeletes.filter { $0.table == "_CascadeRoom_CascadeUser_owner" }.count
        let postLinkCount = allDeletes.filter { $0.table == "_CascadePost_CascadeUser_author" }.count
        #expect(userCount == 1, "Expected one User DELETE; got \(userCount)")
        #expect(roomLinkCount == 1, "Expected one CascadeRoom link DELETE; got \(roomLinkCount)")
        #expect(postLinkCount == 1, "Expected one CascadePost link DELETE; got \(postLinkCount)")

        let userYield = batches.first { $0.deletes.contains { $0.table == "CascadeUser" } }?.index
        let roomYield = batches.first { $0.deletes.contains { $0.table == "_CascadeRoom_CascadeUser_owner" } }?.index
        let postYield = batches.first { $0.deletes.contains { $0.table == "_CascadePost_CascadeUser_author" } }?.index
        #expect(userYield == roomYield,
                "User DELETE landed in yield \(userYield ?? -1); CascadeRoom link DELETE landed in yield \(roomYield ?? -1). A relay that ships one frame per yield will fragment the cascade and any reader on the peer can observe a dangling link between frames.")
        #expect(userYield == postYield,
                "User DELETE landed in yield \(userYield ?? -1); CascadePost link DELETE landed in yield \(postYield ?? -1). Same fragmentation risk as above.")
    }

    /// Multiple inbound links to the same target — every backreference
    /// must be cleared, not just the first.
    @Test func multipleInboundLinks_allCleaned() throws {
        let lattice = try testLattice(
            CascadeRoom.self, CascadeUser.self, CascadePost.self)

        let user = CascadeUser()
        user.nick = "alice"
        lattice.add(user)

        let room = CascadeRoom()
        room.code = "r1"
        lattice.add(room)
        room.owner = user

        let post1 = CascadePost(); post1.text = "hi"; lattice.add(post1); post1.author = user
        let post2 = CascadePost(); post2.text = "bye"; lattice.add(post2); post2.author = user

        lattice.delete(user)

        let roomLinkDeletes = lattice.objects(AuditLog.self)
            .where { $0.tableName == "_CascadeRoom_CascadeUser_owner" }
            .where { $0.operation == .delete }
        let postLinkDeletes = lattice.objects(AuditLog.self)
            .where { $0.tableName == "_CascadePost_CascadeUser_author" }
            .where { $0.operation == .delete }
        #expect(roomLinkDeletes.count == 1)
        #expect(postLinkDeletes.count == 2,
                "Both Post→User links must be cleared; got \(postLinkDeletes.count).")
    }
}

// MARK: - Union models

@Model final class CascadeArticle {
    var title: String = ""
}

@Model final class CascadeVideo {
    var url: String = ""
}

@Union enum CascadeTopic {
    case article(CascadeArticle?)
    case video(CascadeVideo?)
    case empty
}

@Model final class CascadeFeedItem {
    var label: String = ""
    var topic: CascadeTopic = .empty
}

class CascadeUnionCleanupTests: BaseTest {

    /// Union mirror of the link case: deleting an article that a feed
    /// item points to via a union case must not leave the feed item
    /// with a dangling reference.
    @Test func deletingLinkedUnionCase_doesNotCrashOnRead() throws {
        let lattice = try testLattice(
            CascadeFeedItem.self, CascadeArticle.self, CascadeVideo.self)

        let article = CascadeArticle()
        article.title = "lattice deep dive"
        lattice.add(article)

        let item = CascadeFeedItem()
        item.label = "today"
        item.topic = .article(article)
        lattice.add(item)

        if case .article(let a) = item.topic {
            #expect(a?.title == "lattice deep dive")
        } else {
            #expect(Bool(false), "expected .article")
        }

        lattice.delete(article)

        // Re-fetch and read topic — must not crash. Either the case
        // round-trips with nil payload, or the union resolves to .empty.
        let refetched = lattice.objects(CascadeFeedItem.self)
            .first { $0.label == "today" }
        #expect(refetched != nil)
        switch refetched?.topic {
        case .article(let a):
            #expect(a == nil,
                    "Linked article was deleted; case payload must be nil.")
        case .empty:
            // Acceptable if union resolves to .empty when the linked
            // case's target vanishes.
            break
        default:
            #expect(Bool(false), "Unexpected topic state after delete.")
        }
    }

    /// Direct: after deleting the linked article, an AuditLog DELETE
    /// for the union table must exist. Without it, peers can't sync
    /// the cleanup and end up with the same orphan-link symptom.
    @Test func deletingLinkedUnionCase_emitsUnionTableAuditDelete() throws {
        let lattice = try testLattice(
            CascadeFeedItem.self, CascadeArticle.self, CascadeVideo.self)

        let article = CascadeArticle()
        article.title = "post"
        lattice.add(article)

        let item = CascadeFeedItem()
        item.label = "today"
        item.topic = .article(article)
        lattice.add(item)

        // Capture the union table name from the INSERT audit row so the
        // test isn't brittle against the macro's naming convention. The
        // union's INSERT trigger fires when `item.topic = .article(...)`
        // is committed; its tableName is the union table.
        let unionTableName = lattice.objects(AuditLog.self)
            .where { $0.operation == .insert }
            .compactMap { audit -> String? in
                let t = audit.tableName
                // Union-table audit rows are the only ones whose name
                // doesn't match the model tables we're using here.
                return (t != "CascadeFeedItem" && t != "CascadeArticle" && t != "CascadeVideo")
                    ? t : nil
            }
            .first

        #expect(unionTableName != nil,
                "Couldn't find a union table name in the AuditLog after insert; the union storage trigger didn't fire as expected.")
        guard let unionTable = unionTableName else { return }

        lattice.delete(article)

        let unionDeletes = lattice.objects(AuditLog.self)
            .where { $0.tableName == unionTable }
            .where { $0.operation == .delete }
        #expect(unionDeletes.count == 1,
                "Expected one AuditLog DELETE for \(unionTable) after deleting the linked article; without it peers can't sync the union cleanup. count=\(unionDeletes.count)")
    }
}
