import Testing
import Foundation
import Lattice

// `@Unique(compoundedWith:)` against link-kind fields. Pre-fix this would
// crash at `ensure_swift_tables` because SQLite can't build a UNIQUE INDEX
// on columns that live in a link table. The fix materializes shadow
// `<field>__link_gid` columns plus link-table triggers so the compound
// unique can be enforced by a normal SQL index.

enum LinkCompoundUnique {
    @Model final class Pet {
        var name: String = ""
    }

    @Model final class Owner {
        var name: String = ""
    }

    @Model final class Adoption {
        // Compound unique: one adoption row per (pet, owner) pair.
        // `pet` is a link field; the fix auto-creates `pet__link_gid` +
        // `owner__link_gid` shadow cols and indexes those.
        //
        // Types are fully qualified here because `@Model` generates an
        // extension at module scope, which doesn't inherit the enum's
        // nested-type scoping.
        @Unique(compoundedWith: \Self.owner)
        var pet: LinkCompoundUnique.Pet?

        var owner: LinkCompoundUnique.Owner?
        var at: Date = Date()
    }
}

// V1 counterpart (no unique) used by the migration-from-duplicates test.
enum LinkCompoundUniqueV1 {
    @Model final class Adoption {
        var pet: LinkCompoundUnique.Pet?
        var owner: LinkCompoundUnique.Owner?
        var at: Date = Date()
    }
}

class LinkCompoundUniqueTests: BaseTest {

    @Test func test_schemaBootsWithCompoundUniqueOnLinkFields() throws {
        let lattice = try testLattice(
            LinkCompoundUnique.Pet.self,
            LinkCompoundUnique.Owner.self,
            LinkCompoundUnique.Adoption.self)
        #expect(lattice.objects(LinkCompoundUnique.Adoption.self).count == 0)
    }

    @Test func test_clearingLinkReleasesShadowAllowsReinsert() throws {
        // Evidence the DELETE trigger on the link table clears the shadow col
        // — after `vote.voter = nil`, a different row can claim the same pair.
        let lattice = try testLattice(
            LinkCompoundUnique.Pet.self,
            LinkCompoundUnique.Owner.self,
            LinkCompoundUnique.Adoption.self)

        let pet = LinkCompoundUnique.Pet(); pet.name = "Fido"
        let owner = LinkCompoundUnique.Owner(); owner.name = "Alice"
        lattice.add(pet); lattice.add(owner)

        let first = LinkCompoundUnique.Adoption(); first.pet = pet; first.owner = owner
        lattice.add(first)

        // Clear the links on the first adoption — shadow cols should reset to NULL.
        first.pet = nil
        first.owner = nil

        // A second adoption with the same pair is now free to insert.
        let second = LinkCompoundUnique.Adoption(); second.pet = pet; second.owner = owner
        lattice.add(second)

        #expect(lattice.objects(LinkCompoundUnique.Adoption.self).count == 2)
    }

    @Test func test_differentPairsCoexistAcrossReopen() throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 32)).sqlite")

        try autoreleasepool {
            let lattice = try Lattice(
                LinkCompoundUnique.Pet.self,
                LinkCompoundUnique.Owner.self,
                LinkCompoundUnique.Adoption.self,
                configuration: .init(fileURL: dbPath))
            let pet = LinkCompoundUnique.Pet(); pet.name = "Fido"
            let alice = LinkCompoundUnique.Owner(); alice.name = "Alice"
            let bob = LinkCompoundUnique.Owner(); bob.name = "Bob"
            lattice.add(pet); lattice.add(alice); lattice.add(bob)

            let a = LinkCompoundUnique.Adoption(); a.pet = pet; a.owner = alice
            let b = LinkCompoundUnique.Adoption(); b.pet = pet; b.owner = bob
            lattice.add(a); lattice.add(b)
            lattice.close()
        }

        do {
            let lattice = try Lattice(
                LinkCompoundUnique.Pet.self,
                LinkCompoundUnique.Owner.self,
                LinkCompoundUnique.Adoption.self,
                configuration: .init(fileURL: dbPath))
            #expect(lattice.objects(LinkCompoundUnique.Adoption.self).count == 2)
        }

        try? Lattice.delete(for: .init(fileURL: dbPath))
    }

    @Test func test_shadowColMaintenanceTriggersIdempotentOnReopen() throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 32)).sqlite")

        // ALTER TABLE ADD COLUMN and CREATE TRIGGER must be idempotent —
        // reopening the same DB three times must not throw.
        for _ in 0..<3 {
            try autoreleasepool {
                let lattice = try Lattice(
                    LinkCompoundUnique.Pet.self,
                    LinkCompoundUnique.Owner.self,
                    LinkCompoundUnique.Adoption.self,
                    configuration: .init(fileURL: dbPath))
                lattice.close()
            }
        }

        try? Lattice.delete(for: .init(fileURL: dbPath))
    }

    @Test func test_compoundUniqueAddedAfterDuplicatesMigrates() throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 32)).sqlite")

        // V1: no constraint on Adoption — insert duplicates.
        try autoreleasepool {
            let lattice = try Lattice(
                LinkCompoundUnique.Pet.self,
                LinkCompoundUnique.Owner.self,
                LinkCompoundUniqueV1.Adoption.self,
                configuration: .init(fileURL: dbPath))
            let pet = LinkCompoundUnique.Pet(); pet.name = "Fido"
            let alice = LinkCompoundUnique.Owner(); alice.name = "Alice"
            let bob = LinkCompoundUnique.Owner(); bob.name = "Bob"
            lattice.add(pet); lattice.add(alice); lattice.add(bob)

            let a1 = LinkCompoundUniqueV1.Adoption(); a1.pet = pet; a1.owner = alice
            let a2 = LinkCompoundUniqueV1.Adoption(); a2.pet = pet; a2.owner = alice // dup pair
            let a3 = LinkCompoundUniqueV1.Adoption(); a3.pet = pet; a3.owner = bob
            lattice.add(a1); lattice.add(a2); lattice.add(a3)
            #expect(lattice.objects(LinkCompoundUniqueV1.Adoption.self).count == 3)
            lattice.close()
        }

        // V2: same underlying table — reopen with the unique-bearing class.
        // Schema setup backfills shadow cols from link tables, then the
        // catch-block dedup trims to one row per (pet, owner) pair.
        do {
            let lattice = try Lattice(
                LinkCompoundUnique.Pet.self,
                LinkCompoundUnique.Owner.self,
                LinkCompoundUnique.Adoption.self,
                configuration: .init(fileURL: dbPath))
            #expect(lattice.objects(LinkCompoundUnique.Adoption.self).count == 2)
        }

        try? Lattice.delete(for: .init(fileURL: dbPath))
    }
}
