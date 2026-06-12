import Foundation
import Testing
import Lattice

// MARK: - Fixtures

// NOTE: sibling references inside @Model classes nested in a namespace class
// must be fully qualified — the macro-generated `properties` expansion buffer
// does not resolve unqualified names from the enclosing namespace scope.
class ListQueryFixtures {
    @Model class Band {
        var name: String
        var albums: List<ListQueryFixtures.Album>
    }
    @Model class Album {
        var title: String
        var year: Int
        var band: ListQueryFixtures.Band?
    }
}

// MARK: - List query API (first(where:), where, snapshot, sortedBy)

@Suite("List Query API")
class ListQueryTests: BaseTest {
    typealias Band = ListQueryFixtures.Band
    typealias Album = ListQueryFixtures.Album

    private func makeBand(_ lattice: Lattice) -> Band {
        let band = Band()
        band.name = "Zeppelin"
        lattice.add(band)
        for (title, year) in [("IV", 1971), ("Houses of the Holy", 1973), ("Physical Graffiti", 1975)] {
            let album = Album()
            album.title = title
            album.year = year
            album.band = band
            lattice.add(album)
            band.albums.append(album)
        }
        return band
    }

    @Test func snapshotReturnsAllElementsInOrder() throws {
        let lattice = try testLattice(Band.self, Album.self)
        let band = makeBand(lattice)
        let snap = band.albums.snapshot()
        #expect(snap.count == 3)
        #expect(snap.map(\.title) == ["IV", "Houses of the Holy", "Physical Graffiti"])
    }

    // Mirrors Results.snapshot(limit:offset:) — same windowing semantics.
    @Test func snapshotWithLimitAndOffsetWindows() throws {
        let lattice = try testLattice(Band.self, Album.self)
        let band = makeBand(lattice)

        #expect(band.albums.snapshot(limit: 2).map(\.title)
                == ["IV", "Houses of the Holy"])
        #expect(band.albums.snapshot(offset: 1).map(\.title)
                == ["Houses of the Holy", "Physical Graffiti"])
        #expect(band.albums.snapshot(limit: 1, offset: 1).map(\.title)
                == ["Houses of the Holy"])
    }

    @Test func snapshotWindowClampsToBounds() throws {
        let lattice = try testLattice(Band.self, Album.self)
        let band = makeBand(lattice)

        #expect(band.albums.snapshot(offset: 10).isEmpty)
        #expect(band.albums.snapshot(limit: 10).count == 3)
        #expect(band.albums.snapshot(limit: 10, offset: 2).map(\.title)
                == ["Physical Graffiti"])
        #expect(band.albums.snapshot(limit: 0).isEmpty)
    }

    @Test func sliceSnapshotWithLimitAndOffsetWindows() throws {
        let lattice = try testLattice(Band.self, Album.self)
        let band = makeBand(lattice)

        // Windows apply AFTER the view's predicate/sort.
        let newestFirst = band.albums.sortedBy(.init(\.year, order: .reverse))
        #expect(newestFirst.snapshot(limit: 2).map(\.year) == [1975, 1973])
        #expect(newestFirst.snapshot(limit: 1, offset: 1).map(\.year) == [1973])
        #expect(newestFirst.snapshot(offset: 10).isEmpty)

        let seventiesOnward = band.albums.where { $0.year >= 1973 }
        #expect(seventiesOnward.snapshot(limit: 1).map(\.title)
                == ["Houses of the Holy"])
    }

    @Test func sortedByOrdersElements() throws {
        let lattice = try testLattice(Band.self, Album.self)
        let band = makeBand(lattice)
        let newestFirst = band.albums.sortedBy(.init(\.year, order: .reverse))
        #expect(newestFirst.map(\.year) == [1975, 1973, 1971])
        let oldestFirst = band.albums.sortedBy(.init(\.year, order: .forward))
        #expect(oldestFirst.map(\.year) == [1971, 1973, 1975])
    }

    @Test func firstWhereFindsMatch() throws {
        let lattice = try testLattice(Band.self, Album.self)
        let band = makeBand(lattice)
        // Regression: first(where:) used to ignore the predicate and return
        // element 0 — assert on a non-first element.
        let match = band.albums.first(where: { $0.year == 1973 })
        #expect(match?.title == "Houses of the Holy")
    }

    @Test func firstWhereNoMatchReturnsNil() throws {
        let lattice = try testLattice(Band.self, Album.self)
        let band = makeBand(lattice)
        #expect(band.albums.first(where: { $0.year == 1999 }) == nil)
    }

    @Test func firstWhereOnEmptyListReturnsNil() throws {
        let lattice = try testLattice(Band.self, Album.self)
        let band = Band()
        band.name = "Empty"
        lattice.add(band)
        // Regression: used to call get(at: 0) unconditionally.
        #expect(band.albums.first(where: { $0.year == 1971 }) == nil)
    }

    @Test func whereFiltersInListOrder() throws {
        let lattice = try testLattice(Band.self, Album.self)
        let band = makeBand(lattice)
        let seventies = band.albums.where({ $0.year > 1971 })
        #expect(seventies.map(\.title) == ["Houses of the Holy", "Physical Graffiti"])
        #expect(band.albums.where({ $0.year > 1980 }).isEmpty)
    }

    @Test func whereAndSortedByCompose() throws {
        let lattice = try testLattice(Band.self, Album.self)
        let band = makeBand(lattice)
        // Chained lazy views: one combined SQL query; `.first` hydrates one.
        let newestSeventies = band.albums
            .where({ $0.year > 1971 })
            .sortedBy(.init(\.year, order: .reverse))
        #expect(newestSeventies.map(\.year) == [1975, 1973])
        #expect(newestSeventies.first?.title == "Physical Graffiti")
        #expect(band.albums.sortedBy(.init(\.year, order: .forward)).first?.year == 1971)
    }
}

