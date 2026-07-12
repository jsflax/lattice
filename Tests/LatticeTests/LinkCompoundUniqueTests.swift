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

// Mixed scalar + link compound unique WITH allowsUpsert — mirrors TraderKit's
// `LatticeHistoricalSignal` shape: @Unique(symbol, date, interval, trainedModel,
// allowsUpsert: true) where `trainedModel` is a to-one link.
enum LinkCompoundUpsert {
    @Model final class TrainedModel {
        var name: String = ""
    }
    @Model final class Row {
        @Unique(compoundedWith: \Self.date, \Self.interval, \Self.model, allowsUpsert: true)
        var symbol: String = ""
        var date: Date = Date(timeIntervalSinceReferenceDate: 0)
        var interval: String = "oneDay"
        var model: LinkCompoundUpsert.TrainedModel?
        // `payload` is the field that should change on a successful upsert.
        var payload: Float = 0
    }
}

// V1 counterpart of `LinkCompoundUpsert.Row` — NO @Unique. Used to replicate the
// real-world scenario where the constraint (and its `model__link_gid` shadow
// column) is added to an *existing* table via migration, then rows are inserted.
enum LinkCompoundUpsertV1 {
    @Model final class Row {
        var symbol: String = ""
        var date: Date = Date(timeIntervalSinceReferenceDate: 0)
        var interval: String = "oneDay"
        var model: LinkCompoundUpsert.TrainedModel?
        var payload: Float = 0
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
        try lattice.add(pet); try lattice.add(owner)

        let first = LinkCompoundUnique.Adoption(); first.pet = pet; first.owner = owner
        try lattice.add(first)

        // Clear the links on the first adoption — shadow cols should reset to NULL.
        first.pet = nil
        first.owner = nil

        // A second adoption with the same pair is now free to insert.
        let second = LinkCompoundUnique.Adoption(); second.pet = pet; second.owner = owner
        try lattice.add(second)

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
            try lattice.add(pet); try lattice.add(alice); try lattice.add(bob)

            let a = LinkCompoundUnique.Adoption(); a.pet = pet; a.owner = alice
            let b = LinkCompoundUnique.Adoption(); b.pet = pet; b.owner = bob
            try lattice.add(a); try lattice.add(b)
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

    // A compound @Unique that mixes scalar columns with a to-one link column
    // AND sets allowsUpsert: true. Pre-fix, *any* insert crashed
    // ("no such column: model" — get_upsert_columns returned the raw link name
    // instead of the `model__link_gid` shadow). The fix resolves link constraint
    // columns to their shadow AND materializes the link's globalId into the
    // shadow column during the row INSERT, so `ON CONFLICT (..., model__link_gid)
    // DO UPDATE` actually fires for a link-bearing key — overwrite-in-place works.
    @Test func test_compoundUniqueWithLink_allowsUpsert_replacesNotDuplicates() throws {
        let lattice = try testLattice(
            LinkCompoundUpsert.TrainedModel.self,
            LinkCompoundUpsert.Row.self)

        let m = LinkCompoundUpsert.TrainedModel(); m.name = "M"; try lattice.add(m)
        let d = Date(timeIntervalSinceReferenceDate: 1_000)

        let r1 = LinkCompoundUpsert.Row()
        r1.symbol = "NVDA"; r1.date = d; r1.interval = "oneDay"; r1.model = m; r1.payload = 1
        try lattice.add(r1)   // pre-fix: fatalError "no such column: model"
        #expect(lattice.objects(LinkCompoundUpsert.Row.self).count == 1)

        // Same (symbol, date, interval, model) → upsert: count stays 1, payload replaced.
        let r2 = LinkCompoundUpsert.Row()
        r2.symbol = "NVDA"; r2.date = d; r2.interval = "oneDay"; r2.model = m; r2.payload = 2
        try lattice.add(r2)
        #expect(lattice.objects(LinkCompoundUpsert.Row.self).count == 1)
        #expect(lattice.objects(LinkCompoundUpsert.Row.self).first?.payload == 2)

        // Different model on the same scalars → distinct row.
        let m2 = LinkCompoundUpsert.TrainedModel(); m2.name = "M2"; try lattice.add(m2)
        let r3 = LinkCompoundUpsert.Row()
        r3.symbol = "NVDA"; r3.date = d; r3.interval = "oneDay"; r3.model = m2; r3.payload = 3
        try lattice.add(r3)
        #expect(lattice.objects(LinkCompoundUpsert.Row.self).count == 2)

        // Same model, different date → distinct row.
        let r4 = LinkCompoundUpsert.Row()
        r4.symbol = "NVDA"; r4.date = Date(timeIntervalSinceReferenceDate: 2_000)
        r4.interval = "oneDay"; r4.model = m; r4.payload = 4
        try lattice.add(r4)
        #expect(lattice.objects(LinkCompoundUpsert.Row.self).count == 3)

        // Upsert the (m, d) row once more — still 3 rows, that row's payload is 5.
        let r5 = LinkCompoundUpsert.Row()
        r5.symbol = "NVDA"; r5.date = d; r5.interval = "oneDay"; r5.model = m; r5.payload = 5
        try lattice.add(r5)
        #expect(lattice.objects(LinkCompoundUpsert.Row.self).count == 3)
        #expect(Set(lattice.objects(LinkCompoundUpsert.Row.self).snapshot().map(\.payload)) == [5, 3, 4])
    }

