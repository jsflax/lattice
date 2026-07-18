import Foundation
import Testing
@testable import Lattice

// MARK: - Models for the BLOB-column live-path migration pin

class BlobMigV1 { // namespacing
    @Model class Attachment {
        var title: String
        var payload: Data
        var size: String // becomes Int in V2 → forces a row-transform migration
    }
}

class BlobMigV2 {
    @Model class Attachment {
        var title: String
        var payload: Data
        var size: Int
    }
}

/// G3: `ColumnValue` marshalling pins + the BLOB-column migration contract.
///
/// Scope note: `MigrationContext.enumerateObjects`/`setValue` marshal through
/// exactly the conversions pinned here (`ColumnValue.init(_: column_value_t)`
/// and `ColumnValue.cxxValue`). The full enumerate→setValue round-trip against
/// a live database cannot be driven from Swift in 1.0: the only bridge factory
/// that accepts a Swift migration block (`swift_lattice_ref.create(
/// config:schemas:migration:)`) routes it through the core
/// `configuration.migration_block`, which `lattice_db::ensure_tables` only
/// invokes for schema changes detected via the C++ `schema_registry` — always
/// empty in a Swift process. The block-based open lands with the 1.1
/// unified-open ABI (latticecore docs/design-unified-open.md §3), which is
/// specified against the `(rowId, [String: ColumnValue])` shape frozen here.
@Suite("Migration ColumnValue Tests")
class MigrationColumnValueTests: BaseTest {

    // MARK: ColumnValue ↔ column_value_t marshalling

    // NOTE: these round-trips deliberately avoid touching `std.optional`
    // members (`__convertToBool`/`pointee`) from THIS module — the 6.3.2
    // compiler crashes deserializing those accessors across module
    // boundaries (MandatorySILLinker, "__operatorStar" ambiguity). The
    // `ColumnValue.init(_: column_value_t)` half already exercises every
    // `column_value_as_*` optional probe inside the Lattice module.

    @Test func test_ColumnValue_Int64_RoundTrip() throws {
        let cxx = ColumnValue.int64(42).cxxValue
        #expect(!lattice.column_value_is_null(cxx))
        // Swift → C++ → Swift.
        #expect(ColumnValue(cxx) == .int64(42))
        // C++-constructed → Swift (the enumerate direction).
        #expect(ColumnValue(lattice.column_value_from_int(-7)) == .int64(-7))
    }

    @Test func test_ColumnValue_Real_RoundTrip() throws {
        let cxx = ColumnValue.real(37.7749).cxxValue
        #expect(!lattice.column_value_is_null(cxx))
        #expect(ColumnValue(cxx) == .real(37.7749))
        #expect(ColumnValue(lattice.column_value_from_double(-122.4194)) == .real(-122.4194))
        // Whole-number REALs keep their kind (regression pin: the bridge's
        // coercing as_int/as_double helpers must not decide the kind —
        // discrimination rides std::variant::index()).
        #expect(ColumnValue(lattice.column_value_from_double(2.0)) == .real(2.0))
        #expect(ColumnValue(lattice.column_value_from_int(2)) == .int64(2))
    }

    @Test func test_ColumnValue_Text_RoundTrip() throws {
        let cxx = ColumnValue.text("héllo wörld").cxxValue
        #expect(!lattice.column_value_is_null(cxx))
        #expect(ColumnValue(cxx) == .text("héllo wörld"))
        #expect(ColumnValue(lattice.column_value_from_string(std.string("x"))) == .text("x"))
    }

    @Test func test_ColumnValue_Blob_RoundTrip() throws {
        // BLOB-capable by construction — the 1.1 C ABI requirement the shape
        // exists to satisfy (unified-open design §3; C-ABI audit B-8).
        let bytes = Data([0x00, 0xFF, 0x10, 0x80, 0x7F])
        let cxx = ColumnValue.blob(bytes).cxxValue
        #expect(!lattice.column_value_is_null(cxx))
        #expect(ColumnValue(cxx) == .blob(bytes))
        #expect(ColumnValue(lattice.column_value_from_blob(lattice.ByteVector(bytes))) == .blob(bytes))
        // Empty blob is a blob, not NULL.
        let empty = ColumnValue.blob(Data()).cxxValue
        #expect(!lattice.column_value_is_null(empty))
        #expect(ColumnValue(empty) == .blob(Data()))
    }

    @Test func test_ColumnValue_Null_RoundTrip() throws {
        let cxx = ColumnValue.null.cxxValue
        #expect(lattice.column_value_is_null(cxx))
        #expect(ColumnValue(cxx) == .null)
    }

    // MARK: Accessor semantics

    @Test func test_ColumnValue_Accessors() throws {
        #expect(ColumnValue.int64(5).int64Value == 5)
        #expect(ColumnValue.real(1.5).int64Value == nil)
        // doubleValue follows SQLite numeric affinity: INTEGER-stored values
        // in REAL-declared columns surface as .int64 and must still read.
        #expect(ColumnValue.int64(5).doubleValue == 5.0)
        #expect(ColumnValue.real(1.5).doubleValue == 1.5)
        #expect(ColumnValue.text("1.5").doubleValue == nil)
        #expect(ColumnValue.text("a").stringValue == "a")
        #expect(ColumnValue.blob(Data([1])).dataValue == Data([1]))
        #expect(ColumnValue.null.isNull)
        #expect(!ColumnValue.int64(0).isNull)
        #expect(ColumnValue.null.int64Value == nil)
        #expect(ColumnValue.null.doubleValue == nil)
        #expect(ColumnValue.null.stringValue == nil)
        #expect(ColumnValue.null.dataValue == nil)
    }

    // MARK: BLOB-column migration contract pin (live path)

    /// The Swift SDK's versioned row-transform migration path is BLOB-capable:
    /// a table carrying a BLOB (`Data`) column migrates with the blob
    /// preserved byte-for-byte (the bridge row copy hydrates BLOB columns via
    /// `get_data`, no JSON round-trip). Contrast: the C ABI's
    /// `lattice_db_create_with_migration` REFUSES BLOB-bearing tables
    /// explicitly since core 1.0.0-rc.1 (audit B-8 — its JSON row transport
    /// silently dropped BLOBs); full BLOB-capable C migration rides the 1.1
    /// unified-open ABI. This test pins the Swift-path half of that contract.
    @Test func test_BlobTable_RowTransformMigration_PreservesBlob() throws {
        typealias V1 = BlobMigV1.Attachment
        typealias V2 = BlobMigV2.Attachment

        let dbPath = "blob_mig_\(String.random(length: 16)).sqlite"
        let payload = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0x00, 0x7F])

        // Phase 1: v1 schema — size is TEXT, payload is BLOB.
        try autoreleasepool {
            let lattice = try testLattice(path: dbPath, V1.self)
            let a = V1()
            a.title = "scan"
            a.payload = payload
            a.size = "8"
            try lattice.add(a)
        }

        // Phase 2: migrate to v2 (size TEXT → INTEGER) — a row-transform
        // migration over a BLOB-bearing table.
        try autoreleasepool {
            let migration: [Int: Migration] = [
                2: Migration((from: V1.self, to: V2.self),
                             blocks: { old, new in new.size = Int(old.size) ?? 0 })
            ]
            let lattice = try testLattice(path: dbPath, V2.self, migration: migration)
            let migrated = lattice.objects(V2.self)
            #expect(migrated.count == 1)
            let a = try #require(migrated.first)
            #expect(a.title == "scan")
            #expect(a.size == 8)
            #expect(a.payload == payload, "BLOB column must survive a row-transform migration byte-for-byte")
        }
    }
}