// MARK: - Multi-version migration dispatch (regression)

class DispatchV1 {
    @Model class Doc {
        var title: String
        var pageCountRaw: String
    }
    @Model class Memo {
        var subject: String
        var priorityRaw: String
    }
}

class DispatchCurrent {
    @Model class Doc {
        var title: String
        var pageCount: Int
    }
    @Model class Memo {
        var subject: String
        var priority: Int
    }
}

@Suite("Migration Version Dispatch")
class MigrationDispatchTests: BaseTest {
    /// v1→v3 where v2 migrates Doc and v3 migrates Memo. The row callback
    /// used to dispatch every step to migration[target] — so Doc rows fired
    /// into migration[3], which has no Doc block → preconditionFailure.
    @Test func multiStepWalkDispatchesEachVersionsBlocks() throws {
        let path = "\(String.random(length: 32)).sqlite"

        try autoreleasepool {
            let v1 = try testLattice(path: path, DispatchV1.Doc.self, DispatchV1.Memo.self)
            let doc = DispatchV1.Doc()
            doc.title = "spec"
            doc.pageCountRaw = "42"
            v1.add(doc)
            let memo = DispatchV1.Memo()
            memo.subject = "standup"
            memo.priorityRaw = "7"
            v1.add(memo)
            v1.close()
        }

        let migrated = try testLattice(
            path: path, DispatchCurrent.Doc.self, DispatchCurrent.Memo.self,
            migration: [
                2: Migration(
                    (from: DispatchV1.Doc.self, to: DispatchCurrent.Doc.self),
                    blocks: { old, new in
                        new.title = old.title
                        new.pageCount = Int(old.pageCountRaw) ?? 0
                    }
                ),
                3: Migration(
                    (from: DispatchV1.Memo.self, to: DispatchCurrent.Memo.self),
                    blocks: { old, new in
                        new.subject = old.subject
                        new.priority = Int(old.priorityRaw) ?? 0
                    }
                ),
            ])

        let doc = migrated.objects(DispatchCurrent.Doc.self).first
        #expect(doc?.title == "spec")
        #expect(doc?.pageCount == 42)
        let memo = migrated.objects(DispatchCurrent.Memo.self).first
        #expect(memo?.subject == "standup")
        #expect(memo?.priority == 7)
    }
}

// MARK: - Migration.children (FK-to-List backfill)

class ChildrenFKV1 {
    @Model class Library {
        var name: String
    }
    @Model class Book {
        var title: String
        var library: ChildrenFKV1.Library?
    }
}

class ChildrenFKCurrent {
    @Model class Library {
        var name: String
        var books: List<ChildrenFKCurrent.Book>
    }
    @Model class Book {
        var title: String
        var library: ChildrenFKCurrent.Library?
    }
}

@Suite("Migration Children Backlink Query")
class MigrationChildrenTests: BaseTest {
    /// FK-to-List: v1 has Book.library forward links only; v2 adds
    /// Library.books and backfills it in the migration block via
    /// Migration.children + List.append on the unmanaged new row.
    @Test func childrenBackfillsListFromForwardLinks() throws {
        let path = "\(String.random(length: 32)).sqlite"

        try autoreleasepool {
            let v1 = try testLattice(path: path, ChildrenFKV1.Library.self, ChildrenFKV1.Book.self)
            let library = ChildrenFKV1.Library()
            library.name = "Central"
            v1.add(library)

            for title in ["Dune", "Hyperion"] {
                let book = ChildrenFKV1.Book()
                book.title = title
                book.library = library
                v1.add(book)
            }
            let orphan = ChildrenFKV1.Book()
            orphan.title = "Unshelved"
            v1.add(orphan)
            v1.close()
        }

        let migrated = try testLattice(
            path: path, ChildrenFKCurrent.Library.self, ChildrenFKCurrent.Book.self,
            migration: [
                2: Migration(
                    (from: ChildrenFKV1.Library.self, to: ChildrenFKCurrent.Library.self),
                    blocks: { old, new in
                        new.name = old.name
                        let books = Migration.children(ChildrenFKCurrent.Book.self,
                                                       of: old, via: \.library)
                        for book in books.sorted(by: { $0.title < $1.title }) {
                            new.books.append(book)
                        }
                    }
                ),
            ])

        let library = migrated.objects(ChildrenFKCurrent.Library.self).first
        #expect(library != nil)
        #expect(library?.books.count == 2)
        #expect(library.map { $0.books.map(\.title) } == ["Dune", "Hyperion"])
        // Orphan stays unlinked.
        #expect(migrated.objects(ChildrenFKCurrent.Book.self).count == 3)
    }
}
