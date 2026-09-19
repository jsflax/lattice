#include "TestRuntime.hpp"
#include <lattice/observation_frames.hpp>
#include <lattice/db.hpp>

namespace {
namespace frames = lattice::observation_frames;
using lattice::database;
void schema(database& db) {
    db.execute(R"SQL(CREATE TABLE AuditLog(
        id INTEGER PRIMARY KEY AUTOINCREMENT,globalId TEXT UNIQUE COLLATE NOCASE,
        tableName TEXT,operation TEXT,rowId INTEGER,globalRowId TEXT,
        changedFields TEXT,changedFieldsNames TEXT,
        isFromRemote INTEGER DEFAULT 0,isSynchronized INTEGER DEFAULT 0,
        timestamp REAL DEFAULT 0,synthesized INTEGER DEFAULT 0))SQL");
}
void setup(database& db) {
    schema(db);
    const auto result=frames::install(db);
    if (result.code!=frames::status::ready_integrity_only) throw std::runtime_error(result.message);
}
int64_t integer(database& db,const std::string& sql) {
    const auto rows=db.query(sql);
    if(rows.size()!=1 || rows.front().size()!=1) throw std::runtime_error("Missing fixture integer");
    return std::get<int64_t>(rows.front().begin()->second);
}
std::string text(database& db,const std::string& sql) {
    const auto rows=db.query(sql);
    if(rows.size()!=1 || rows.front().size()!=1) throw std::runtime_error("Missing fixture text");
    return std::get<std::string>(rows.front().begin()->second);
}
void append(database& db,const std::string& id) {
    db.execute("INSERT INTO main.AuditLog(globalId,tableName,operation,rowId,globalRowId) VALUES(?,'M','INSERT',1,'r')",{id});
}
frames::result inspect(database& db) {
    db.execute("BEGIN");
    try {
        (void)db.query("SELECT name FROM main.sqlite_schema LIMIT 1");
        auto value=frames::inspect_in_snapshot(db); db.execute("ROLLBACK"); return value;
    } catch (...) { db.execute("ROLLBACK"); throw; }
}
void context_empty(database& db) {
    EXPECT_EQ(integer(db,"SELECT count(*) FROM main._lattice_observation_write_context WHERE frame_key IS NULL AND history_epoch IS NULL"),1);
}
// A real rollback-journal reader holds SHARED while the writer owns RESERVED.
// COMMIT must obtain EXCLUSIVE and returns BUSY with a zero busy timeout. There
// are no fixture callbacks, sleeps, competing worker threads, or hook overrides.
// Use a R/W descriptor but only BEGIN/SELECT/ROLLBACK on this peer. The
// platform's O_RDONLY peer produces SQLITE_IOERR_LOCK/EBADF at writer BEGIN,
// independently reproduced without Core. A database R/W constructor would
// switch the file back to WAL, so this fixture owns the raw peer explicitly.
struct reader_deleter {
    void operator()(sqlite3* reader) const noexcept { if (reader) sqlite3_close_v2(reader); }
};
using reader_owner = std::unique_ptr<sqlite3, reader_deleter>;
reader_owner open_rollback_journal_reader(const std::string& path) {
    sqlite3* raw = nullptr;
    const int rc = sqlite3_open_v2(path.c_str(), &raw,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX, nullptr);
    reader_owner reader(raw);
    if (rc != SQLITE_OK) throw std::runtime_error(raw ? sqlite3_errmsg(raw) : "Reader open failed");
    return reader;
}
void reader_sql(sqlite3* reader, const char* sql) {
    if (sqlite3_exec(reader, sql, nullptr, nullptr, nullptr) != SQLITE_OK)
        throw std::runtime_error(sqlite3_errmsg(reader));
}
void hold_reader(sqlite3* reader) {
    reader_sql(reader,"BEGIN");
    reader_sql(reader,"SELECT * FROM main.AuditLog");
    ASSERT_EQ(sqlite3_txn_state(reader,"main"),SQLITE_TXN_READ);
}
// Installed only after the last owner/protocol operation. This fixture's fixed
// trace callback observes teardown; it performs no SQL, allocation or logging.
// Its stack state outlives the connection, including after database moves.
struct optimize_trace {
    int calls = 0;
    static int callback(unsigned kind, void* context, void* statement, void*) noexcept {
        if (kind == SQLITE_TRACE_STMT) {
            const char* sql = sqlite3_sql(static_cast<sqlite3_stmt*>(statement));
            if (sql && std::strcmp(sql,"PRAGMA optimize") == 0)
                ++static_cast<optimize_trace*>(context)->calls;
        }
        return 0;
    }
};
void observe_teardown(database& db, optimize_trace& trace) {
    if (sqlite3_trace_v2(db.handle(),SQLITE_TRACE_STMT,optimize_trace::callback,&trace) != SQLITE_OK)
        throw std::runtime_error("Teardown trace installation failed");
}
}