    // Replicates the TraderKit scenario: a table that existed WITHOUT the
    // constraint gets `@Unique(scalar..., <link>, allowsUpsert: true)` added on a
    // later open (Phase 8a materializes the `model__link_gid` shadow column + the
    // unique index on the existing table), and then a fresh `add` is performed.
    // The real-world failure was `Lattice.swift:918: Failed to prepare insert:
    // table main.LatticeHistoricalSignal has no column named trainedModel__link_gid`.
    @Test func test_compoundUniqueWithLink_allowsUpsert_addedViaMigration_thenInsert() throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 32)).sqlite")

        // V1: no constraint on Row. Insert a TrainedModel + one Row.
        try autoreleasepool {
            let lattice = try Lattice(
                LinkCompoundUpsert.TrainedModel.self,
                LinkCompoundUpsertV1.Row.self,
                configuration: .init(fileURL: dbPath))
            let m = LinkCompoundUpsert.TrainedModel(); m.name = "M"; try lattice.add(m)
            let r = LinkCompoundUpsertV1.Row()
            r.symbol = "NVDA"; r.date = Date(timeIntervalSinceReferenceDate: 1_000)
            r.interval = "oneDay"; r.model = m; r.payload = 1
            try lattice.add(r)
            #expect(lattice.objects(LinkCompoundUpsertV1.Row.self).count == 1)
            lattice.close()
        }

        // V2: reopen with the @Unique(... <link>, allowsUpsert: true)-bearing Row.
        // Phase 8a adds `model__link_gid` + the unique index + backfills the shadow.
        do {
            let lattice = try Lattice(
                LinkCompoundUpsert.TrainedModel.self,
                LinkCompoundUpsert.Row.self,
                configuration: .init(fileURL: dbPath))
            #expect(lattice.objects(LinkCompoundUpsert.Row.self).count == 1)
            let m = lattice.objects(LinkCompoundUpsert.TrainedModel.self).first!

            // Fresh INSERT into the just-migrated table — pre-fix this crashed.
            let r2 = LinkCompoundUpsert.Row()
            r2.symbol = "NVDA"; r2.date = Date(timeIntervalSinceReferenceDate: 2_000)
            r2.interval = "oneDay"; r2.model = m; r2.payload = 2
            try lattice.add(r2)
            #expect(lattice.objects(LinkCompoundUpsert.Row.self).count == 2)

            // Upsert the migrated row (same (symbol, date, interval, model) as the V1 row).
            let r3 = LinkCompoundUpsert.Row()
            r3.symbol = "NVDA"; r3.date = Date(timeIntervalSinceReferenceDate: 1_000)
            r3.interval = "oneDay"; r3.model = m; r3.payload = 99
            try lattice.add(r3)
            #expect(lattice.objects(LinkCompoundUpsert.Row.self).count == 2)
            #expect(Set(lattice.objects(LinkCompoundUpsert.Row.self).snapshot().map(\.payload)) == [99, 2])
        }

        // Reopen once more and add again — exercises the path where the shadow
        // column already exists (Phase 8a is a no-op) and a new connection inserts.
        do {
            let lattice = try Lattice(
                LinkCompoundUpsert.TrainedModel.self,
                LinkCompoundUpsert.Row.self,
                configuration: .init(fileURL: dbPath))
            let m = lattice.objects(LinkCompoundUpsert.TrainedModel.self).first!
            let r4 = LinkCompoundUpsert.Row()
            r4.symbol = "NVDA"; r4.date = Date(timeIntervalSinceReferenceDate: 3_000)
            r4.interval = "oneDay"; r4.model = m; r4.payload = 3
            try lattice.add(r4)
            #expect(lattice.objects(LinkCompoundUpsert.Row.self).count == 3)
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
            try lattice.add(pet); try lattice.add(alice); try lattice.add(bob)

            let a1 = LinkCompoundUniqueV1.Adoption(); a1.pet = pet; a1.owner = alice
            let a2 = LinkCompoundUniqueV1.Adoption(); a2.pet = pet; a2.owner = alice // dup pair
            let a3 = LinkCompoundUniqueV1.Adoption(); a3.pet = pet; a3.owner = bob
            try lattice.add(a1); try lattice.add(a2); try lattice.add(a3)
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
