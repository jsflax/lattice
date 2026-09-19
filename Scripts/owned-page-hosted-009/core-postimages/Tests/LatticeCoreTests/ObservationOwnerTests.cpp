#ifndef SQLITE_CORE
#define SQLITE_CORE 1
#endif
#include "TestRuntime.hpp"
#include <lattice.hpp>
#include <bulk_mutation.hpp>
#include "../../Sources/LatticeSwiftCppBridge/src/observation_owner.hpp"
#include <csignal>
#include <cstdio>
#include <functional>
#include <limits>
#include <set>
#if !defined(__EMSCRIPTEN__)
#include <unistd.h>
namespace lattice::observation_owned {
// Only the test can pause between owned model collection and its barrier.
// There is no product callback/SQL escape, and both reads stay on this thread.
struct test_access {
    static std::unique_ptr<model_capture> begin(swift_lattice& owner) {
        return std::unique_ptr<model_capture>(new model_capture(owner, "OwnedModel", {}, {}));
    }
    static void collect(model_capture& value) { value.collect(); }
    static model_snapshot finish(model_capture& value) { return value.finish(); }
};
}
namespace {
using namespace lattice;
namespace owned = lattice::observation_owned;
namespace frames = lattice::observation_frames;
namespace replay = frames::replay;
void check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
SchemaVector owner_schema() {
    swift_schema_entry entry;
    entry.table_name = "OwnedModel";
    property_descriptor value;
    value.name = "value"; value.type = column_type::integer;
    entry.properties["value"] = value;
    return {entry};
}
std::unique_ptr<swift_lattice_ref> owner_ref(const swift_configuration& config, const SchemaVector& schema) {
#if LATTICE_HAS_FRT
    return std::unique_ptr<swift_lattice_ref>(swift_lattice_ref::create(config, schema));
#else
    return std::make_unique<swift_lattice_ref>(swift_lattice_ref::create(config, schema));
#endif
}
struct Fixture {
    TempDB file{"observation_owned"};
    SchemaVector schema = owner_schema();
    std::unique_ptr<swift_lattice_ref> ref = owner_ref(swift_configuration(file.str()), schema);
    lattice::swift_lattice& core() { return *ref->get(); }
    ~Fixture() { if (ref) { core().close(); core().close_read_db(); ref.reset(); } }
    void enable() {
        check(owned::enable(core(), "OwnedModel").code == frames::status::ready_integrity_only,
              "actual hooked owner installation");
    }
    void legacy(int64_t value) {
        swift_dynamic_object source;
        source.table_name = "OwnedModel"; source.properties = schema[0].properties;
        source.values["value"] = value;
        dynamic_object object(source); core().add(object);
    }
    int64_t scalar(const std::string& sql) {
        const auto rows = core().db().query(sql);
        check(rows.size() == 1 && rows[0].size() == 1, "fixture scalar cardinality");
        return std::get<int64_t>(rows[0].begin()->second);
    }
    int64_t audit_count() { return scalar("SELECT count(*) FROM AuditLog WHERE tableName='OwnedModel'"); }
    std::vector<std::unique_ptr<dynamic_object_ref>> rows() {
        std::vector<std::unique_ptr<dynamic_object_ref>> result;
        for (auto& row : core().objects("OwnedModel", std::nullopt, std::string("id ASC")))
            result.push_back(std::make_unique<dynamic_object_ref>(row));
        return result;
    }
    replay::page read(const replay::cursor& cursor) {
        database reader(file.str(), database::open_mode::read_only);
        return replay::read_frames(reader, cursor);
    }
};
struct Watch {
    lattice::swift_lattice& owner;
    std::string table;
    lattice_db::observer_id token;
    Watch(lattice::swift_lattice& source, std::string name,
          std::function<void(const std::vector<lattice::lattice_db::change_event>&)> callback)
        : owner(source), table(std::move(name)), token(static_cast<lattice::lattice_db&>(owner).add_table_observer(table, std::move(callback))) {}
    ~Watch() { static_cast<lattice::lattice_db&>(owner).remove_table_observer(table, token); }
};
void rejected(const std::function<void()>& body) {
    bool threw = false;
    try { body(); } catch (const std::exception&) { threw = true; }
    check(threw, "unsupported route must reject");
}
void bounded(const std::function<void()>& body) {
#if GTEST_HAS_DEATH_TEST && (defined(__APPLE__) || defined(__linux__))
    struct Restore { std::string value = ::testing::FLAGS_gtest_death_test_style;
        ~Restore() { ::testing::FLAGS_gtest_death_test_style = value; } } restore;
    ::testing::FLAGS_gtest_death_test_style = "threadsafe";
    ASSERT_EXIT({
        std::signal(SIGALRM, SIG_DFL);
        sigset_t unblocked; sigemptyset(&unblocked); sigaddset(&unblocked, SIGALRM);
        if (sigprocmask(SIG_UNBLOCK, &unblocked, nullptr)) _exit(2);
        alarm(10);
        try { body(); std::fputs("observation_owner_complete\n", stderr); _exit(0); }
        catch (const std::exception& error) { std::fprintf(stderr,"observation_owner_failure: %s\n",error.what()); _exit(1); }
    }, ::testing::ExitedWithCode(0), "observation_owner_complete");
#else
    body();
#endif
}
void committed(owned::transaction& transaction) {
    const auto result = transaction.commit();
    check(result.code == frames::outcome::committed && !result.transaction_open, "frame committed");
}
} // namespace

