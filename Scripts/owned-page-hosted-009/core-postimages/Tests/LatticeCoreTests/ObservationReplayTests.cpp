#include <gtest/gtest.h>
#include <lattice/db.hpp>
#include <lattice/observation_replay.hpp>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <exception>
#include <filesystem>
#include <functional>
#include <limits>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#if !defined(__EMSCRIPTEN__)
#include <unistd.h>
#include <csignal>
namespace {
namespace frames = lattice::observation_frames;
namespace replay = frames::replay;
using lattice::database;
void require(bool value, const char* reason) { if (!value) throw std::runtime_error(reason); }
void schema(database& db) {
    db.execute(R"SQL(CREATE TABLE AuditLog(
        id INTEGER PRIMARY KEY AUTOINCREMENT,globalId TEXT UNIQUE COLLATE NOCASE,
        tableName TEXT,operation TEXT,rowId INTEGER,globalRowId TEXT,
        changedFields TEXT,changedFieldsNames TEXT,
        isFromRemote INTEGER DEFAULT 0,isSynchronized INTEGER DEFAULT 0,
        timestamp REAL DEFAULT 0,synthesized INTEGER DEFAULT 0);
        CREATE TABLE Model(id INTEGER PRIMARY KEY,value INTEGER);
        INSERT INTO Model VALUES(1,0))SQL");
}
void setup(database& db) {
    schema(db);
    require(frames::install(db).code == frames::status::ready_integrity_only, "private frame install");
}
int64_t scalar(database& db, const char* sql) {
    const auto rows = db.query(sql);
    require(rows.size() == 1 && rows.front().size() == 1, "fixture scalar");
    return std::get<int64_t>(rows.front().begin()->second);
}
void append(database& db, const std::string& id, const std::string& names = {}) {
    db.execute("INSERT INTO AuditLog(globalId,tableName,operation,rowId,globalRowId,changedFieldsNames) VALUES(?,'M','INSERT',1,'r',?)",
               {id, names});
}
void commit(database& db, const std::vector<std::string>& ids, int64_t model = 0) {
    frames::write_scope writer(db);
    db.execute("UPDATE Model SET value=? WHERE id=1", {model});
    for (const auto& id : ids) append(db, id);
    require(writer.commit().code == frames::outcome::committed, "owned frame commit");
}
replay::cursor origin(database& db) {
    auto opened = replay::open(db); require(static_cast<bool>(opened.scope), "open origin snapshot");
    auto result = opened.scope->origin(); require(result.result.status == replay::code::ready, "origin cursor");
    require(opened.scope->finish().status == replay::code::ready, "finish origin");
    return result.resume;
}
void settled(database& db) {
    require(sqlite3_get_autocommit(db.handle()) && !sqlite3_next_stmt(db.handle(), nullptr), "no statement or transaction retained");
}
struct File {
    std::filesystem::path path;
    File() {
        static std::atomic<unsigned> count{0};
        path = std::filesystem::temp_directory_path() /
            ("observation-replay-" + std::to_string(getpid()) + "-" + std::to_string(count.fetch_add(1)) + ".sqlite");
        require(!std::filesystem::exists(path), "fresh owned replay fixture");
    }
    ~File() {
        std::error_code ignored;
        for (const auto* suffix : {"", "-wal", "-shm"}) std::filesystem::remove(path.string() + suffix, ignored);
    }
};
void concurrent(const std::function<void()>& body) {
    std::exception_ptr error;
    std::jthread writer([&] { try { body(); } catch (...) { error = std::current_exception(); } });
    writer.join(); if (error) std::rethrow_exception(error);
}
void bounded(const std::function<void()>& body) {
#if GTEST_HAS_DEATH_TEST && (defined(__APPLE__) || defined(__linux__))
    struct Restore { std::string value = ::testing::FLAGS_gtest_death_test_style; ~Restore() { ::testing::FLAGS_gtest_death_test_style = value; } } restore;
    ::testing::FLAGS_gtest_death_test_style = "threadsafe";
    ASSERT_EXIT({
        std::signal(SIGALRM, SIG_DFL);
        sigset_t alarm_set; sigemptyset(&alarm_set); sigaddset(&alarm_set, SIGALRM);
        if (sigprocmask(SIG_UNBLOCK, &alarm_set, nullptr)) _exit(2);
        alarm(10);
        try { body(); std::fputs("replay_case_complete\n", stderr); _exit(0); }
        catch (const std::exception& e) { std::fprintf(stderr, "replay_failure: %s\n", e.what()); _exit(1); }
    }, ::testing::ExitedWithCode(0), "replay_case_complete");
#else
    body();
#endif
}
} // namespace

TEST(ObservationReplay, ExactFramesExcludeEmptyAndRolledBackTransactions) {
    database db(":memory:"); setup(db); const auto start = origin(db);
    { frames::write_scope empty(db); ASSERT_EQ(empty.commit().code, frames::outcome::committed); }
    commit(db, {"a", "b"});
    { frames::write_scope rollback(db); append(db, "discarded"); }
    commit(db, {"c"});
    auto page = replay::read_frames(db, start);
    ASSERT_EQ(page.result.status, replay::code::ready);
    ASSERT_EQ(page.frame_count, 2); ASSERT_EQ(page.row_count, 3);
    EXPECT_EQ(page.frames[0].row_count, 2); EXPECT_EQ(page.frames[1].row_count, 1);
    EXPECT_EQ(page.value(page.rows[0].global_id), "a");
    EXPECT_EQ(page.value(page.rows[2].global_id), "c");
    EXPECT_EQ(page.next.after_audit_id, 3); EXPECT_TRUE(page.at_head); settled(db);
}

