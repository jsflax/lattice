import Testing
import Foundation
import Lattice

// V1: no unique constraint
enum ConstraintV1 {
    @Model final class Item {
        var name: String = ""
        var category: String = ""
    }
}

// V2: @Unique added to name
enum ConstraintV2 {
    @Model final class Item {
        @Unique var name: String = ""
        var category: String = ""
    }
}

// V2b: @Unique with allowsUpsert
enum ConstraintV2Upsert {
    @Model final class Item {
        @Unique(allowsUpsert: true) var name: String = ""
        var category: String = ""
    }
}

// Bulk-insert reproducer: compound unique with allowsUpsert
enum ConstraintCompoundUpsert {
    @Model final class Candle {
        @Unique(compoundedWith: \Self.symbol, \.interval, allowsUpsert: true)
        var date: Double = 0
        var symbol: String = ""
        var interval: String = "1d"
        var close: Double = 0
    }
}

// Shape-match TraderKit's LatticeCandle so we can open the user's actual DB.
// TraderKit declares LatticeCandle as @Model class LatticeCandle: Candle (protocol).
// Column types: date REAL, open/high/low/close/volume REAL, symbol TEXT, interval TEXT.
@Model public final class LatticeCandle {
    public var open: Float = 0
    public var high: Float = 0
    public var low: Float = 0
    public var close: Float = 0
    public var volume: Float = 0
    public var symbol: String = ""
    public var interval: String = "oneDay"
    @Unique(compoundedWith: \Self.symbol, \.interval, allowsUpsert: true)
    public var date: Date = Date(timeIntervalSinceReferenceDate: 0)
}

class ConstraintEvolutionTests: BaseTest {