TEST(ObservationOwner, DefaultOffKeepsOrdinaryModelAndAuditBehavior) {
    bounded([] {
        Fixture fixture; fixture.legacy(7);
        check(fixture.scalar("SELECT value FROM OwnedModel") == 7 && fixture.audit_count() == 1,
              "legacy value and audit unchanged");
        check(fixture.scalar("SELECT count(*) FROM sqlite_master WHERE name LIKE '_lattice_observation_%'") == 0,
              "default off creates no private metadata");
        rejected([&] { owned::transaction transaction(fixture.core(), "OwnedModel"); });
        check(fixture.audit_count() == 1, "rejected unenabled owner makes no model audit");
    });
}
TEST(ObservationOwner, InstallationAndEmptyFrameDoNotPublishMetadataRows) {
    bounded([] {
        Fixture fixture;
        int events = 0;
        Watch model(fixture.core(), "OwnedModel", [&](const auto& changes) { events += changes.size(); });
        Watch state(fixture.core(), "_lattice_observation_state", [&](const auto& changes) { events += changes.size(); });
        Watch receipt(fixture.core(), "_lattice_observation_insert_receipt", [&](const auto& changes) { events += changes.size(); });
        Watch frames_watch(fixture.core(), "_lattice_observation_frames", [&](const auto& changes) { events += changes.size(); });
        Watch context(fixture.core(), "_lattice_observation_write_context", [&](const auto& changes) { events += changes.size(); });
        fixture.enable();
        { owned::transaction transaction(fixture.core(), "OwnedModel"); committed(transaction); }
        check(events == 0 && fixture.audit_count() == 0 &&
              fixture.scalar("SELECT count(*) FROM _lattice_observation_frames") == 0,
              "protocol-only commits have no row payload or fabricated frame");
    });
}
TEST(ObservationOwner, ScalarWritesProduceOneCompleteFrameWithRealAuditIdentities) {
    bounded([] {
        Fixture fixture; fixture.enable();
        auto start = owned::capture(fixture.core(), "OwnedModel");
        check(start.barrier.has_cursor && start.row_count == 0, "empty model barrier");
        int64_t id = 0;
        std::string key;
        {
            owned::transaction transaction(fixture.core(), "OwnedModel"); key = transaction.frame_key();
            id = transaction.insert(7);
            check(id > 0 && transaction.set(id, 9) == 1, "scalar row count");
            committed(transaction);
        }
        const auto audit = fixture.core().db().query("SELECT id,globalId,globalRowId,operation FROM AuditLog WHERE tableName='OwnedModel' ORDER BY id");
        check(audit.size() == 2, "real insert and update audit rows");
        auto page = fixture.read(start.barrier.resume);
        check(page.result.status == replay::code::ready && page.frame_count == 1 && page.row_count == 2 &&
              page.at_head && std::string(page.frames[0].key.data(),32) == key, "one exact frame");
        for (size_t i = 0; i < 2; ++i) {
            check(page.rows[i].id == std::get<int64_t>(audit[i].at("id")) &&
                  page.value(page.rows[i].global_id) == std::get<std::string>(audit[i].at("globalId")) &&
                  page.value(page.rows[i].global_row_id) == std::get<std::string>(audit[i].at("globalRowId")),
                  "exact persisted audit IDs and model UUID");
        }
        auto snapshot = owned::capture(fixture.core(), "OwnedModel");
        check(snapshot.barrier.has_cursor && snapshot.row_count == 1 && snapshot.rows[0].id == id &&
              snapshot.rows[0].value == 9 && snapshot.barrier.snapshot.audit_head == page.next.after_audit_id,
              "current model and exact barrier");
    });
}
TEST(ObservationOwner, RollbackDropsModelAuditFrameAndRowDelivery) {
    bounded([] {
        Fixture fixture; fixture.enable(); int calls = 0;
        Watch model(fixture.core(), "OwnedModel", [&](const auto&) { ++calls; });
        { owned::transaction transaction(fixture.core(), "OwnedModel"); transaction.insert(4);
          const auto result = transaction.rollback();
          check(result.code == frames::outcome::rolled_back && !result.transaction_open, "explicit rollback"); }
        { owned::transaction abandoned(fixture.core(), "OwnedModel"); abandoned.insert(5); }
        check(calls == 0 && fixture.audit_count() == 0 &&
              fixture.scalar("SELECT count(*) FROM OwnedModel") == 0 &&
              fixture.scalar("SELECT count(*) FROM _lattice_observation_frames") == 0,
              "rollback does not escape as data/frame/callback");
        { owned::transaction transaction(fixture.core(), "OwnedModel"); transaction.insert(6); committed(transaction); }
        check(calls == 1 && fixture.audit_count() == 1, "next commit has no rolled-back phantom");
    });
}
TEST(ObservationOwner, SelectedBatchUsesOwnedTopologyAndPreservesMaterializedValues) {
    bounded([] {
        Fixture fixture; fixture.enable();
        { owned::transaction transaction(fixture.core(), "OwnedModel"); transaction.insert(1); transaction.insert(2); committed(transaction); }
        auto rows = fixture.rows(); check(rows.size() == 2, "selected handles");
        rows[0]->enable_row_cache();
        auto start = owned::capture(fixture.core(), "OwnedModel");
        selected_mutation_batch batch;
        batch.add_object(*rows[0]); batch.add_object(*rows[1]); batch.add_object(*rows[0]);
        batch.increment_int64("value", 5);
        { owned::transaction transaction(fixture.core(), "OwnedModel");
          check(transaction.increment(batch) == 2 && fixture.core().db().changes() == 2, "deduplicated selected count");
          committed(transaction); }
        check(rows[0]->is_row_cache_enabled() && rows[0]->get_int("value") == 1 && rows[1]->get_int("value") == 7,
              "selected mutation keeps existing cache modes");
        auto page = fixture.read(start.barrier.resume);
        check(page.result.status == replay::code::ready && page.frame_count == 1 && page.row_count == 2,
              "selected batch is one exact transaction frame");
        auto snapshot = owned::capture(fixture.core(), "OwnedModel");
        check(snapshot.row_count == 2 && snapshot.rows[0].value == 6 && snapshot.rows[1].value == 7,
              "actual selected physical values");
    });
}
TEST(ObservationOwner, UnsupportedBodyRoutesRejectBeforeAnyMutation) {
    bounded([] {
        Fixture fixture; fixture.enable();
        { owned::transaction transaction(fixture.core(), "OwnedModel"); transaction.insert(1); committed(transaction); }
        auto rows = fixture.rows(); const auto before = fixture.audit_count();
        owned::transaction transaction(fixture.core(), "OwnedModel");
        selected_mutation_batch bad; bad.add_object(*rows[0]); bad.set("value", column_value_t(4.0));
        rejected([&] { (void)transaction.increment(bad); });
        rejected([&] { fixture.core().db().execute("DELETE FROM OwnedModel"); });
        rejected([&] { fixture.core().db().execute("UPDATE OwnedModel SET value=99"); });
        rejected([&] { fixture.core().db().execute("INSERT INTO AuditLog(tableName) VALUES('OwnedModel')"); });
        rejected([&] { fixture.core().db().execute("UPDATE _SyncControl SET disabled=1 WHERE id=1"); });
        rejected([&] { (void)fixture.core().db().query("SELECT changes(),total_changes()"); });
        check(fixture.scalar("SELECT value FROM OwnedModel") == 1 && fixture.audit_count() == before,
              "unsupported paths have no mutation effects");
        check(transaction.rollback().code == frames::outcome::rolled_back, "rejected body can roll back");
    });
}
TEST(ObservationOwner, WrapperCountsAndLastInsertRowidExcludeProtocolTail) {
    bounded([] {
        Fixture fixture; fixture.legacy(1);
        const auto prior_count = fixture.core().db().changes();
        const auto prior_rowid = fixture.scalar("SELECT last_insert_rowid()");
        fixture.enable();
        check(fixture.core().db().changes() == prior_count && fixture.scalar("SELECT last_insert_rowid()") == prior_rowid,
              "installation preserves wrapper result and rowid");
        { owned::transaction empty(fixture.core(), "OwnedModel");
          check(fixture.core().db().changes() == prior_count, "context admission preserves prior wrapper count");
          committed(empty); }
        check(fixture.core().db().changes() == prior_count && fixture.scalar("SELECT last_insert_rowid()") == prior_rowid,
              "empty frame preserves prior result");
        int64_t id;
        { owned::transaction transaction(fixture.core(), "OwnedModel"); id = transaction.insert(2); committed(transaction); }
        check(fixture.core().db().changes() == 1 && fixture.scalar("SELECT last_insert_rowid()") == id,
              "committed user result survives protocol tail");
        // Raw SQL counters are deliberately NOT restored outside the scope.
        check(fixture.scalar("SELECT total_changes()") > fixture.audit_count(), "documented protocol-inclusive SQL counter");
    });
}
TEST(ObservationOwner, EmptySelectionAndMissingRowKeepNativeCountSemantics) {
    bounded([] {
        Fixture fixture; fixture.enable(); int64_t id;
        { owned::transaction transaction(fixture.core(), "OwnedModel"); id = transaction.insert(8); committed(transaction); }
        const auto audit_before = fixture.audit_count();
        const auto frames_before = fixture.scalar("SELECT count(*) FROM _lattice_observation_frames");
        const auto prior_count = fixture.core().db().changes();
        selected_mutation_batch empty; empty.increment_int64("value", 1);
        { owned::transaction transaction(fixture.core(), "OwnedModel");
          check(transaction.increment(empty) == 0 && fixture.core().db().changes() == prior_count,
                "empty selection has no SQL and preserves previous wrapper count");
          committed(transaction); }
        check(fixture.core().db().changes() == prior_count, "empty selection count survives metadata tail");
        { owned::transaction transaction(fixture.core(), "OwnedModel");
          check(transaction.set(id + 1, 9) == 0 && fixture.core().db().changes() == 0,
                "missing-row UPDATE reports actual zero changes");
          committed(transaction); }
        check(fixture.core().db().changes() == 0 && fixture.audit_count() == audit_before &&
              fixture.scalar("SELECT count(*) FROM _lattice_observation_frames") == frames_before &&
              fixture.scalar("SELECT value FROM OwnedModel") == 8,
              "zero-row write preserves count without manufacturing an audit frame");
    });
}
TEST(ObservationOwner, ReentrantCallbackStartsNewFrameAfterNativeOwnershipRelease) {
    bounded([] {
        Fixture fixture; fixture.enable();
        int calls = 0; int64_t nested_id = 0;
        Watch model(fixture.core(), "OwnedModel", [&](const auto& changes) {
            check(!changes.empty(), "model callback payload");
            if (++calls == 1) {
                owned::transaction nested(fixture.core(), "OwnedModel");
                nested_id = nested.insert(22); committed(nested);
            }
        });
        { owned::transaction outer(fixture.core(), "OwnedModel"); outer.insert(11); committed(outer); }
        check(calls == 2 && nested_id > 0 && fixture.scalar("SELECT count(*) FROM OwnedModel") == 2 &&
              fixture.scalar("SELECT count(*) FROM _lattice_observation_frames WHERE kind='transaction'") == 2,
              "reentrant commit is separate complete frame without ownership deadlock");
        check(fixture.scalar("SELECT last_insert_rowid()") == nested_id && fixture.core().db().changes() == 1,
              "outer tail does not overwrite reentrant result");
    });
}
TEST(ObservationOwner, SnapshotModelAndBarrierStayTogetherAcrossConcurrentCommit) {
    bounded([] {
        Fixture fixture; fixture.enable(); int64_t id;
        { owned::transaction transaction(fixture.core(), "OwnedModel"); id = transaction.insert(1); committed(transaction); }
        auto capture = owned::test_access::begin(fixture.core());
        owned::test_access::collect(*capture);
        std::exception_ptr failure;
        std::thread writer([&] { try {
            owned::transaction transaction(fixture.core(), "OwnedModel");
            check(transaction.set(id,2) == 1, "concurrent update count"); committed(transaction);
        } catch (...) { failure = std::current_exception(); } });
        writer.join(); if (failure) std::rethrow_exception(failure);
        auto first = owned::test_access::finish(*capture); capture.reset();
        check(first.barrier.has_cursor && first.row_count == 1 && first.rows[0].value == 1,
              "owned model copy retains precommit snapshot");
        auto next = fixture.read(first.barrier.resume);
        check(next.result.status == replay::code::ready && next.frame_count == 1 && next.row_count == 1 &&
              next.value(next.rows[0].operation) == "UPDATE" &&
              next.rows[0].id > first.barrier.resume.after_audit_id,
              "concurrent committed update follows exact snapshot barrier");
        auto latest = owned::capture(fixture.core(), "OwnedModel");
        check(latest.row_count == 1 && latest.rows[0].value == 2, "new capture sees committed value");
    });
}
TEST(ObservationOwner, SnapshotCapsAndCancellationReturnNoPartialModelOrCursor) {
    bounded([] {
        Fixture fixture; fixture.enable();
        { owned::transaction transaction(fixture.core(), "OwnedModel"); transaction.insert(1); transaction.insert(2); committed(transaction); }
        owned::snapshot_limits limits; limits.max_rows = 1;
        auto capped = owned::capture(fixture.core(), "OwnedModel", limits);
        check(capped.barrier.result.status == replay::code::resource_limit && capped.row_count == 0 &&
              !capped.rows && !capped.barrier.has_cursor && capped.barrier.result.cleanup_ok,
              "row cap has no partial result");
        auto stop = std::make_shared<replay::stop_control>(); stop->cancelled.store(true);
        auto cancelled = owned::capture(fixture.core(), "OwnedModel", {}, stop);
        check(cancelled.barrier.result.status == replay::code::cancelled && !cancelled.barrier.has_cursor &&
              cancelled.row_count == 0 && !cancelled.rows, "cancelled owned capture has no partial cursor");
        auto retry = owned::capture(fixture.core(), "OwnedModel");
        check(retry.barrier.has_cursor && retry.row_count == 2, "failed capture retains no reader scope");
    });
}
TEST(ObservationOwner, OrdinaryWritersRemainExplicitlyFramingUnavailable) {
    bounded([] {
        Fixture fixture; fixture.enable();
        auto start = owned::capture(fixture.core(), "OwnedModel");
        fixture.legacy(3);
        auto page = fixture.read(start.barrier.resume);
        check(page.result.status == replay::code::framing_unavailable && !page.has_cursor && page.row_count == 0,
              "ordinary unowned route is an honest gap");
        check(fixture.scalar("SELECT count(*) FROM _lattice_observation_frames WHERE kind='framing_unavailable'") == 1,
              "ordinary audit row carries unavailable framing");
    });
}
TEST(ObservationOwner, RawEscapeDisabledAuditingAndSchemaDriftRefuseAdmission) {
    bounded([] {
        { Fixture fixture; (void)fixture.core().db().handle();
          rejected([&] { fixture.enable(); });
          check(fixture.scalar("SELECT count(*) FROM sqlite_master WHERE name='_lattice_observation_state'") == 0,
                "raw escape refused before metadata install"); }
        { Fixture fixture; fixture.enable(); fixture.core().db().execute("UPDATE _SyncControl SET disabled=1 WHERE id=1");
          rejected([&] { owned::transaction transaction(fixture.core(), "OwnedModel"); });
          check(fixture.audit_count() == 0, "disabled auditing cannot claim complete frame"); }
        { Fixture fixture; fixture.enable(); fixture.core().db().execute("CREATE TABLE Unrelated(id INTEGER)");
          rejected([&] { owned::transaction transaction(fixture.core(), "OwnedModel"); });
          check(fixture.audit_count() == 0 && fixture.scalar("SELECT count(*) FROM _lattice_observation_frames") == 0,
                "schema cookie change is not silently acknowledged"); }
    });
}