TEST(ObservationReplay, SavepointRollbackRetainsOnlySurvivingFrameMembers) {
    database db(":memory:"); setup(db); auto start = origin(db);
    { frames::write_scope writer(db); append(db, "a"); const auto point = writer.savepoint();
      append(db, "gone"); writer.rollback_to(point); writer.release(point); append(db, "b");
      ASSERT_EQ(writer.commit().code, frames::outcome::committed); }
    auto page = replay::read_frames(db, start);
    ASSERT_EQ(page.result.status, replay::code::ready); ASSERT_EQ(page.frame_count, 1);
    ASSERT_EQ(page.row_count, 2); EXPECT_EQ(page.value(page.rows[1].global_id), "b");
}

TEST(ObservationReplay, RowAndFrameLimitsNeverReturnPartialTransaction) {
    database db(":memory:"); setup(db); auto start = origin(db); commit(db, {"a", "b"}); commit(db, {"c"});
    replay::limits cap; cap.max_rows = 1; cap.max_frames = 1;
    auto too_small = replay::read_frames(db, start, cap);
    EXPECT_EQ(too_small.result.status, replay::code::frame_too_large); EXPECT_FALSE(too_small.has_cursor);
    EXPECT_EQ(too_small.result.boundary_first_audit_id, 1); EXPECT_EQ(too_small.result.boundary_last_audit_id, 2);
    cap.max_rows = 2;
    auto first = replay::read_frames(db, start, cap);
    ASSERT_EQ(first.result.status, replay::code::ready); ASSERT_EQ(first.frame_count, 1);
    EXPECT_EQ(first.row_count, 2); EXPECT_FALSE(first.at_head);
    auto last = replay::read_frames(db, first.next, cap);
    ASSERT_EQ(last.result.status, replay::code::ready); ASSERT_EQ(last.row_count, 1);
    EXPECT_EQ(last.value(last.rows[0].global_id), "c"); EXPECT_TRUE(last.at_head);
}

TEST(ObservationReplay, ExactByteLimitIncludesArrayStorageAndEmbeddedNul) {
    database db(":memory:"); setup(db); auto start = origin(db);
    { frames::write_scope writer(db);
      // database's string binder uses -1 length. Bind exact bytes as a BLOB and
      // cast in SQLite so the fixture really contains the embedded NUL.
      db.execute("INSERT INTO AuditLog(globalId,tableName,operation,rowId,globalRowId,changedFieldsNames) VALUES('a','M','INSERT',1,'r',CAST(? AS TEXT))",
                 {std::vector<uint8_t>{'n', 0, 'm'}});
      ASSERT_EQ(writer.commit().code, frames::outcome::committed); }
    const auto stored = db.query("SELECT typeof(changedFieldsNames) AS type,hex(changedFieldsNames) AS bytes,length(CAST(changedFieldsNames AS BLOB)) AS size FROM AuditLog");
    ASSERT_EQ(stored.size(), 1);
    ASSERT_EQ(std::get<std::string>(stored[0].at("type")), "text");
    ASSERT_EQ(std::get<std::string>(stored[0].at("bytes")), "6E006D");
    ASSERT_EQ(std::get<int64_t>(stored[0].at("size")), 3);
    replay::limits cap; cap.max_rows = cap.max_frames = 1;
    const size_t fixed = sizeof(replay::page) + sizeof(replay::frame_header) + sizeof(replay::audit_header);
    cap.max_bytes = fixed + 12; // a + M + INSERT + r + n\0m
    auto exact = replay::read_frames(db, start, cap);
    ASSERT_EQ(exact.result.status, replay::code::ready); ASSERT_EQ(exact.row_count, 1);
    EXPECT_EQ(exact.text_bytes, 12); EXPECT_EQ(exact.allocated_bytes, cap.max_bytes);
    EXPECT_EQ(exact.value(exact.rows[0].changed_field_names), std::string_view("n\0m", 3));
    --cap.max_bytes;
    auto smaller = replay::read_frames(db, start, cap);
    EXPECT_EQ(smaller.result.status, replay::code::frame_too_large); EXPECT_FALSE(smaller.has_cursor);
    EXPECT_EQ(smaller.allocated_bytes, 0); settled(db);
}

TEST(ObservationReplay, NullableStoredHeadersRemainNullAndOwnedAfterClose) {
    database db(":memory:"); setup(db); auto start = origin(db);
    { frames::write_scope writer(db); db.execute("INSERT INTO AuditLog(globalId) VALUES('only-id')");
      ASSERT_EQ(writer.commit().code, frames::outcome::committed); }
    auto page = replay::read_frames(db, start); db.close();
    ASSERT_EQ(page.result.status, replay::code::ready); ASSERT_EQ(page.row_count, 1);
    EXPECT_TRUE(page.rows[0].table_name.is_null); EXPECT_TRUE(page.rows[0].row_id.is_null);
    EXPECT_TRUE(page.rows[0].changed_field_names.is_null); EXPECT_EQ(page.value(page.rows[0].global_id), "only-id");
}