TEST(ObservationFrame, FreshFormatTwoDoesNotUpgradeOrModifyQualifiedFormatOne) {
    database old(":memory:"); schema(old);
    ASSERT_EQ(lattice::observation_metadata::install(old).code,frames::status::ready_integrity_only);
    const auto before=text(old,"SELECT ddl_fingerprint FROM _lattice_observation_state");
    EXPECT_NE(frames::install(old).code,frames::status::ready_integrity_only);
    EXPECT_EQ(text(old,"SELECT ddl_fingerprint FROM _lattice_observation_state"),before);
    EXPECT_EQ(integer(old,"SELECT format_version FROM _lattice_observation_state"),1);
    database fresh(":memory:"); setup(fresh);
    EXPECT_EQ(integer(fresh,"SELECT format_version FROM _lattice_observation_state"),2);
    EXPECT_EQ(inspect(fresh).code,frames::status::ready_integrity_only);
}

TEST(ObservationFrame, EveryInstallationFaultRollsBackAllFormatTwoObjects) {
    for(int fault=0;fault<15;++fault) {
        SCOPED_TRACE(fault);
        database db(":memory:"); schema(db); append(db,"old");
        const auto failed=frames::install(db,{.fail_after_statement=fault});
        EXPECT_EQ(failed.why,frames::reason::injected_failure);
        EXPECT_FALSE(failed.owner_must_rollback);
        EXPECT_TRUE(sqlite3_get_autocommit(db.handle()));
        EXPECT_EQ(integer(db,"SELECT count(*) FROM sqlite_schema WHERE name GLOB '_lattice_observation_*'"),0);
        EXPECT_EQ(integer(db,"SELECT count(*) FROM AuditLog"),1);
    }
}

TEST(ObservationFrame, OwnCommitIsDurableAndGroupsExactlyOneActualTransaction) {
    TempDB path("frame_commit"); std::string key;
    {
        database db(path.str()); setup(db);
        { frames::write_scope writer(db); key=writer.frame_key(); append(db,"a");
          const auto inserted=db.query("INSERT INTO main.AuditLog(globalId) VALUES(?) RETURNING id",{std::string("b")});
          ASSERT_EQ(inserted.size(),1u); EXPECT_EQ(std::get<int64_t>(inserted.front().at("id")),2);
          EXPECT_EQ(writer.commit().code,frames::outcome::committed); }
        context_empty(db);
    }
    database reopened(path.str());
    const auto inspected=inspect(reopened);
    EXPECT_EQ(inspected.code,frames::status::ready_integrity_only)
        << inspected.message << " reason=" << static_cast<int>(inspected.why)
        << " storedCookie=" << integer(reopened,"SELECT schema_cookie FROM _lattice_observation_state")
        << " actualCookie=" << integer(reopened,"PRAGMA main.schema_version")
        << " statTables=" << integer(reopened,"SELECT count(*) FROM sqlite_schema WHERE name GLOB 'sqlite_stat*'");
    EXPECT_EQ(integer(reopened,"SELECT count(*) FROM _lattice_observation_frames"),1);
    EXPECT_EQ(integer(reopened,"SELECT record_count FROM _lattice_observation_frames"),2);
    EXPECT_EQ(text(reopened,"SELECT frame_key FROM _lattice_observation_frames"),key);
    EXPECT_EQ(text(reopened,"SELECT kind FROM _lattice_observation_frames"),"transaction");
    EXPECT_EQ(integer(reopened,"SELECT last_audit_id-first_audit_id FROM _lattice_observation_frames"),1);
}