TEST(ObservationOwner, OwnedReplayReleasesReaderAndPageSurvivesParentClose) {
    bounded([] {
        Fixture fixture; fixture.enable();
        auto start = owned::capture(fixture.core(), "OwnedModel");
        int64_t id;
        { owned::transaction transaction(fixture.core(), "OwnedModel");
          id = transaction.insert(10); check(transaction.set(id, 11) == 1, "owned update");
          committed(transaction); }
        const auto count = fixture.core().db().changes();
        const auto rowid = fixture.scalar("SELECT last_insert_rowid()");
        auto page = owned::read_after(fixture.core(), "OwnedModel", start.barrier.resume);
        check(page.result.status == replay::code::ready && page.result.cleanup_ok &&
              page.has_cursor && page.at_head && page.frame_count == 1 && page.row_count == 2 &&
              page.rows[0].id == page.frames[0].first_audit_id &&
              page.rows[1].id == page.frames[0].last_audit_id &&
              page.value(page.rows[0].operation) == "INSERT" &&
              page.value(page.rows[1].operation) == "UPDATE" &&
              page.rows[0].row_id.value == id && page.rows[1].row_id.value == id,
              "owned replay preserves exact complete frame and real row identity");
        check(fixture.core().db().changes() == count && fixture.scalar("SELECT last_insert_rowid()") == rowid,
              "reader admission preserves writer result counters");
        const auto global_id = std::string(page.value(page.rows[0].global_row_id));
        { owned::transaction transaction(fixture.core(), "OwnedModel");
          check(transaction.set(id, 12) == 1, "writer remains usable while caller retains page");
          committed(transaction); }
        // A retained page must not pin the WAL snapshot it was read from.
        const auto checkpoint = fixture.core().db().query("PRAGMA wal_checkpoint(TRUNCATE)");
        check(checkpoint.size() == 1 && std::get<int64_t>(checkpoint[0].at("busy")) == 0 &&
              std::get<int64_t>(checkpoint[0].at("log")) == 0,
              "retained replay page has no WAL reader");
        auto next = owned::read_after(fixture.core(), "OwnedModel", page.next);
        check(next.result.status == replay::code::ready && next.frame_count == 1 && next.row_count == 1 &&
              next.rows[0].id > page.rows[1].id, "next demand reads later committed frame");
        fixture.core().close(); fixture.core().close_read_db(); fixture.ref.reset();
        check(page.value(page.rows[0].global_row_id) == global_id &&
              page.value(page.rows[1].operation) == "UPDATE" &&
              next.value(next.rows[0].operation) == "UPDATE", "owned page bytes outlive parent");
    });
}