TEST(ObservationReplay, ByteLimitedPageRetainsOnlyCompletedEarlierFrames) {
    database db(":memory:"); setup(db); const auto start = origin(db); commit(db, {"a"}); commit(db, {"b"});
    replay::limits cap; cap.max_rows = cap.max_frames = 2;
    cap.max_bytes = sizeof(replay::page) + 2 * sizeof(replay::frame_header) + 2 * sizeof(replay::audit_header) + 9;
    auto first = replay::read_frames(db, start, cap);
    ASSERT_EQ(first.result.status, replay::code::ready); ASSERT_EQ(first.row_count, 1);
    EXPECT_EQ(first.frame_count, 1); EXPECT_EQ(first.text_bytes, 9); EXPECT_FALSE(first.at_head);
    EXPECT_EQ(first.value(first.rows[0].global_id), "a");
    auto next = replay::read_frames(db, first.next, cap);
    ASSERT_EQ(next.result.status, replay::code::ready); ASSERT_EQ(next.row_count, 1);
    EXPECT_EQ(next.value(next.rows[0].global_id), "b"); EXPECT_TRUE(next.at_head);
}

TEST(ObservationReplay, CursorRestartsOnReopenedReaderWithoutReplayDuplication) {
    File file; replay::cursor next;
    { database db(file.path.string()); setup(db); auto start = origin(db); commit(db, {"a"}); commit(db, {"b"});
      replay::limits cap; cap.max_frames = 1;
      database reader(file.path.string(), database::open_mode::read_only);
      auto first = replay::read_frames(reader, start, cap);
      ASSERT_EQ(first.result.status, replay::code::ready); next = first.next; settled(reader); }
    { database reopened(file.path.string(), database::open_mode::read_only);
      auto second = replay::read_frames(reopened, next);
      ASSERT_EQ(second.result.status, replay::code::ready); ASSERT_EQ(second.row_count, 1);
      EXPECT_EQ(second.value(second.rows[0].global_id), "b"); EXPECT_TRUE(second.at_head); }
}

TEST(ObservationReplay, CommitBeforeSnapshotBelongsToItsBarrier) { bounded([] {
    File file; database writer(file.path.string()); setup(writer); commit(writer, {"before"}, 1);
    database reader(file.path.string(), database::open_mode::read_only);
    auto opened = replay::open(reader); require(static_cast<bool>(opened.scope), "open before snapshot");
    require(scalar(reader, "SELECT value FROM Model WHERE id=1") == 1, "model includes prior commit");
    const auto barrier = opened.scope->capture_barrier();
    require(barrier.has_cursor && barrier.resume.after_audit_id == 1, "barrier includes prior commit");
    require(opened.scope->finish().status == replay::code::ready, "snapshot finish");
    auto page = replay::read_frames(reader, barrier.resume);
    require(page.result.status == replay::code::ready && page.at_head && page.row_count == 0, "no duplicate prior frame");
}); }

TEST(ObservationReplay, CommitDuringSnapshotCannotSeparateModelFromBarrier) { bounded([] {
    File file; database writer(file.path.string()); setup(writer); commit(writer, {"before"}, 1);
    database reader(file.path.string(), database::open_mode::read_only);
    auto opened = replay::open(reader); require(static_cast<bool>(opened.scope), "open during snapshot");
    concurrent([&] { commit(writer, {"during"}, 2); });
    require(scalar(reader, "SELECT value FROM Model WHERE id=1") == 1, "same old model snapshot");
    const auto barrier = opened.scope->capture_barrier();
    require(barrier.has_cursor && barrier.resume.after_audit_id == 1, "same old durable head");
    require(opened.scope->finish().status == replay::code::ready, "snapshot finish");
    auto page = replay::read_frames(reader, barrier.resume);
    require(page.result.status == replay::code::ready && page.row_count == 1 && page.value(page.rows[0].global_id) == "during",
            "next call catches exactly concurrent commit"); settled(reader);
}); }

TEST(ObservationReplay, CommitAfterSnapshotIsReadAfterAcceptedBarrier) { bounded([] {
    File file; database writer(file.path.string()); setup(writer);
    database reader(file.path.string(), database::open_mode::read_only);
    auto opened = replay::open(reader); require(static_cast<bool>(opened.scope), "open empty snapshot");
    require(scalar(reader, "SELECT value FROM Model WHERE id=1") == 0, "empty model baseline");
    const auto barrier = opened.scope->capture_barrier(); require(barrier.has_cursor, "empty barrier");
    opened.scope.reset(); settled(reader);
    concurrent([&] { commit(writer, {"after"}, 3); });
    auto page = replay::read_frames(reader, barrier.resume);
    require(page.result.status == replay::code::ready && page.row_count == 1 && page.value(page.rows[0].global_id) == "after",
            "later commit is not skipped");
}); }

TEST(ObservationReplay, ConcurrentPartialPruneNeverPublishesTruncatedFrame) { bounded([] {
    File file; database writer(file.path.string()); setup(writer); const auto start = origin(writer); commit(writer, {"a", "b"});
    database reader(file.path.string(), database::open_mode::read_only);
    auto opened = replay::open(reader); require(static_cast<bool>(opened.scope), "open pre-prune snapshot");
    concurrent([&] { writer.execute("DELETE FROM AuditLog WHERE globalId='a'"); });
    auto old = opened.scope->read_after(start);
    require(old.result.status == replay::code::ready && old.row_count == 2, "held snapshot retains complete old frame");
    const auto accepted = old.next; opened.scope.reset();
    auto gap = replay::read_frames(reader, start);
    require(gap.result.status == replay::code::history_pruned && !gap.has_cursor && gap.snapshot.pruned_through == 2,
            "new snapshot reports whole-frame gap despite surviving row");
    auto equal_floor = replay::read_frames(reader, accepted);
    require(equal_floor.result.status == replay::code::ready && equal_floor.row_count == 0 && equal_floor.at_head,
            "acknowledged end equal to floor remains resumable");
}); }