TEST(ObservationFrame, EmptyAndFullyRolledBackTransactionsLeaveNoFrame) {
    database db(":memory:"); setup(db);
    { frames::write_scope empty(db); EXPECT_EQ(empty.commit().code,frames::outcome::committed); }
    { frames::write_scope writer(db); append(db,"rollback"); EXPECT_EQ(writer.rollback().code,frames::outcome::rolled_back); }
    { frames::write_scope abandoned(db); append(db,"destructor"); }
    EXPECT_EQ(integer(db,"SELECT count(*) FROM AuditLog"),0);
    EXPECT_EQ(integer(db,"SELECT count(*) FROM _lattice_observation_frames"),0);
    context_empty(db);
}

TEST(ObservationFrame, NestedSavepointsKeepOuterIdentityAndRetractRolledBackRecords) {
    database db(":memory:"); setup(db);
    frames::write_scope writer(db); const auto key=writer.frame_key(); append(db,"a");
    const auto first=writer.savepoint(); append(db,"b");
    const auto second=writer.savepoint(); append(db,"c");
    writer.rollback_to(first); EXPECT_ANY_THROW(writer.release(second));
    append(db,"d"); writer.release(first); EXPECT_ANY_THROW(writer.rollback_to(first));
    EXPECT_EQ(writer.commit().code,frames::outcome::committed);
    EXPECT_EQ(integer(db,"SELECT count(*) FROM AuditLog"),2);
    EXPECT_EQ(integer(db,"SELECT count(*) FROM AuditLog WHERE globalId IN ('a','d')"),2);
    EXPECT_EQ(integer(db,"SELECT count(*) FROM _lattice_observation_frames"),1);
    EXPECT_EQ(integer(db,"SELECT record_count FROM _lattice_observation_frames"),2);
    EXPECT_EQ(text(db,"SELECT frame_key FROM _lattice_observation_frames"),key);
}

TEST(ObservationFrame, UnknownWritersRemainWritableWithoutInventedTransactionBoundaries) {
    database db(":memory:"); setup(db);
    db.execute("BEGIN IMMEDIATE"); append(db,"raw-a"); append(db,"raw-b"); db.execute("COMMIT");
    EXPECT_EQ(integer(db,"SELECT count(*) FROM _lattice_observation_frames WHERE kind='framing_unavailable'"),2);
    EXPECT_EQ(integer(db,"SELECT count(*) FROM _lattice_observation_frames WHERE kind='transaction'"),0);
    context_empty(db);
    { frames::write_scope writer(db); append(db,"owned"); EXPECT_EQ(writer.commit().code,frames::outcome::committed); }
    EXPECT_EQ(integer(db,"SELECT count(*) FROM _lattice_observation_frames WHERE kind='transaction'"),1);
}

TEST(ObservationFrame, CallerTransactionAndUnsafeControlsAreRefusedWithoutCommittingIt) {
    database db(":memory:"); setup(db);
    db.execute("BEGIN IMMEDIATE"); append(db,"prior");
    EXPECT_ANY_THROW({ frames::write_scope bad(db); });
    EXPECT_FALSE(sqlite3_get_autocommit(db.handle())); db.execute("ROLLBACK");
    frames::write_scope writer(db);
    for(const auto* sql:{"COMMIT","ROLLBACK","SAVEPOINT user","CREATE TABLE unsafe(id)",
                         "PRAGMA writable_schema=ON","UPDATE _lattice_observation_write_context SET frame_key=NULL,history_epoch=NULL"}) {
        SCOPED_TRACE(sql); EXPECT_ANY_THROW(db.execute(sql));
    }
    append(db,"allowed"); EXPECT_EQ(writer.commit().code,frames::outcome::committed);
    EXPECT_EQ(integer(db,"SELECT count(*) FROM AuditLog"),1);
}