TEST(ObservationOwner, OwnedReplayPreCancelledTurnSkipsClosedOwnerAdmission) {
    bounded([] {
        Fixture fixture; fixture.enable();
        auto start = owned::capture(fixture.core(), "OwnedModel");
        auto stop = std::make_shared<replay::stop_control>();
        stop->cancelled.store(true, std::memory_order_release);
        fixture.core().close(); fixture.core().close_read_db();
        std::filesystem::remove(fixture.file.path);
        // Without the early cancellation check this closed owner fails native
        // admission; a fresh READONLY open also cannot succeed on the absent file.
        auto page = owned::read_after(fixture.core(), "OwnedModel", start.barrier.resume, {}, stop);
        check(page.result.status == replay::code::cancelled && page.result.cleanup_ok &&
              !page.has_cursor && !page.frames && !page.rows && !page.text &&
              page.frame_count == 0 && page.row_count == 0 && page.allocated_bytes == 0 &&
              !std::filesystem::exists(fixture.file.path), "pre-cancelled turn has no native admission or partial result");
    });
}

TEST(ObservationOwner, OwnedReplayPreservesWholeFrameLimitAndForeignCursorFailures) {
    bounded([] {
        Fixture fixture; fixture.enable();
        auto start = owned::capture(fixture.core(), "OwnedModel");
        { owned::transaction transaction(fixture.core(), "OwnedModel");
          transaction.insert(1); transaction.insert(2); committed(transaction); }
        replay::limits limits; limits.max_rows = 1;
        auto small = owned::read_after(fixture.core(), "OwnedModel", start.barrier.resume, limits);
        check(small.result.status == replay::code::frame_too_large && small.result.cleanup_ok &&
              !small.has_cursor && small.row_count == 0 && !small.rows && !small.text,
              "whole-frame budget failure does not split or advance");
        Fixture other; other.enable();
        auto foreign = owned::read_after(other.core(), "OwnedModel", start.barrier.resume);
        check(foreign.result.status == replay::code::foreign_store && foreign.result.cleanup_ok &&
              !foreign.has_cursor && foreign.row_count == 0 && !foreign.rows,
              "foreign-store diagnostic is preserved");
        auto retry = owned::read_after(fixture.core(), "OwnedModel", start.barrier.resume);
        check(retry.result.status == replay::code::ready && retry.result.cleanup_ok &&
              retry.frame_count == 1 && retry.row_count == 2 && retry.has_cursor,
              "failed turns release resources and leave original cursor retryable");
    });
}