TEST(ObservationReplay, ConcurrentRollbackPublishesNoFrameOrModelChange) { bounded([] {
    File file; database writer(file.path.string()); setup(writer); const auto start = origin(writer);
    database reader(file.path.string(), database::open_mode::read_only);
    auto opened = replay::open(reader); require(static_cast<bool>(opened.scope), "open rollback snapshot");
    concurrent([&] { frames::write_scope scope(writer); writer.execute("UPDATE Model SET value=9"); append(writer, "gone"); });
    require(scalar(reader, "SELECT value FROM Model") == 0, "rollback model unchanged"); opened.scope.reset();
    auto page = replay::read_frames(reader, start);
    require(page.result.status == replay::code::ready && page.row_count == 0 && page.at_head, "rollback has no replay frame");
}); }

TEST(ObservationReplay, RawWriterReportsUnavailableRangeUntilExplicitBarrier) {
    database db(":memory:"); setup(db); auto start = origin(db); append(db, "unknown");
    auto unknown = replay::read_frames(db, start);
    EXPECT_EQ(unknown.result.status, replay::code::framing_unavailable); EXPECT_FALSE(unknown.has_cursor);
    EXPECT_EQ(unknown.result.boundary_first_audit_id, 1); EXPECT_EQ(unknown.result.boundary_last_audit_id, 1);
    auto opened = replay::open(db); ASSERT_TRUE(opened.scope);
    const auto barrier = opened.scope->capture_barrier(); ASSERT_TRUE(barrier.has_cursor); opened.scope.reset();
    commit(db, {"known"}); auto next = replay::read_frames(db, barrier.resume);
    ASSERT_EQ(next.result.status, replay::code::ready); ASSERT_EQ(next.row_count, 1);
    EXPECT_EQ(next.value(next.rows[0].global_id), "known");
}

TEST(ObservationReplay, ForeignStoreAndEpochResetAreDistinctNonAdvancingResults) {
    database first(":memory:"), second(":memory:"); setup(first); setup(second); auto start = origin(first);
    auto foreign = replay::read_frames(second, start);
    EXPECT_EQ(foreign.result.status, replay::code::foreign_store); EXPECT_FALSE(foreign.has_cursor);
    commit(first, {"a"}); first.execute("UPDATE AuditLog SET operation='UPDATE' WHERE id=1");
    auto reset = replay::read_frames(first, start);
    EXPECT_EQ(reset.result.status, replay::code::history_reset); EXPECT_FALSE(reset.has_cursor);
    auto opened = replay::open(first); ASSERT_TRUE(opened.scope);
    auto missing = opened.scope->origin(); EXPECT_EQ(missing.result.status, replay::code::coverage_unavailable);
    opened = replay::open(first); ASSERT_TRUE(opened.scope);
    auto barrier = opened.scope->capture_barrier(); ASSERT_TRUE(barrier.has_cursor); opened.scope.reset();
    commit(first, {"b"}); auto next = replay::read_frames(first, barrier.resume);
    ASSERT_EQ(next.result.status, replay::code::ready); ASSERT_EQ(next.row_count, 1);
    EXPECT_EQ(next.value(next.rows[0].global_id), "b");
}

TEST(ObservationReplay, KnownPrefixIsDeliveredBeforeUnavailableRangeWithoutSkippingIt) {
    database db(":memory:"); setup(db); const auto start = origin(db);
    commit(db, {"known"}); append(db, "unknown");
    auto prefix = replay::read_frames(db, start);
    ASSERT_EQ(prefix.result.status, replay::code::ready); ASSERT_EQ(prefix.row_count, 1);
    EXPECT_EQ(prefix.value(prefix.rows[0].global_id), "known"); EXPECT_FALSE(prefix.at_head);
    EXPECT_EQ(prefix.next.after_audit_id, 1);
    auto gap = replay::read_frames(db, prefix.next);
    EXPECT_EQ(gap.result.status, replay::code::framing_unavailable); EXPECT_FALSE(gap.has_cursor);
    EXPECT_EQ(gap.result.boundary_first_audit_id, 2); EXPECT_EQ(gap.result.boundary_last_audit_id, 2);
}

TEST(ObservationReplay, PreinstallationHistoryRequiresExplicitSnapshotBarrier) {
    database db(":memory:"); schema(db); append(db, "old");
    ASSERT_EQ(frames::install(db).code, frames::status::ready_integrity_only);
    auto opened = replay::open(db); ASSERT_TRUE(opened.scope);
    auto result = opened.scope->origin(); EXPECT_EQ(result.result.status, replay::code::coverage_unavailable);
    EXPECT_FALSE(result.has_cursor); settled(db);
}

TEST(ObservationReplay, UnknownSchemaAndFormatOneAreNotRepairedOrAccepted) {
    database old(":memory:"); schema(old);
    ASSERT_EQ(lattice::observation_metadata::install(old).code, frames::status::ready_integrity_only);
    auto unsupported = replay::open(old);
    EXPECT_EQ(unsupported.result.status, replay::code::metadata_uncertain); EXPECT_FALSE(unsupported.scope);
    EXPECT_EQ(scalar(old, "SELECT format_version FROM _lattice_observation_state"), 1);
    database current(":memory:"); setup(current); const auto start = origin(current);
    current.execute("CREATE TABLE unrelated(value INTEGER)");
    auto drift = replay::read_frames(current, start);
    EXPECT_EQ(drift.result.status, replay::code::metadata_uncertain); EXPECT_FALSE(drift.has_cursor); settled(current);
}