TEST(ObservationFrame, BusyCommitRestoresSameContextAndAllowsOnlyResolution) {
    TempDB path("frame_busy"); database db(path.str());
    setup(db); db.execute("PRAGMA journal_mode=DELETE"); db.execute("PRAGMA busy_timeout=0");
    auto reader=open_rollback_journal_reader(path.str());
    ASSERT_EQ(text(db,"PRAGMA journal_mode"),"delete"); hold_reader(reader.get());
    frames::write_scope writer(db); const auto key=writer.frame_key(); append(db,"a");
    const auto busy=writer.commit();
    EXPECT_EQ(busy.code,frames::outcome::retry_commit_or_rollback); EXPECT_EQ(busy.sqlite_code&255,SQLITE_BUSY);
    EXPECT_TRUE(busy.transaction_open); EXPECT_EQ(writer.current_phase(),frames::phase::resolving_commit);
    EXPECT_EQ(text(db,"SELECT frame_key FROM _lattice_observation_write_context"),key);
    EXPECT_ANY_THROW(append(db,"forbidden"));
    EXPECT_ANY_THROW(writer.savepoint());
    reader_sql(reader.get(),"ROLLBACK");
    EXPECT_EQ(writer.commit().code,frames::outcome::committed); context_empty(db);
    EXPECT_EQ(integer(db,"SELECT record_count FROM _lattice_observation_frames"),1);
    EXPECT_EQ(text(db,"SELECT frame_key FROM _lattice_observation_frames"),key);
}

TEST(ObservationFrame, FailedContextRestorationPoisonsWritesUntilExplicitRollback) {
    TempDB path("frame_restore"); database db(path.str());
    setup(db); db.execute("PRAGMA journal_mode=DELETE"); db.execute("PRAGMA busy_timeout=0");
    auto reader=open_rollback_journal_reader(path.str());
    ASSERT_EQ(text(db,"PRAGMA journal_mode"),"delete"); hold_reader(reader.get());
    frames::write_scope writer(db,{.fail_next_context_restore=true}); append(db,"a");
    EXPECT_EQ(writer.commit().code,frames::outcome::rollback_required);
    EXPECT_EQ(writer.current_phase(),frames::phase::rollback_only);
    EXPECT_ANY_THROW(append(db,"forbidden")); EXPECT_EQ(writer.commit().code,frames::outcome::invalid_context);
    reader_sql(reader.get(),"ROLLBACK"); EXPECT_EQ(writer.rollback().code,frames::outcome::rolled_back);
    EXPECT_EQ(integer(db,"SELECT count(*) FROM AuditLog"),0); context_empty(db);
}

TEST(ObservationFrame, RollbackFailureIsReportedAndRetryResolvesWithoutPublishing) {
    database db(":memory:"); setup(db);
    frames::write_scope writer(db,{.fail_next_rollback=true}); append(db,"a");
    const auto failed=writer.rollback(); EXPECT_EQ(failed.code,frames::outcome::rollback_required);
    EXPECT_TRUE(failed.transaction_open); EXPECT_ANY_THROW(append(db,"forbidden"));
    EXPECT_EQ(writer.rollback().code,frames::outcome::rolled_back);
    EXPECT_EQ(integer(db,"SELECT count(*) FROM _lattice_observation_frames"),0); context_empty(db);
}

TEST(ObservationFrame, AutomaticRollbackIsUnknownToOwnerAndCannotRestartUnframedWrites) {
    database db(":memory:"); setup(db);
    frames::write_scope writer(db); append(db,"a");
    EXPECT_ANY_THROW(db.execute("INSERT OR ROLLBACK INTO AuditLog(globalId) VALUES('a')"));
    EXPECT_TRUE(sqlite3_get_autocommit(db.handle()));
    EXPECT_ANY_THROW(append(db,"forbidden"));
    EXPECT_EQ(writer.commit().code,frames::outcome::outcome_unknown);
    EXPECT_EQ(integer(db,"SELECT count(*) FROM AuditLog"),0); context_empty(db);
}

TEST(ObservationFrame, PartialDeletionAndLaterExtensionWithdrawThroughWholeFrame) {
    database db(":memory:"); setup(db);
    { frames::write_scope writer(db); append(db,"a"); append(db,"b");
      db.execute("DELETE FROM AuditLog WHERE globalId='a'"); append(db,"c");
      EXPECT_EQ(writer.commit().code,frames::outcome::committed); }
    EXPECT_EQ(integer(db,"SELECT invalidated FROM _lattice_observation_frames"),1);
    EXPECT_EQ(integer(db,"SELECT pruned_through= (SELECT last_audit_id FROM _lattice_observation_frames) FROM _lattice_observation_state"),1);
    EXPECT_EQ(integer(db,"SELECT count(*) FROM AuditLog"),2);
}