TEST(ObservationOwner, OwnedReplayPreservesUnframedGapAndRejectsEscapedWriter) {
    bounded([] {
        Fixture fixture; fixture.enable();
        auto start = owned::capture(fixture.core(), "OwnedModel");
        fixture.legacy(3);
        auto gap = owned::read_after(fixture.core(), "OwnedModel", start.barrier.resume);
        check(gap.result.status == replay::code::framing_unavailable && gap.result.cleanup_ok &&
              !gap.has_cursor && gap.row_count == 0 && !gap.rows && !gap.text,
              "ordinary writes remain an explicit non-advancing gap through owned reader");
        (void)fixture.core().db().handle();
        rejected([&] { (void)owned::read_after(fixture.core(), "OwnedModel", start.barrier.resume); });
        check(fixture.audit_count() == 1, "escaped-writer refusal has no write effects");
    });
}
#endif

#if defined(LATTICE_EXPERIMENTAL_OWNED_READ) && LATTICE_EXPERIMENTAL_OWNED_READ && !defined(__EMSCRIPTEN__)
#include <experimental_owned_read.hpp>
namespace {
using EdgePage = lattice::experimental_durable_page;
using EdgeStop = lattice::experimental_durable_stop_control;
using EdgeLimits = lattice::experimental_owned_read_limits;
std::string edge_token(const replay::cursor& cursor) {
    replay::encoded_cursor bytes;
    check(replay::encode_cursor(cursor, bytes) == replay::code::ready, "fixture canonical cursor");
    return std::string(bytes.data(), bytes.size());
}
EdgeStop edge_stop() {
    auto value = EdgeStop::make();
    check(last_bridge_error().empty() && value.is_valid(), "operation stop allocation");
    return value;
}
std::string edge_page_token(const EdgePage& page) {
    check(page.has_cursor() && page.cursor_byte_count() == 139, "exact returned cursor length");
    std::string result;
    for (uint64_t byte = 0; byte < 139; ++byte) {
        const auto value = page.cursor_byte(byte);
        check(last_bridge_error().empty(), "cursor getter did not seal a failure");
        result.push_back(static_cast<char>(value));
    }
    return result;
}
std::string edge_text(const EdgePage& page, uint64_t row, int32_t field) {
    const auto descriptor = page.text_field(row, field);
    check(last_bridge_error().empty(), "text descriptor did not seal a failure");
    check(!descriptor.is_null && descriptor.byte_count <= 1024, "bounded fixture text");
    std::string result;
    for (uint64_t byte = 0; byte < descriptor.byte_count; ++byte) {
        const auto value = page.text_byte(row, field, byte);
        check(last_bridge_error().empty(), "text getter did not seal a failure");
        result.push_back(static_cast<char>(value));
    }
    return result;
}
void edge_failure(const EdgePage& page, int32_t status) {
    check(page.status_code() == status && page.result().cleanup_ok &&
          !page.has_cursor() && !page.at_head() && page.frame_count() == 0 &&
          page.row_count() == 0 && page.text_bytes() == 0 &&
          page.allocated_backing_bytes() == 0, "non-advancing inline failure");
}
}