TEST(ObservationReplay, CorruptedFrameCountAndCursorCannotProducePartialSuccess) {
    database db(":memory:"); setup(db); auto start = origin(db); commit(db, {"a", "b"});
    auto good = replay::read_frames(db, start); ASSERT_EQ(good.result.status, replay::code::ready);
    auto invalid = good.next; invalid.after_audit_id = 1;
    auto wrong_cursor = replay::read_frames(db, invalid);
    EXPECT_EQ(wrong_cursor.result.status, replay::code::invalid_cursor); EXPECT_FALSE(wrong_cursor.has_cursor);
    db.execute("UPDATE _lattice_observation_frames SET record_count=3");
    auto malformed = replay::read_frames(db, start);
    EXPECT_EQ(malformed.result.status, replay::code::metadata_uncertain); EXPECT_FALSE(malformed.has_cursor);
}

TEST(ObservationReplay, MalformedSnapshotAnchorCannotPublishUnusableCursor) {
    for (const auto* mutation : {
            "UPDATE _lattice_observation_frames SET frame_id=0",
            "UPDATE _lattice_observation_frames SET frame_id=-1",
            "UPDATE _lattice_observation_frames SET last_audit_id=2"}) {
        SCOPED_TRACE(mutation);
        database db(":memory:"); setup(db); commit(db, {"a"});
        db.execute(mutation);
        // These data mutations preserve the exact schema/cookie and pass the
        // format inspector. Barrier creation must validate its own anchor.
        db.execute("BEGIN DEFERRED");
        (void)db.query("SELECT rootpage FROM main.sqlite_schema LIMIT 1");
        const auto inspected = frames::inspect_in_snapshot(db);
        db.execute("ROLLBACK");
        ASSERT_EQ(inspected.code, frames::status::ready_integrity_only);
        auto opened = replay::open(db); ASSERT_TRUE(opened.scope);
        const auto barrier = opened.scope->capture_barrier();
        EXPECT_EQ(barrier.result.status, replay::code::metadata_uncertain);
        EXPECT_FALSE(barrier.has_cursor); EXPECT_TRUE(barrier.result.cleanup_ok);
        EXPECT_EQ(barrier.resume.frame_id, 0); settled(db);
    }
}

TEST(ObservationReplay, SnapshotBarrierRecoversAtInvalidatedPrunedAnchor) {
    database db(":memory:"); setup(db); commit(db, {"a", "b"});
    db.execute("DELETE FROM AuditLog WHERE globalId='a'");
    ASSERT_EQ(scalar(db, "SELECT invalidated FROM _lattice_observation_frames"), 1);
    auto opened = replay::open(db); ASSERT_TRUE(opened.scope);
    const auto barrier = opened.scope->capture_barrier();
    ASSERT_EQ(barrier.result.status, replay::code::ready); ASSERT_TRUE(barrier.has_cursor);
    EXPECT_GT(barrier.resume.frame_id, 0); EXPECT_EQ(barrier.snapshot.pruned_through, 2);
    EXPECT_EQ(barrier.resume.after_audit_id, 2);
    opened.scope.reset();
    auto same = replay::read_frames(db, barrier.resume);
    ASSERT_EQ(same.result.status, replay::code::ready); EXPECT_TRUE(same.at_head); EXPECT_EQ(same.row_count, 0);
    commit(db, {"c"});
    auto later = replay::read_frames(db, barrier.resume);
    ASSERT_EQ(later.result.status, replay::code::ready); ASSERT_EQ(later.row_count, 1);
    EXPECT_EQ(later.value(later.rows[0].global_id), "c"); EXPECT_TRUE(later.at_head);
}

TEST(ObservationReplay, ExistingCallerTransactionIsNeitherJoinedNorRolledBack) {
    database db(":memory:"); setup(db); db.begin_transaction(); db.execute("UPDATE Model SET value=4");
    auto rejected = replay::open(db);
    EXPECT_EQ(rejected.result.status, replay::code::invalid_context); EXPECT_FALSE(rejected.scope);
    EXPECT_TRUE(db.is_in_transaction()); EXPECT_EQ(scalar(db, "SELECT value FROM Model"), 4);
    db.rollback(); EXPECT_EQ(scalar(db, "SELECT value FROM Model"), 0);
}

TEST(ObservationReplay, ReadScopeRejectsCallerWritesControlsAndUnsafeFunctions) {
    database db(":memory:"); setup(db); auto opened = replay::open(db); ASSERT_TRUE(opened.scope);
    for (const auto* sql : {"UPDATE Model SET value=7", "COMMIT", "ROLLBACK", "CREATE TABLE wrong(id)",
                            "PRAGMA schema_version=99", "ATTACH ':memory:' AS other", "SELECT randomblob(10)"})
        EXPECT_THROW(db.execute(sql), lattice::db_error);
    EXPECT_EQ(scalar(db, "SELECT count(*) FROM Model"), 1);
    auto barrier = opened.scope->capture_barrier(); EXPECT_TRUE(barrier.has_cursor);
    opened.scope.reset(); settled(db); commit(db, {"still-writable"});
}

