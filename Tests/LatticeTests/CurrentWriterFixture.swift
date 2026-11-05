import CLatticeTestSQLite

// These raw connections intentionally mutate current stores to build corruption,
// retirement and foreign-writer fixtures. They are not legacy-writer probes.
// Match Core9's explicit current-writer capability without removing its guards;
// ordinary readers and old-writer rejection tests do not call this helper.
enum CurrentWriterFixtureError: Error {
    case registration(Int32)
    case mutation(Int32)
}

func registerCurrentWriterForFixtureMutation(_ connection: OpaquePointer?) throws {
    let result = sqlite3_create_function_v2(
        connection, "lattice_storage_writer_epoch", 0,
        SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_INNOCUOUS, nil,
        { context, _, _ in sqlite3_result_int(context, 9) }, nil, nil, nil)
    guard result == SQLITE_OK else { throw CurrentWriterFixtureError.registration(result) }
}
