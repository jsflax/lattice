#if os(macOS) || os(Linux)
import Foundation
import Testing
import CLatticeTestSQLite
@testable import Lattice
#if os(macOS)
import Darwin
#else
import Glibc
#endif

@Model private final class CloseDescriptorFactRow {
    var value: Int = 1
}

private final class CloseDescriptorWeakBackend {
    weak var value: (any LatticeBackend)?
    init(_ value: any LatticeBackend) { self.value = value }
}

/// Counts this fixture's main-file descriptors, not unrelated process activity.
private struct CloseDescriptorIdentity {
    let device: dev_t
    let inode: ino_t

    init(_ url: URL) throws {
        var metadata = stat()
        try #require(lstat(url.path, &metadata) == 0)
        device = metadata.st_dev
        inode = metadata.st_ino
    }

    func count() throws -> Int {
        #if os(Linux)
        let directory = "/proc/self/fd"
        #else
        let directory = "/dev/fd"
        #endif
        var count = 0
        for name in try FileManager.default.contentsOfDirectory(atPath: directory) {
            guard let descriptor = Int32(name) else { continue }
            var metadata = stat()
            if fstat(descriptor, &metadata) == 0,
               metadata.st_dev == device, metadata.st_ino == inode { count += 1 }
        }
        return count
    }
}

@inline(never)
private func seedCloseDescriptorFixture(_ url: URL) throws {
    let store = try Lattice(for: [CloseDescriptorFactRow.self], configuration: .init(fileURL: url))
    defer { store.close() }
    try store.add(CloseDescriptorFactRow())
}

@Suite("Closed store descriptor facts", .serialized)
struct CloseDescriptorFactsTests {
    @Test(arguments: [false, true])
    func logicalCloseAndOwnerReleaseHaveDistinctDescriptorBoundaries(holdingSiblingRead: Bool) throws {
        let directory = testTemporaryDirectory.appendingPathComponent("close-fact-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.sqlite")
        try seedCloseDescriptorFixture(file)
        let identity = try CloseDescriptorIdentity(file)
        let before = try identity.count()
        try #require(before == 0, "The fixture seed must release its owner before measurement")
        // Calibrate before the SQLite sibling locks: closing a raw descriptor
        // for the same inode while those locks exist would itself release them.
        let calibration = try FileHandle(forReadingFrom: file)
        let calibrated = try identity.count()
        try calibration.close()
        try #require(calibrated == before + 1)
        try #require(identity.count() == before)

        var sibling: OpaquePointer?
        defer { if let sibling { sqlite3_close(sibling) } }
        if holdingSiblingRead {
            try #require(sqlite3_open_v2(file.path, &sibling, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
            let reader = try #require(sibling)
            try #require(sqlite3_exec(reader, "BEGIN; SELECT count(*) FROM sqlite_schema", nil, nil, nil) == SQLITE_OK)
            try #require(sqlite3_get_autocommit(reader) == 0)
            try #require(sqlite3_txn_state(reader, "main") == SQLITE_TXN_READ)
        }
        let withSibling = try identity.count()
        if holdingSiblingRead { try #require(withSibling > before) }

        var owner: Lattice? = try Lattice(independentFor: [CloseDescriptorFactRow.self],
                                         configuration: .init(fileURL: file, allowsFileCreation: false))
        defer { owner?.close() }
        let backend = CloseDescriptorWeakBackend(owner!.backend)
        let opened = try identity.count()
        try #require(opened > withSibling)
        owner!.close()
        let logicallyClosed = try identity.count()
        // Assignment releases the final Swift owner; no result/model is kept alive.
        owner = nil
        let ownerReleased = try identity.count()
        let backendReleased = backend.value == nil

        if let reader = sibling {
            try #require(sqlite3_exec(reader, "COMMIT", nil, nil, nil) == SQLITE_OK)
            try #require(sqlite3_close(reader) == SQLITE_OK)
            sibling = nil
        }
        let allReleased = try identity.count()
        print("CLOSE_DESCRIPTOR_FACT sibling_read_lock=\(holdingSiblingRead) sqlite=\(String(cString: sqlite3_libversion())) before=\(before) sibling=\(withSibling) opened=\(opened) closed=\(logicallyClosed) owner_released=\(ownerReleased) all_released=\(allReleased) backend_released=\(backendReleased)")
        #expect(logicallyClosed == opened, "Logical close retains the native connection wrappers")
        #expect(backendReleased, "The descriptor observation must follow release of the Swift backend")
        if holdingSiblingRead {
            #expect(ownerReleased == opened,
                    "SQLite defers closing same-inode descriptors while another connection holds a read lock")
        } else {
            #expect(ownerReleased == before)
        }
        #expect(allReleased == before)
    }
}
#endif