TEST(ObservationReplay, CancellationReleasesScopeAndRestoresOrdinaryBusyPolicy) {
    database db(":memory:"); setup(db); const auto start = origin(db); db.execute("PRAGMA busy_timeout=17");
    auto stop = std::make_shared<replay::stop_control>(); stop->cancelled.store(true);
    auto cancelled = replay::open(db, {}, stop);
    EXPECT_EQ(cancelled.result.status, replay::code::cancelled); EXPECT_FALSE(cancelled.scope); settled(db);
    stop->cancelled.store(false); auto opened = replay::open(db, {}, stop); ASSERT_TRUE(opened.scope);
    stop->cancelled.store(true); auto page = opened.scope->read_after(start);
    EXPECT_EQ(page.result.status, replay::code::cancelled); EXPECT_FALSE(page.has_cursor); settled(db);
    EXPECT_EQ(scalar(db, "PRAGMA busy_timeout"), 17); commit(db, {"after-cancel"});
}

TEST(ObservationReplay, WorkBudgetInterruptsCallerReadAndDestructorSettles) { bounded([] {
    database db(":memory:"); setup(db);
    replay::limits cap; cap.max_vm_steps = 1000000; cap.timeout_ms = 30000;
    auto opened = replay::open(db, cap); require(static_cast<bool>(opened.scope), "open work-limited reader");
    bool interrupted = false;
    try { db.query("WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<1000000000) SELECT count(*) FROM n"); }
    catch (const lattice::db_error&) { interrupted = true; }
    const auto stopped = opened.scope->capture_barrier();
    require(interrupted && stopped.result.status == replay::code::work_limit, "finite VM budget interrupts read");
    opened.scope.reset(); settled(db); commit(db, {"after-work-stop"});
}); }

TEST(ObservationReplay, ExpiredDeadlineReturnsNoCursorAndReleasesReader) { bounded([] {
    database db(":memory:"); setup(db); replay::limits cap; cap.timeout_ms = 1;
    auto opened = replay::open(db, cap);
    if (opened.scope) {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
        const auto value = opened.scope->capture_barrier();
        require(value.result.status == replay::code::deadline && !value.has_cursor, "expired scope rejects barrier");
    } else require(opened.result.status == replay::code::deadline, "only deadline may end initial short-budget admission");
    opened.scope.reset(); settled(db); commit(db, {"after-deadline"});
}); }

TEST(ObservationReplay, OversizedMetadataIsRejectedBeforeInspectorCopiesIt) {
    database db(":memory:"); setup(db);
    db.execute("UPDATE _lattice_observation_state SET ddl_fingerprint=?", {std::string(2048, 'x')});
    auto opened = replay::open(db);
    EXPECT_EQ(opened.result.status, replay::code::resource_limit); EXPECT_FALSE(opened.scope); settled(db);
}

TEST(ObservationReplay, EarlyScopeDestructionReleasesSnapshotAndAuthorizer) {
    database db(":memory:"); setup(db);
    { auto opened = replay::open(db); ASSERT_TRUE(opened.scope); EXPECT_EQ(scalar(db, "SELECT value FROM Model"), 0); }
    settled(db); db.execute("UPDATE Model SET value=6");
    EXPECT_EQ(scalar(db, "SELECT value FROM Model"), 6);
}

namespace {
replay::identity codec_identity(std::string_view text) {
    require(text.size() == 32, "codec fixture identity size");
    replay::identity value{};
    std::copy(text.begin(), text.end(), value.begin());
    return value;
}
replay::cursor codec_fixture() {
    replay::cursor value;
    value.store_uuid = codec_identity("0123456789abcdef0123456789abcdef");
    value.history_epoch = codec_identity("fedcba9876543210fedcba9876543210");
    value.frame_key = codec_identity("00112233445566778899aabbccddeeff");
    value.frame_id = 0x0123456789abcdefLL;
    value.after_audit_id = 0x7fedcba987654321LL;
    value.kind = replay::cursor_kind::frame;
    return value;
}
void same_cursor(const replay::cursor& actual, const replay::cursor& expected) {
    EXPECT_EQ(actual.store_uuid, expected.store_uuid);
    EXPECT_EQ(actual.history_epoch, expected.history_epoch);
    EXPECT_EQ(actual.frame_key, expected.frame_key);
    EXPECT_EQ(actual.frame_id, expected.frame_id);
    EXPECT_EQ(actual.after_audit_id, expected.after_audit_id);
    EXPECT_EQ(actual.kind, expected.kind);
}
std::string codec_text(const replay::encoded_cursor& bytes) { return {bytes.data(), bytes.size()}; }
void reject_codec_text(std::string_view text) {
    const auto sentinel = codec_fixture();
    auto output = sentinel;
    EXPECT_EQ(replay::decode_cursor(text, output), replay::code::invalid_cursor);
    same_cursor(output, sentinel);
}
} // namespace

TEST(ObservationReplay, CursorCodecKnownVectorPinsAllFieldsAndIntegerOrder) {
    const auto value = codec_fixture();
    replay::encoded_cursor text;
    ASSERT_EQ(replay::encode_cursor(value, text), replay::code::ready);
    EXPECT_EQ(text.size(), 139);
    EXPECT_EQ(codec_text(text),
        "lrc1:f:0123456789abcdef0123456789abcdef:fedcba9876543210fedcba9876543210:"
        "00112233445566778899aabbccddeeff:0123456789abcdef:7fedcba987654321");
    replay::cursor decoded;
    ASSERT_EQ(replay::decode_cursor(codec_text(text), decoded), replay::code::ready);
    same_cursor(decoded, value);
}