TEST(ObservationFrame, ReplaceConflictWithdrawsWholePriorFrameWithRecursiveTriggersOff) {
    database db(":memory:"); setup(db); db.execute("PRAGMA recursive_triggers=OFF");
    { frames::write_scope writer(db); append(db,"a"); append(db,"b"); EXPECT_EQ(writer.commit().code,frames::outcome::committed); }
    const auto end=integer(db,"SELECT last_audit_id FROM _lattice_observation_frames");
    db.execute("INSERT OR REPLACE INTO AuditLog(globalId) VALUES('a')");
    EXPECT_EQ(integer(db,"SELECT invalidated FROM _lattice_observation_frames WHERE kind='transaction'"),1);
    EXPECT_GE(integer(db,"SELECT pruned_through FROM _lattice_observation_state"),end);
    EXPECT_EQ(integer(db,"SELECT count(*) FROM _lattice_observation_frames WHERE kind='framing_unavailable'"),1);
}

TEST(ObservationFrame, IndependentPhysicalOwnersDoNotShareFrameKeysOrPermitAttachedWrites) {
    TempDB a("frame_owner_a"), b("frame_owner_b");
    database first(a.str()),second(b.str()); setup(first); setup(second);
    const auto uuidA=text(first,"SELECT store_uuid FROM _lattice_observation_state");
    const auto uuidB=text(second,"SELECT store_uuid FROM _lattice_observation_state"); EXPECT_NE(uuidA,uuidB);
    { frames::write_scope x(first),y(second); append(first,"same"); append(second,"same");
      EXPECT_NE(x.frame_key(),y.frame_key()); EXPECT_EQ(x.commit().code,frames::outcome::committed);
      EXPECT_EQ(y.rollback().code,frames::outcome::rolled_back); }
    first.execute("ATTACH DATABASE ? AS peer",{b.str()});
    { frames::write_scope x(first); EXPECT_ANY_THROW(first.execute("INSERT INTO peer.AuditLog(globalId) VALUES('denied')"));
      EXPECT_EQ(x.commit().code,frames::outcome::committed); }
    EXPECT_EQ(integer(first,"SELECT count(*) FROM AuditLog"),1);
    EXPECT_EQ(integer(second,"SELECT count(*) FROM AuditLog"),0);
}

TEST(ObservationFrame, CommittedNonemptyContextIsIntegrityFailureAndNeverAdopted) {
    database db(":memory:"); setup(db);
    db.execute("UPDATE _lattice_observation_write_context SET frame_key=lower(hex(randomblob(16))),history_epoch=(SELECT history_epoch FROM _lattice_observation_state)");
    EXPECT_EQ(inspect(db).code,frames::status::integrity_uncertain);
    EXPECT_ANY_THROW({ frames::write_scope writer(db); });
    EXPECT_TRUE(sqlite3_get_autocommit(db.handle()));
}

TEST(ObservationFrame, DestructorPolicyPreservesUnownedDefaultAndPrivateOptIn) {
    optimize_trace unowned, owned;
    {
        database ordinary(":memory:"); schema(ordinary);
        observe_teardown(ordinary,unowned);
    }
    {
        database observation(":memory:"); setup(observation);
        observe_teardown(observation,owned);
    }
    EXPECT_GE(unowned.calls,1);
    EXPECT_EQ(owned.calls,0);
}

TEST(ObservationFrame, DestructorPolicyFollowsMoveConstructionAndAssignment) {
    for (const bool assign : {false,true}) {
        SCOPED_TRACE(assign);
        optimize_trace transferred, reused;
        {
            database source(":memory:"); setup(source);
            observe_teardown(source,transferred);
            {
                std::unique_ptr<database> target;
                if (assign) {
                    target=std::make_unique<database>(":memory:");
                    *target=std::move(source);
                } else target=std::make_unique<database>(std::move(source));
                EXPECT_EQ(source.handle(),nullptr);
                EXPECT_NE(target->handle(),nullptr);
            }
            // A new ordinary connection assigned to the moved-from wrapper
            // must retain the source connection's default maintenance policy.
            source=database(":memory:");
            observe_teardown(source,reused);
        }
        EXPECT_EQ(transferred.calls,0);
        EXPECT_GE(reused.calls,1);
    }
}