TEST(ObservationOwnedReadEdge, InvalidTransportRefusesBeforeClosedOwnerAdmission) {
    bounded([] {
        Fixture fixture; fixture.enable();
        const auto start = owned::capture(fixture.core(), "OwnedModel");
        const auto token = edge_token(start.barrier.resume);
        auto stop = edge_stop();
        fixture.core().close(); fixture.core().close_read_db();
        std::vector<std::string> invalid{token.substr(1), token + "x", token + '\0', ""};
        auto changed = token; changed[3] = '2'; invalid.push_back(changed);
        changed = token; changed[5] = 'x'; invalid.push_back(changed);
        changed = token; changed[6] = ';'; invalid.push_back(changed);
        changed = token; changed[7] = 'A'; invalid.push_back(changed);
        changed = token; changed[20] = '\0'; invalid.push_back(changed);
        changed = token; changed.replace(106, 16, "8000000000000000"); invalid.push_back(changed);
        for (const auto& bytes : invalid) {
            last_bridge_error() = "stale error must be cleared";
            auto page = experimental_owned_read(*fixture.ref, "OwnedModel", bytes, {}, stop);
            check(last_bridge_error().empty(), "transport refusal precedes throwing closed-owner admission");
            edge_failure(page, 3);
        }
    });
}

TEST(ObservationOwnedReadEdge, InvalidArgumentsAndLimitNarrowingRefuseBeforeAdmission) {
    bounded([] {
        Fixture fixture; fixture.enable();
        const auto start = owned::capture(fixture.core(), "OwnedModel");
        const auto token = edge_token(start.barrier.resume);
        auto stop = edge_stop();
        fixture.core().close(); fixture.core().close_read_db();
        auto empty_stop = experimental_owned_read(*fixture.ref, "OwnedModel", token, {}, EdgeStop{});
        check(last_bridge_error().empty(), "invalid default stop is not uncancellable fallback");
        edge_failure(empty_stop, 1);
        const std::vector<std::string> names{"", "_OwnedModel", "Owned.Model", "Owned Model",
            std::string(65, 'a'), std::string("Owned\0Model", 11), std::string(1, static_cast<char>(0xff))};
        for (const auto& model : names) {
            auto page = experimental_owned_read(*fixture.ref, model, token, {}, stop);
            check(last_bridge_error().empty(), "invalid model is checked before owner");
            edge_failure(page, 1);
        }
        std::vector<EdgeLimits> invalid;
        auto add = [&](auto mutate) { EdgeLimits value; mutate(value); invalid.push_back(value); };
        add([](auto& x) { x.max_frames = 0; });
        add([](auto& x) { x.max_frames = 257; });
        add([](auto& x) { x.max_frames = UINT64_MAX; });
        add([](auto& x) { x.max_rows = 0; });
        add([](auto& x) { x.max_rows = 4097; });
        add([](auto& x) { x.max_rows = UINT64_MAX; });
        add([](auto& x) { x.max_bytes = 0; });
        add([](auto& x) { x.max_bytes = UINT64_MAX; });
        add([](auto& x) { x.max_bytes = 8 * 1024 * 1024 + 1; });
        add([](auto& x) { x.max_bytes = sizeof(replay::page); }); // no room for fixed arrays
        add([](auto& x) { x.max_vm_steps = 127; });
        add([](auto& x) { x.max_vm_steps = 50000001; });
        add([](auto& x) { x.timeout_ms = 0; });
        add([](auto& x) { x.timeout_ms = -1; });
        add([](auto& x) { x.timeout_ms = 30001; });
        add([](auto& x) { x.timeout_ms = INT64_MAX; });
        for (const auto& limits : invalid) {
            auto page = experimental_owned_read(*fixture.ref, "OwnedModel", token, limits, stop);
            check(last_bridge_error().empty(), "limits refuse before narrowing or parent admission");
            edge_failure(page, 2);
        }
        // At both valid boundaries, a cancelled request gets past validation
        // but never reaches the closed parent. No large allocations are made.
        stop.cancel();
        EdgeLimits low; low.max_frames = 1; low.max_rows = 1;
        low.max_bytes = sizeof(replay::page) + sizeof(replay::frame_header) + sizeof(replay::audit_header);
        low.max_vm_steps = 128; low.timeout_ms = 1;
        EdgeLimits high; high.max_frames = 256; high.max_rows = 4096;
        high.max_bytes = 8 * 1024 * 1024; high.max_vm_steps = 50000000; high.timeout_ms = 30000;
        for (const auto& limits : {low, high}) {
            auto page = experimental_owned_read(*fixture.ref, std::string(64, 'a'), token, limits, stop);
            check(last_bridge_error().empty(), "inclusive boundary validation");
            edge_failure(page, 12);
        }
    });
}

