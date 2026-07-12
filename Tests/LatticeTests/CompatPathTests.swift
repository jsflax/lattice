import Testing
import Foundation
import Lattice

// MARK: - Fixtures

protocol CompatPOI: VirtualModel {
    var name: String { get }
    var country: String { get }
}

@Model final class CompatRestaurant: CompatPOI {
    var name: String
    var country: String

    convenience init(name: String, country: String) {
        self.init()
        self.name = name
        self.country = country
    }
}

@Model final class CompatMuseum: CompatPOI {
    var name: String
    var country: String
    var exhibitCount: Int

    convenience init(name: String, country: String, exhibitCount: Int = 0) {
        self.init()
        self.name = name
        self.country = country
        self.exhibitCount = exhibitCount
    }
}

// MARK: - Suite

/// Runtime-verifies the array-backed compat results types (`_VirtualResultsCompat`,
/// `_VirtualQueryCompat`, `_VirtualNearestResultsCompat`) on macOS, where the
/// `#available(iOS 17, …)` dispatch would otherwise always pick the
/// parameter-pack types and leave the compat surface build-verified only.
///
/// Each test runs its body twice — once on the natural (pack) path and once
/// under `Lattice.$_forceCompatPaths.withValue(true)` — and asserts identical
/// behavior. The flag is a TaskLocal, so parallel suites are unaffected.
@Suite("Compat Path Tests")
final class CompatPathTests: BaseTest {

    private func makeLattice() throws -> Lattice {
        try testLattice(CompatRestaurant.self, CompatMuseum.self)
    }

    private func seed(_ lattice: Lattice) throws {
        try lattice.add(CompatRestaurant(name: "Le Bernardin", country: "United States"))
        try lattice.add(CompatRestaurant(name: "Noma", country: "Denmark"))
        try lattice.add(CompatMuseum(name: "The Louvre", country: "France", exhibitCount: 35_000))
        try lattice.add(CompatMuseum(name: "MoMA", country: "United States", exhibitCount: 200_000))
    }

    /// Runs `body` on the natural path, then again on the forced-compat path.
    private func onBothPaths(_ body: (_ forcedCompat: Bool) throws -> Void) rethrows {
        try body(false)
        try Lattice.$_forceCompatPaths.withValue(true) {
            try body(true)
        }
    }

    @Test func test_ForcedCompat_SelectsCompatType() throws {
        let lattice = try makeLattice()
        try seed(lattice)
        onBothPaths { forced in
            let results = lattice.objects(CompatPOI.self)
            let typeName = String(describing: type(of: results))
            if forced {
                #expect(typeName.hasPrefix("_VirtualResultsCompat<"), "expected compat results, got \(typeName)")
            } else {
                #expect(typeName.hasPrefix("_VirtualResults<"), "expected pack results, got \(typeName)")
            }
        }
    }

    @Test func test_UnionCountAndSnapshot_BothPaths() throws {
        let lattice = try makeLattice()
        try seed(lattice)
        onBothPaths { _ in
            let results = lattice.objects(CompatPOI.self)
            #expect(results.count == 4)
            let names = results.snapshot().map(\.name).sorted()
            #expect(names == ["Le Bernardin", "MoMA", "Noma", "The Louvre"])
        }
    }

    @Test func test_Where_BothPaths() throws {
        let lattice = try makeLattice()
        try seed(lattice)
        onBothPaths { _ in
            var results = lattice.objects(CompatPOI.self)
            results = results.where { $0.country == "France" }
            #expect(results.count == 1)
            guard let museum = results.first as? CompatMuseum else {
                return #expect(Bool(false), "expected a CompatMuseum")
            }
            #expect(museum.name == "The Louvre")
        }
    }

    @Test func test_Where_AcrossBothTables_BothPaths() throws {
        let lattice = try makeLattice()
        try seed(lattice)
        onBothPaths { _ in
            var results = lattice.objects(CompatPOI.self)
            results = results.where { $0.country == "United States" }
            #expect(results.count == 2)
            let kinds = Set(results.snapshot().map { String(describing: type(of: $0)) })
            #expect(kinds == ["CompatRestaurant", "CompatMuseum"])
        }
    }

    @Test func test_SnapshotLimitOffset_BothPaths() throws {
        let lattice = try makeLattice()
        try seed(lattice)
        onBothPaths { _ in
            let results = lattice.objects(CompatPOI.self)
            #expect(results.snapshot(limit: 2, offset: nil).count == 2)
            let all = results.snapshot().map(\.name)
            let offset = results.snapshot(limit: 2, offset: 1).map(\.name)
            #expect(offset == Array(all.dropFirst().prefix(2)))
        }
    }

    @Test func test_PolymorphicHydration_BothPaths() throws {
        let lattice = try makeLattice()
        try seed(lattice)
        onBothPaths { _ in
            let results = lattice.objects(CompatPOI.self).snapshot()
            let restaurants = results.compactMap { $0 as? CompatRestaurant }
            let museums = results.compactMap { $0 as? CompatMuseum }
            #expect(restaurants.count == 2)
            #expect(museums.count == 2)
            #expect(museums.first { $0.name == "The Louvre" }?.exhibitCount == 35_000)
        }
    }
}