    @Test func test_addUniqueConstraint_onSubsequentOpen() async throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 32)).sqlite")

        // V1: insert data without unique constraint
        try autoreleasepool {
            let lattice = try Lattice(ConstraintV1.Item.self, configuration: .init(fileURL: dbPath))
            let item1 = ConstraintV1.Item(); item1.name = "alpha"; lattice.add(item1)
            let item2 = ConstraintV1.Item(); item2.name = "beta"; lattice.add(item2)
            #expect(lattice.objects(ConstraintV1.Item.self).count == 2)
            lattice.close()
        }

        // V2: reopen with @Unique on name — constraint should be auto-created
        do {
            let lattice = try Lattice(ConstraintV2.Item.self, configuration: .init(fileURL: dbPath))
            #expect(lattice.objects(ConstraintV2.Item.self).count == 2)

            // New unique name inserts fine
            let item3 = ConstraintV2.Item(); item3.name = "gamma"
            lattice.add(item3)
            #expect(lattice.objects(ConstraintV2.Item.self).count == 3)
        }

        try? Lattice.delete(for: .init(fileURL: dbPath))
    }

    @Test func test_addUniqueConstraint_withExistingDuplicates() async throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 32)).sqlite")

        // V1: insert duplicate data
        try autoreleasepool {
            let lattice = try Lattice(ConstraintV1.Item.self, configuration: .init(fileURL: dbPath))
            let item1 = ConstraintV1.Item(); item1.name = "alpha"; item1.category = "a"; lattice.add(item1)
            let item2 = ConstraintV1.Item(); item2.name = "alpha"; item2.category = "b"; lattice.add(item2)
            let item3 = ConstraintV1.Item(); item3.name = "beta"; item3.category = "c"; lattice.add(item3)
            #expect(lattice.objects(ConstraintV1.Item.self).count == 3)
            lattice.close()
        }

        // V2: reopen with @Unique on name — should deduplicate, keeping newest per name
        do {
            let lattice = try Lattice(ConstraintV2.Item.self, configuration: .init(fileURL: dbPath))
            let items = lattice.objects(ConstraintV2.Item.self)
            // "alpha" had 2 rows — deduplication keeps the newest (id=2, category="b")
            #expect(items.count == 2)

            let alpha = items.where { $0.name == "alpha" }.first
            #expect(alpha?.category == "b")
        }

        try? Lattice.delete(for: .init(fileURL: dbPath))
    }

    @Test func test_addUniqueConstraint_deduplicatesManyDuplicates() async throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 32)).sqlite")

        // V1: insert lots of duplicates
        try autoreleasepool {
            let lattice = try Lattice(ConstraintV1.Item.self, configuration: .init(fileURL: dbPath))
            for i in 0..<10 {
                let item = ConstraintV1.Item()
                item.name = "dup"
                item.category = "cat-\(i)"
                lattice.add(item)
            }
            #expect(lattice.objects(ConstraintV1.Item.self).count == 10)
            lattice.close()
        }

        // V2: reopen with @Unique — should not crash, should deduplicate to 1
        do {
            let lattice = try Lattice(ConstraintV2.Item.self, configuration: .init(fileURL: dbPath))
            #expect(lattice.objects(ConstraintV2.Item.self).count == 1)
        }

        try? Lattice.delete(for: .init(fileURL: dbPath))
    }

    @Test func test_addAllowsUpsert_afterUniqueAlreadySet() async throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 32)).sqlite")

        // V2: open with @Unique (no upsert), insert data
        try autoreleasepool {
            let lattice = try Lattice(ConstraintV2.Item.self, configuration: .init(fileURL: dbPath))
            let item1 = ConstraintV2.Item(); item1.name = "alpha"; item1.category = "original"
            lattice.add(item1)
            #expect(lattice.objects(ConstraintV2.Item.self).count == 1)
            lattice.close()
        }

        // V2b: reopen with @Unique(allowsUpsert: true), insert duplicate name
        do {
            let lattice = try Lattice(ConstraintV2Upsert.Item.self, configuration: .init(fileURL: dbPath))
            #expect(lattice.objects(ConstraintV2Upsert.Item.self).count == 1)

            // Duplicate name should upsert (replace), not crash
            let dup = ConstraintV2Upsert.Item(); dup.name = "alpha"; dup.category = "updated"
            lattice.add(dup)

            let items = lattice.objects(ConstraintV2Upsert.Item.self)
            #expect(items.count == 1)
            #expect(items.first?.category == "updated")
        }

        try? Lattice.delete(for: .init(fileURL: dbPath))
    }

    @Test func test_inspect_constraint() async throws {
        print("CONSTRAINTS:", ConstraintCompoundUpsert.Candle.constraints)
    }

    @Test func test_repro_userDb_bulkUpsert() async throws {
        let dbURL = URL(fileURLWithPath: "/tmp/trader_repro.sqlite")
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            print("SKIP: user DB copy not present")
            return
        }
        print("LatticeCandle.constraints:", LatticeCandle.constraints)

        // DB is at schema v2 (TraderKit uses traderMigrations [2: ...]).
        // Provide a no-op migration at v2 so our binary advertises target_version=2 and opens the DB.
        let noopMigration = Migration((from: LatticeCandle.self, to: LatticeCandle.self), blocks: { _, _ in })
        let lattice = try Lattice(LatticeCandle.self, configuration: .init(fileURL: dbURL, migration: [2: noopMigration]))

        // Pick an existing (symbol, interval, date) triple from the DB and try to insert a duplicate.
        let sample = lattice.objects(LatticeCandle.self).where { $0.symbol == "NVDA" && $0.interval == "oneDay" }.snapshot().prefix(3)
        #expect(sample.count > 0)

        let dups: [LatticeCandle] = sample.map { existing in
            let c = LatticeCandle()
            c.date = existing.date
            c.symbol = existing.symbol
            c.interval = existing.interval
            c.open = existing.open + 1
            c.high = existing.high + 1
            c.low = existing.low + 1
            c.close = existing.close + 1
            c.volume = existing.volume
            return c
        }

        lattice.transaction {
            lattice.add(contentsOf: dups)
        }

        print("Bulk upsert attempted on \(dups.count) rows — no throw")

        // Larger mixed batch: duplicates across different symbols + some brand-new (date, symbol) combos.
        let nvdaSample = lattice.objects(LatticeCandle.self).where { $0.symbol == "NVDA" && $0.interval == "oneDay" }.snapshot().prefix(10)
        let aaplSample = lattice.objects(LatticeCandle.self).where { $0.symbol == "AAPL" && $0.interval == "oneDay" }.snapshot().prefix(10)
        var mixed: [LatticeCandle] = []
        for existing in nvdaSample + aaplSample {
            let c = LatticeCandle()
            c.date = existing.date
            c.symbol = existing.symbol
            c.interval = existing.interval
            c.close = existing.close + 10
            c.open = existing.open
            c.high = existing.high
            c.low = existing.low
            c.volume = existing.volume
            mixed.append(c)
        }
        // New-novel rows
        let faraway = Date(timeIntervalSinceReferenceDate: 999_999_999)
        for sym in ["NVDA", "AAPL", "TSLA", "ZZZ_NEW_SYMBOL"] {
            let c = LatticeCandle()
            c.date = faraway
            c.symbol = sym
            c.interval = "oneDay"
            c.close = 1.0
            mixed.append(c)
        }

        lattice.transaction {
            lattice.add(contentsOf: mixed)
        }
        print("Mixed bulk upsert: \(mixed.count) rows — no throw")

        // Internal duplicates within the same batch — two candles with same (date, symbol, interval).
        let dupDate = Date(timeIntervalSinceReferenceDate: 888_888_888)
        let internalDups: [LatticeCandle] = (0..<3).map { i in
            let c = LatticeCandle()
            c.date = dupDate
            c.symbol = "INTERNAL_DUP_TEST"
            c.interval = "oneDay"
            c.close = Float(100 + i)
            return c
        }
        lattice.transaction {
            lattice.add(contentsOf: internalDups)
        }
        print("Internal dup bulk upsert: \(internalDups.count) rows — no throw")
    }

    @Test func test_bulkInsert_compoundUnique_allowsUpsert() async throws {
        let lattice = try testLattice(ConstraintCompoundUpsert.Candle.self)
        typealias Candle = ConstraintCompoundUpsert.Candle

        // First batch
        let batch1: [Candle] = (0..<5).map { i in
            let c = Candle()
            c.date = Double(i)
            c.symbol = "NVDA"
            c.interval = "1d"
            c.close = Double(100 + i)
            return c
        }
        lattice.add(contentsOf: batch1)
        #expect(lattice.objects(Candle.self).count == 5)

        // Second batch with overlapping (date, symbol, interval) — should upsert
        let batch2: [Candle] = (3..<8).map { i in
            let c = Candle()
            c.date = Double(i)
            c.symbol = "NVDA"
            c.interval = "1d"
            c.close = Double(200 + i)
            return c
        }
        lattice.add(contentsOf: batch2)

        let all = lattice.objects(Candle.self)
        #expect(all.count == 8)  // 0,1,2 from batch1; 3,4 upserted; 5,6,7 new
        let day3 = all.where { $0.date == 3 }.first
        #expect(day3?.close == 203)  // upserted to batch2 value
    }
}