TEST(ObservationOwnedReadEdge, ClosedOwnerExceptionIsSealedAndNonAdvancing) {
    bounded([] {
        Fixture fixture; fixture.enable();
        const auto start = owned::capture(fixture.core(), "OwnedModel");
        const auto token = edge_token(start.barrier.resume);
        auto stop = edge_stop();
        fixture.core().close(); fixture.core().close_read_db();
        auto page = experimental_owned_read(*fixture.ref, "OwnedModel", token, {}, stop);
        const auto error = last_bridge_error();
        check(error == "observation owner closed", "native admission exception is sealed unchanged");
        edge_failure(page, 1);
    });
}

TEST(ObservationOwnedReadEdge, DefaultOffAndRawEscapeKeepExistingOwnerGuards) {
    bounded([] {
        Fixture ordinary;
        replay::cursor origin; origin.store_uuid.fill('1'); origin.history_epoch.fill('2');
        auto stop = edge_stop();
        auto disabled = experimental_owned_read(*ordinary.ref, "OwnedModel", edge_token(origin), {}, stop);
        const auto disabled_error = last_bridge_error();
        check(disabled_error == "observation snapshot not enabled", "reader does not activate private owner");
        edge_failure(disabled, 1);
        check(ordinary.scalar("SELECT count(*) FROM sqlite_master WHERE name LIKE '_lattice_observation_%'") == 0,
              "default-off read installs nothing");
        Fixture escaped; escaped.enable();
        auto start = owned::capture(escaped.core(), "OwnedModel");
        (void)escaped.core().db().handle();
        auto refused = experimental_owned_read(*escaped.ref, "OwnedModel", edge_token(start.barrier.resume), {}, stop);
        const auto escaped_error = last_bridge_error();
        check(escaped_error == "observation owner raw handle escaped", "genuine caller escape still rejects");
        edge_failure(refused, 1);
        check(escaped.audit_count() == 0, "refused reader does not mutate audit");
    });
}

TEST(ObservationOwnedReadEdge, RealPageReleasesWalAndRetainsNoOwner) {
    bounded([] {
        Fixture fixture; fixture.enable();
        const auto start = owned::capture(fixture.core(), "OwnedModel");
        const auto token = edge_token(start.barrier.resume);
        std::weak_ptr<lattice::swift_lattice> lifetime = swift_lattice_ref::shared_for_lattice(fixture.ref->get());
        check(!lifetime.expired(), "actual owner lifetime observed without retention");
        int64_t id;
        std::string key;
        { owned::transaction transaction(fixture.core(), "OwnedModel");
          key = transaction.frame_key(); id = transaction.insert(10);
          check(transaction.set(id, 11) == 1, "actual owned update"); committed(transaction); }
        const auto changes = fixture.core().db().changes();
        const auto rowid = fixture.scalar("SELECT last_insert_rowid()");
        auto stop = edge_stop();
        const swift_lattice_ref& immutable_ref = *fixture.ref;
        auto page = experimental_owned_read(immutable_ref, "OwnedModel", token, {}, stop);
        check(last_bridge_error().empty(), "successful sealed owning read");
        check(page.status_code() == 0 && page.result().cleanup_ok && page.at_head() &&
              page.frame_count() == 1 && page.row_count() == 2 && page.has_cursor(), "complete actual page");
        check(fixture.core().db().changes() == changes && fixture.scalar("SELECT last_insert_rowid()") == rowid,
              "owning forwarder preserves writer result counters");
        const auto frame = page.frame(0);
        check(last_bridge_error().empty(), "frame getter");
        check(frame.row_offset == 0 && frame.row_count == 2, "whole frame range");
        for (uint64_t byte = 0; byte < 32; ++byte) {
            const auto value = page.frame_key_byte(0, byte);
            check(last_bridge_error().empty(), "frame key getter");
            check(value == static_cast<uint8_t>(key[byte]), "actual committed frame identity");
        }
        for (uint64_t row = 0; row < 2; ++row) {
            const auto value = page.integer_field(row, 0);
            check(last_bridge_error().empty(), "row identity getter");
            check(!value.is_null && value.value == id, "actual row identity");
            const auto audit = page.audit_id(row);
            check(last_bridge_error().empty(), "audit identity getter");
            check(audit == (row == 0 ? frame.first_audit_id : frame.last_audit_id), "exact frame audit boundaries");
        }
        check(edge_text(page, 0, 1) == "OwnedModel" && edge_text(page, 0, 2) == "INSERT" &&
              edge_text(page, 1, 2) == "UPDATE", "real stored audit headers");
        const auto global_id = edge_text(page, 0, 3);
        const auto next_token = edge_page_token(page);
        replay::cursor next;
        check(replay::decode_cursor(next_token, next) == replay::code::ready &&
              next.kind == replay::cursor_kind::frame && next.frame_id == frame.id &&
              next.after_audit_id == frame.last_audit_id, "canonical next cursor is actual frame end");
        const auto snapshot = page.snapshot();
        check(snapshot.audit_head == frame.last_audit_id, "snapshot preserved through adoption");
        { owned::transaction transaction(fixture.core(), "OwnedModel");
          check(transaction.set(id, 12) == 1, "writer remains usable with retained edge page"); committed(transaction); }
        const auto checkpoint = fixture.core().db().query("PRAGMA wal_checkpoint(TRUNCATE)");
        check(checkpoint.size() == 1 && std::get<int64_t>(checkpoint[0].at("busy")) == 0 &&
              std::get<int64_t>(checkpoint[0].at("log")) == 0, "retained bridge page has no WAL reader");
        auto copy = page; page = EdgePage{};
        fixture.core().close(); fixture.core().close_read_db(); fixture.ref.reset();
        check(lifetime.expired(), "returned page and stop do not retain native owner");
        check(edge_text(copy, 0, 3) == global_id && edge_text(copy, 1, 2) == "UPDATE" &&
              edge_page_token(copy) == next_token && copy.snapshot().audit_head == snapshot.audit_head,
              "copied immutable payload and cursor survive actual owner destruction");
    });
}