TEST(ObservationFrame, FailedInstallationStillDefersTeardown) {
    optimize_trace failed_owner;
    {
        database db(":memory:"); schema(db);
        const auto failed=frames::install(db,{.fail_after_statement=0});
        ASSERT_EQ(failed.why,frames::reason::injected_failure);
        EXPECT_FALSE(failed.owner_must_rollback);
        EXPECT_TRUE(sqlite3_get_autocommit(db.handle()));
        EXPECT_EQ(integer(db,"SELECT count(*) FROM sqlite_schema WHERE name GLOB '_lattice_observation_*'"),0);
        observe_teardown(db,failed_owner);
    }
    EXPECT_EQ(failed_owner.calls,0);
}

TEST(ObservationFrame, FailedInspectionNeverAcknowledgesUnrelatedOrRestoredDDL) {
    for (const bool restore_trigger : {false,true}) {
        SCOPED_TRACE(restore_trigger);
        TempDB path("frame_unknown_ddl");
        int64_t original_cookie=0, changed_cookie=0;
        {
            database installed(path.str()); setup(installed);
            original_cookie=integer(installed,"SELECT schema_cookie FROM _lattice_observation_state");
        }
        optimize_trace failed_owner;
        {
            database db(path.str());
            if (restore_trigger) {
                const auto definition=text(db,"SELECT sql FROM sqlite_schema WHERE name='_lattice_observation_audit_ai_v2'");
                db.execute("DROP TRIGGER _lattice_observation_audit_ai_v2");
                db.execute(definition);
            } else db.execute("CREATE TABLE unrelated(id INTEGER PRIMARY KEY)");
            changed_cookie=integer(db,"PRAGMA main.schema_version");
            ASSERT_NE(changed_cookie,original_cookie);
            const auto failed=inspect(db);
            EXPECT_EQ(failed.code,frames::status::integrity_uncertain);
            EXPECT_EQ(failed.why,frames::reason::schema_changed);
            EXPECT_EQ(integer(db,"SELECT schema_cookie FROM _lattice_observation_state"),original_cookie);
            observe_teardown(db,failed_owner);
        }
        EXPECT_EQ(failed_owner.calls,0);
        database verify(path.str(),database::open_mode::read_only);
        EXPECT_EQ(integer(verify,"PRAGMA main.schema_version"),changed_cookie);
        EXPECT_EQ(integer(verify,"SELECT schema_cookie FROM _lattice_observation_state"),original_cookie);
        const auto failed=inspect(verify);
        EXPECT_EQ(failed.code,frames::status::integrity_uncertain);
        EXPECT_EQ(failed.why,frames::reason::schema_changed);
    }
}

TEST(ObservationFrame, InvalidatedEndIndexAndFloorRetractWithSavepointRollback) {
    database db(":memory:"); setup(db);
    EXPECT_EQ(integer(db,"SELECT count(*) FROM pragma_index_list('_lattice_observation_frames','main') "
                        "WHERE name='_lattice_observation_invalidated_end' AND partial=1"),1);
    { frames::write_scope first(db); append(db,"a"); append(db,"b");
      ASSERT_EQ(first.commit().code,frames::outcome::committed); }
    frames::write_scope next(db);
    const auto point=next.savepoint();
    db.execute("DELETE FROM AuditLog WHERE globalId='a'");
    EXPECT_EQ(integer(db,"SELECT pruned_through FROM _lattice_observation_state"),2);
    EXPECT_EQ(integer(db,"SELECT max(last_audit_id) FROM _lattice_observation_frames "
                        "INDEXED BY _lattice_observation_invalidated_end WHERE invalidated=1"),2);
    next.rollback_to(point);
    EXPECT_EQ(integer(db,"SELECT pruned_through FROM _lattice_observation_state"),0);
    EXPECT_EQ(integer(db,"SELECT count(*) FROM _lattice_observation_frames "
                        "INDEXED BY _lattice_observation_invalidated_end WHERE invalidated=1"),0);
    append(db,"c"); next.release(point);
    ASSERT_EQ(next.commit().code,frames::outcome::committed);
    EXPECT_EQ(integer(db,"SELECT count(*) FROM AuditLog"),3);
    EXPECT_EQ(integer(db,"SELECT count(*) FROM _lattice_observation_frames"),2);
}