TEST(ObservationReplay, CursorCodecRoundTripsAllKindsAndNumericBounds) {
    const auto maximum = std::numeric_limits<int64_t>::max();
    auto value = codec_fixture();
    std::vector<replay::cursor> cases;
    value.kind = replay::cursor_kind::origin;
    value.frame_key = {}; value.frame_id = value.after_audit_id = 0;
    cases.push_back(value);
    value.kind = replay::cursor_kind::snapshot_barrier;
    for (const int64_t after : {int64_t{0}, int64_t{1}, maximum}) {
        value.after_audit_id = after; cases.push_back(value);
    }
    for (const auto kind : {replay::cursor_kind::frame, replay::cursor_kind::snapshot_barrier}) {
        value.kind = kind;
        for (const int64_t number : {int64_t{1}, maximum}) {
            value.frame_key = codec_fixture().frame_key;
            value.frame_id = value.after_audit_id = number; cases.push_back(value);
        }
    }
    for (const auto& original : cases) {
        SCOPED_TRACE(static_cast<int>(original.kind));
        replay::encoded_cursor text, repeated;
        ASSERT_EQ(replay::encode_cursor(original, text), replay::code::ready);
        replay::cursor decoded;
        ASSERT_EQ(replay::decode_cursor(codec_text(text), decoded), replay::code::ready);
        same_cursor(decoded, original);
        ASSERT_EQ(replay::encode_cursor(decoded, repeated), replay::code::ready);
        EXPECT_EQ(repeated, text);
    }
}

TEST(ObservationReplay, CursorCodecAbsentFrameKeyDiffersFromZeroHexIdentity) {
    auto value = codec_fixture();
    value.kind = replay::cursor_kind::snapshot_barrier;
    value.frame_id = 0; value.frame_key = {};
    replay::encoded_cursor absent, zero;
    ASSERT_EQ(replay::encode_cursor(value, absent), replay::code::ready);
    EXPECT_EQ(codec_text(absent).substr(73, 32), std::string(32, '-'));
    value.frame_id = 1; value.frame_key.fill('0');
    ASSERT_EQ(replay::encode_cursor(value, zero), replay::code::ready);
    EXPECT_EQ(codec_text(zero).substr(73, 32), std::string(32, '0'));
    replay::cursor decoded;
    ASSERT_EQ(replay::decode_cursor(codec_text(zero), decoded), replay::code::ready);
    same_cursor(decoded, value);
    auto wrong = codec_text(absent); wrong.replace(73, 32, 32, '0');
    reject_codec_text(wrong);
    wrong = codec_text(zero); wrong.replace(73, 32, 32, '-');
    reject_codec_text(wrong);
}

TEST(ObservationReplay, CursorCodecRejectsEveryTruncationAndOversizedInput) {
    replay::encoded_cursor encoded;
    ASSERT_EQ(replay::encode_cursor(codec_fixture(), encoded), replay::code::ready);
    const auto text = codec_text(encoded);
    reject_codec_text({});
    for (size_t length = 0; length != text.size(); ++length) {
        SCOPED_TRACE(length); reject_codec_text(std::string_view(text.data(), length));
    }
    reject_codec_text(text + 'x');
    reject_codec_text(text + '\0');
    const std::string oversized(4096, 'a');
    reject_codec_text(oversized);
}

TEST(ObservationReplay, CursorCodecRejectsVersionsTagsAndNoncanonicalBytes) {
    replay::encoded_cursor encoded;
    ASSERT_EQ(replay::encode_cursor(codec_fixture(), encoded), replay::code::ready);
    const auto canonical = codec_text(encoded);
    for (const auto version : {"lrc0:", "lrc2:", "LRC1:", "lrcx:"}) {
        auto text = canonical; text.replace(0, 5, version); reject_codec_text(text);
    }
    for (const char kind : {'0', 'F', 'x', '\0'}) {
        auto text = canonical; text[5] = kind; reject_codec_text(text);
    }
    for (const size_t separator : {4, 6, 39, 72, 105, 122}) {
        auto text = canonical; text[separator] = '/'; reject_codec_text(text);
    }
    for (const size_t field : {7, 40, 73, 106, 123}) {
        for (const char bad : {'A', 'g', ' ', '+', '-', '\0', static_cast<char>(0x80)}) {
            auto text = canonical; text[field] = bad; reject_codec_text(text);
        }
    }
    auto text = canonical; text[121] = 'F'; reject_codec_text(text);
    text = canonical; text[138] = '\n'; reject_codec_text(text);
}

TEST(ObservationReplay, CursorCodecRejectsIntegerOverflowAndInvalidWireShapes) {
    replay::encoded_cursor encoded;
    ASSERT_EQ(replay::encode_cursor(codec_fixture(), encoded), replay::code::ready);
    const auto canonical = codec_text(encoded);
    for (const size_t number : {106, 123}) {
        for (const char high : {'8', 'f'}) {
            auto text = canonical; text[number] = high; reject_codec_text(text);
        }
    }
    auto text = canonical; text[5] = 'o'; reject_codec_text(text);
    text = canonical; text.replace(106, 16, 16, '0'); reject_codec_text(text);
    text = canonical; text.replace(123, 16, 16, '0'); reject_codec_text(text);
    text[5] = 's'; reject_codec_text(text);
}