TEST(ObservationOwnedReadEdge, StopAliasesPreCancelAndIndependentStopStillReads) {
    bounded([] {
        Fixture fixture; fixture.enable();
        auto start = owned::capture(fixture.core(), "OwnedModel");
        const auto token = edge_token(start.barrier.resume);
        auto stop = edge_stop(); auto alias = stop; auto independent = edge_stop();
        check(alias.same_operation(stop) && !independent.same_operation(stop), "operation-local stop identity");
        alias.cancel(); alias.cancel();
        fixture.core().close(); fixture.core().close_read_db(); std::filesystem::remove(fixture.file.path);
        auto cancelled = experimental_owned_read(*fixture.ref, "OwnedModel", token, {}, stop);
        check(last_bridge_error().empty(), "pre-cancelled edge skips throwing closed-owner admission");
        edge_failure(cancelled, 12);
        check(!std::filesystem::exists(fixture.file.path), "pre-cancel does not recreate absent store");
        Fixture other; other.enable(); auto other_start = owned::capture(other.core(), "OwnedModel");
        { owned::transaction transaction(other.core(), "OwnedModel"); transaction.insert(7); committed(transaction); }
        auto page = experimental_owned_read(*other.ref, "OwnedModel", edge_token(other_start.barrier.resume), {}, independent);
        check(last_bridge_error().empty(), "independent read has no sealed error");
        check(!independent.is_cancelled() && page.status_code() == 0 && page.result().cleanup_ok &&
              page.has_cursor() && page.frame_count() == 1 && page.row_count() == 1,
              "cancellation of one alias does not cancel another operation");
    });
}

TEST(ObservationOwnedReadEdge, WholeFrameForeignStoreAndUnframedGapStayDistinct) {
    bounded([] {
        Fixture fixture; fixture.enable(); auto start = owned::capture(fixture.core(), "OwnedModel");
        const auto token = edge_token(start.barrier.resume); auto stop = edge_stop();
        { owned::transaction transaction(fixture.core(), "OwnedModel");
          transaction.insert(1); transaction.insert(2); committed(transaction); }
        EdgeLimits limits; limits.max_rows = 1;
        auto too_large = experimental_owned_read(*fixture.ref, "OwnedModel", token, limits, stop);
        check(last_bridge_error().empty(), "whole-frame failure is a native diagnostic");
        edge_failure(too_large, 10);
        check(too_large.result().boundary_frame_id > 0 && too_large.snapshot().audit_head > 0,
              "whole-frame failure preserves boundary and snapshot");
        Fixture foreign; foreign.enable();
        auto wrong_store = experimental_owned_read(*foreign.ref, "OwnedModel", token, {}, stop);
        check(last_bridge_error().empty(), "foreign store failure is not a bridge exception");
        edge_failure(wrong_store, 4);
        auto retry = experimental_owned_read(*fixture.ref, "OwnedModel", token, {}, stop);
        check(last_bridge_error().empty() && retry.status_code() == 0 && retry.row_count() == 2,
              "failure did not advance input cursor or retain reader resources");
        auto next = edge_page_token(retry); fixture.legacy(3);
        auto gap = experimental_owned_read(*fixture.ref, "OwnedModel", next, {}, stop);
        check(last_bridge_error().empty(), "unframed write has a native gap diagnostic");
        edge_failure(gap, 8);
        check(gap.result().boundary_frame_id > 0 && gap.snapshot().audit_head > retry.snapshot().audit_head,
              "unframed gap preserves its known boundary and snapshot");
    });
}
#endif