TEST(ObservationReplay, CursorCodecInvalidNativeShapesLeaveEncodingUnchanged) {
    const auto valid = codec_fixture();
    std::vector<replay::cursor> invalid;
    auto value = valid; value.store_uuid[0] = 'A'; invalid.push_back(value);
    value = valid; value.history_epoch[0] = '\0'; invalid.push_back(value);
    value = valid; value.frame_key[0] = 'G'; invalid.push_back(value);
    value = valid; value.frame_id = -1; invalid.push_back(value);
    value = valid; value.after_audit_id = -1; invalid.push_back(value);
    value = valid; value.frame_id = 0; invalid.push_back(value);
    value = valid; value.after_audit_id = 0; invalid.push_back(value);
    value = valid; value.frame_key = {}; invalid.push_back(value);
    value = valid; value.kind = static_cast<replay::cursor_kind>(99); invalid.push_back(value);
    value = valid; value.kind = replay::cursor_kind::origin; invalid.push_back(value);
    value.frame_id = value.after_audit_id = 0; invalid.push_back(value);
    value.frame_key = {}; value.after_audit_id = 1; invalid.push_back(value);
    value = valid; value.kind = replay::cursor_kind::snapshot_barrier; value.frame_id = 0; invalid.push_back(value);
    value = valid; value.kind = replay::cursor_kind::snapshot_barrier; value.frame_key = {}; invalid.push_back(value);
    invalid.push_back(replay::cursor{});
    for (const auto& cursor : invalid) {
        replay::encoded_cursor output; output.fill('!'); const auto before = output;
        EXPECT_EQ(replay::encode_cursor(cursor, output), replay::code::invalid_cursor);
        EXPECT_EQ(output, before);
    }
}

TEST(ObservationReplay, CursorCodecRealBarrierAndFramePersistAcrossReaderReopen) {
    File file; replay::encoded_cursor barrier_text, frame_text;
    {
        database writer(file.path.string()); setup(writer); commit(writer, {"before"});
        database reader(file.path.string(), database::open_mode::read_only);
        auto opened = replay::open(reader); ASSERT_TRUE(opened.scope);
        auto barrier = opened.scope->capture_barrier(); ASSERT_TRUE(barrier.has_cursor);
        ASSERT_EQ(opened.scope->finish().status, replay::code::ready); opened.scope.reset();
        ASSERT_EQ(replay::encode_cursor(barrier.resume, barrier_text), replay::code::ready);
        commit(writer, {"after"}); settled(reader);
    }
    {
        database reader(file.path.string(), database::open_mode::read_only);
        replay::cursor after;
        ASSERT_EQ(replay::decode_cursor(codec_text(barrier_text), after), replay::code::ready);
        EXPECT_EQ(after.kind, replay::cursor_kind::snapshot_barrier);
        auto page = replay::read_frames(reader, after);
        ASSERT_EQ(page.result.status, replay::code::ready); ASSERT_EQ(page.row_count, 1);
        EXPECT_EQ(page.value(page.rows[0].global_id), "after");
        ASSERT_EQ(replay::encode_cursor(page.next, frame_text), replay::code::ready); settled(reader);
    }
    {
        database reader(file.path.string(), database::open_mode::read_only);
        replay::cursor after;
        ASSERT_EQ(replay::decode_cursor(codec_text(frame_text), after), replay::code::ready);
        EXPECT_EQ(after.kind, replay::cursor_kind::frame);
        auto page = replay::read_frames(reader, after);
        ASSERT_EQ(page.result.status, replay::code::ready);
        EXPECT_TRUE(page.at_head); EXPECT_EQ(page.row_count, 0); settled(reader);
    }
}

TEST(ObservationReplay, CursorCodecDoesNotAuthenticateForeignResetOrForgedAnchors) {
    database first(":memory:"), second(":memory:"); setup(first); setup(second);
    const auto start = origin(first);
    replay::encoded_cursor text;
    ASSERT_EQ(replay::encode_cursor(start, text), replay::code::ready);
    replay::cursor decoded;
    ASSERT_EQ(replay::decode_cursor(codec_text(text), decoded), replay::code::ready);
    same_cursor(decoded, start);
    auto foreign = replay::read_frames(second, decoded);
    EXPECT_EQ(foreign.result.status, replay::code::foreign_store); EXPECT_FALSE(foreign.has_cursor);
    commit(first, {"first"}); auto page = replay::read_frames(first, decoded);
    ASSERT_EQ(page.result.status, replay::code::ready);
    auto forged = page.next; forged.frame_key[0] = forged.frame_key[0] == 'a' ? 'b' : 'a';
    ASSERT_EQ(replay::encode_cursor(forged, text), replay::code::ready);
    ASSERT_EQ(replay::decode_cursor(codec_text(text), decoded), replay::code::ready);
    auto rejected = replay::read_frames(first, decoded);
    EXPECT_EQ(rejected.result.status, replay::code::invalid_cursor); EXPECT_FALSE(rejected.has_cursor);
    ASSERT_EQ(replay::encode_cursor(start, text), replay::code::ready);
    ASSERT_EQ(replay::decode_cursor(codec_text(text), decoded), replay::code::ready);
    first.execute("UPDATE AuditLog SET operation='UPDATE' WHERE id=1");
    auto reset = replay::read_frames(first, decoded);
    EXPECT_EQ(reset.result.status, replay::code::history_reset); EXPECT_FALSE(reset.has_cursor);
}
#endif
