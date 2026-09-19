#include "TestRuntime.hpp"
#include <lattice/observation_metadata.hpp>
#include <lattice/db.hpp>

namespace {
namespace metadata = lattice::observation_metadata;
using lattice::database;

// The native installer's current contract is a plain, exclusively owned
// SQLite database. No lattice_db hooks are installed by this fixture.
void create_audit(database& db) {
    db.execute(R"SQL(CREATE TABLE AuditLog(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        globalId TEXT UNIQUE COLLATE NOCASE,
        tableName TEXT, operation TEXT, rowId INTEGER, globalRowId TEXT,
        changedFields TEXT, changedFieldsNames TEXT,
        isFromRemote INTEGER DEFAULT 0, isSynchronized INTEGER DEFAULT 0,
        timestamp REAL DEFAULT 0, synthesized INTEGER DEFAULT 0
    ))SQL");
}
int64_t scalar(database& db, const std::string& sql) {
    const auto rows = db.query(sql);
    if (rows.size() != 1 || rows[0].size() != 1) throw std::runtime_error("fixture scalar missing");
    return std::get<int64_t>(rows[0].begin()->second);
}
metadata::result inspect(database& db) {
    db.execute("BEGIN");
    try {
        (void)db.query("SELECT count(*) FROM main.sqlite_schema");
        auto result = metadata::inspect_in_snapshot(db);
        db.execute("ROLLBACK");
        return result;
    } catch (...) { db.execute("ROLLBACK"); throw; }
}
size_t objects(database& db) {
    return static_cast<size_t>(scalar(db,
        "SELECT count(*) FROM main.sqlite_schema WHERE name GLOB '_lattice_observation_*'"));
}
void insert(database& db, const std::string& id) {
    db.execute("INSERT INTO AuditLog(globalId,tableName,operation,rowId,globalRowId,changedFields,changedFieldsNames) "
               "VALUES(?,'M','INSERT',1,'r','{}','[]')", {id});
}
}

TEST(ObservationMetadata, OwnCommitSurvivesReopenAndPreservesPrunedSequenceBaseline) {
    TempDB file("observation_metadata_install");
    std::string store, epoch;
    {
        database db(file.str()); create_audit(db);
        db.execute("INSERT INTO AuditLog(id,globalId) VALUES(9,'old')");
        db.execute("DELETE FROM AuditLog");
        const auto result = metadata::install(db);
        ASSERT_EQ(result.code, metadata::status::ready_integrity_only) << result.message;
        ASSERT_TRUE(result.value);
        EXPECT_EQ(result.scope, metadata::visibility::committed_by_this_call);
        EXPECT_TRUE(result.installed_now);
        EXPECT_EQ(result.value->ddl_fingerprint, "406bd310227e4ec8");
        EXPECT_EQ(result.value->audit_head, 9);
        EXPECT_EQ(result.value->capture_started_after, 9);
        EXPECT_EQ(result.value->pruned_through, 0);
        store = result.value->store_uuid; epoch = result.value->history_epoch;
        EXPECT_EQ(objects(db), 6u);
        EXPECT_TRUE(sqlite3_get_autocommit(db.handle()));
    }
    database reopened(file.str());
    const auto current = inspect(reopened);
    ASSERT_EQ(current.code, metadata::status::ready_integrity_only) << current.message;
    ASSERT_TRUE(current.value);
    EXPECT_EQ(current.value->store_uuid, store);
    EXPECT_EQ(current.value->history_epoch, epoch);
    const auto again = metadata::install(reopened);
    EXPECT_EQ(again.code, metadata::status::ready_integrity_only);
    EXPECT_FALSE(again.installed_now);
    insert(reopened, "new");
    const auto after = inspect(reopened);
    ASSERT_TRUE(after.value);
    EXPECT_EQ(after.value->audit_head, 10);
    EXPECT_EQ(after.value->history_epoch, epoch);
}

TEST(ObservationMetadata, EveryInstallationFaultRollsBackWithoutTouchingAuditRows) {
    for (int fault = 0; fault != 9; ++fault) {
        SCOPED_TRACE(fault);
        database db(":memory:"); create_audit(db); insert(db, "existing");
        const auto result = metadata::install(db, {.fail_after_statement = fault});
        EXPECT_EQ(result.code, metadata::status::database_error);
        EXPECT_EQ(result.why, metadata::reason::injected_failure);
        EXPECT_FALSE(result.owner_must_rollback);
        EXPECT_TRUE(sqlite3_get_autocommit(db.handle()));
        EXPECT_EQ(objects(db), 0u);
        EXPECT_EQ(scalar(db, "SELECT count(*) FROM AuditLog WHERE globalId='existing'"), 1);
        EXPECT_EQ(metadata::install(db).code, metadata::status::ready_integrity_only);
    }
}

TEST(ObservationMetadata, CallerWriteSavepointReturnsUncommittedAndOuterRollbackRemovesIt) {
    database db(":memory:"); create_audit(db);
    db.execute("BEGIN IMMEDIATE"); insert(db, "outer");
    const auto result = metadata::install_in_write_transaction(db);
    ASSERT_EQ(result.code, metadata::status::ready_integrity_only) << result.message;
    EXPECT_EQ(result.scope, metadata::visibility::pending_outer_commit);
    EXPECT_EQ(sqlite3_txn_state(db.handle(), "main"), SQLITE_TXN_WRITE);
    EXPECT_EQ(objects(db), 6u);
    db.execute("ROLLBACK");
    EXPECT_EQ(objects(db), 0u);
    EXPECT_EQ(scalar(db, "SELECT count(*) FROM AuditLog"), 0);
}

TEST(ObservationMetadata, CallerWriteFaultRollsBackOnlyInstallerSavepoint) {
    for (int fault = 0; fault != 9; ++fault) {
        SCOPED_TRACE(fault);
        database db(":memory:"); create_audit(db);
        db.execute("BEGIN IMMEDIATE"); insert(db, "outer");
        const auto result = metadata::install_in_write_transaction(db, {.fail_after_statement = fault});
        EXPECT_EQ(result.code, metadata::status::database_error);
        EXPECT_EQ(result.why, metadata::reason::injected_failure);
        EXPECT_FALSE(result.owner_must_rollback);
        EXPECT_EQ(sqlite3_txn_state(db.handle(), "main"), SQLITE_TXN_WRITE);
        EXPECT_EQ(objects(db), 0u);
        EXPECT_EQ(scalar(db, "SELECT count(*) FROM AuditLog WHERE globalId='outer'"), 1);
        db.execute("COMMIT");
        EXPECT_EQ(inspect(db).code, metadata::status::not_installed);
    }
}

TEST(ObservationMetadata, InspectionAndInstallationRequireTheirDeclaredTransactionContexts) {
    database db(":memory:"); create_audit(db);
    EXPECT_EQ(metadata::inspect_in_snapshot(db).why, metadata::reason::snapshot_required);
    EXPECT_EQ(metadata::install_in_write_transaction(db).why, metadata::reason::write_transaction_required);
    db.execute("BEGIN");
    EXPECT_EQ(metadata::inspect_in_snapshot(db).why, metadata::reason::snapshot_required);
    EXPECT_EQ(metadata::install(db).why, metadata::reason::autocommit_required);
    (void)db.query("SELECT * FROM AuditLog");
    EXPECT_EQ(metadata::inspect_in_snapshot(db).code, metadata::status::not_installed);
    EXPECT_EQ(metadata::install_in_write_transaction(db).why, metadata::reason::write_transaction_required);
    db.execute("ROLLBACK"); db.close();
    EXPECT_EQ(metadata::install(db).why, metadata::reason::closed_connection);
}

TEST(ObservationMetadata, DisabledLocalTriggersAndNonpositiveOrMalformedSequenceFailClosed) {
    {
        database db(":memory:"); create_audit(db);
        int enabled = 1;
        ASSERT_EQ(sqlite3_db_config(db.handle(), SQLITE_DBCONFIG_ENABLE_TRIGGER, 0, &enabled), SQLITE_OK);
        EXPECT_EQ(metadata::install(db).code, metadata::status::triggers_disabled);
        EXPECT_EQ(objects(db), 0u);
    }
    for (const auto& sql : {
        "INSERT INTO AuditLog(id,globalId) VALUES(0,'zero')",
        "INSERT INTO AuditLog(id,globalId) VALUES(-1,'negative')",
        "INSERT INTO sqlite_sequence(name,seq) VALUES('AuditLog',-1)",
        "INSERT INTO sqlite_sequence(name,seq) VALUES('AuditLog','bad')",
        "INSERT INTO sqlite_sequence(name,seq) VALUES('AuditLog',1),('AuditLog',2)"}) {
        SCOPED_TRACE(sql);
        database db(":memory:"); create_audit(db); db.execute(sql);
        EXPECT_EQ(metadata::install(db).code, metadata::status::integrity_uncertain);
        EXPECT_EQ(objects(db), 0u);
    }
}

TEST(ObservationMetadata, StrictTriggerForeignKeyTempAndReservedInventoriesNeverRepair) {
    const std::vector<std::pair<std::string, metadata::status>> cases{
        {"CREATE TRIGGER unexpected AFTER INSERT ON AuditLog BEGIN SELECT 1; END", metadata::status::unsupported_trigger_inventory},
        {"CREATE TABLE incoming(id INTEGER REFERENCES AuditLog(id))", metadata::status::unsupported_foreign_key_inventory},
        {"CREATE TEMP VIEW AuditLog AS SELECT 1 AS id", metadata::status::unsupported_temp_inventory},
        {"CREATE TEMP TRIGGER shadow AFTER INSERT ON main.AuditLog BEGIN SELECT 1; END", metadata::status::unsupported_temp_inventory},
        {"CREATE TABLE _lattice_observation_unknown(id INTEGER)", metadata::status::integrity_uncertain},
        {"CREATE UNIQUE INDEX unsupported_unique ON AuditLog(rowId)", metadata::status::unsupported_audit_shape}
    };
    for (const auto& [sql, expected] : cases) {
        SCOPED_TRACE(sql);
        database db(":memory:"); create_audit(db); db.execute(sql);
        const auto before = scalar(db, "SELECT count(*) FROM main.sqlite_schema");
        EXPECT_EQ(metadata::install(db).code, expected);
        EXPECT_EQ(scalar(db, "SELECT count(*) FROM main.sqlite_schema"), before);
    }
}

TEST(ObservationMetadata, PartialChangedDefinitionAndCookieMismatchRemainUnrepaired) {
    for (const auto& sql : {
        "DROP TABLE _lattice_observation_insert_receipt",
        "DROP TRIGGER _lattice_observation_audit_ad_v1",
        "CREATE INDEX unauthorized ON _lattice_observation_state(audit_head)",
        "CREATE TABLE unrelated_after_install(id INTEGER)"}) {
        SCOPED_TRACE(sql);
        database db(":memory:"); create_audit(db);
        ASSERT_EQ(metadata::install(db).code, metadata::status::ready_integrity_only);
        db.execute(sql);
        const auto before = scalar(db, "SELECT count(*) FROM main.sqlite_schema");
        EXPECT_EQ(metadata::install(db).code, metadata::status::integrity_uncertain);
        EXPECT_EQ(scalar(db, "SELECT count(*) FROM main.sqlite_schema"), before);
    }
}

TEST(ObservationMetadata, SingletonTypesBoundsAndFormatAreValidatedWithoutReseeding) {
    const std::vector<std::pair<std::string, metadata::status>> cases{
        {"DELETE FROM _lattice_observation_state", metadata::status::integrity_uncertain},
        {"DELETE FROM _lattice_observation_insert_receipt", metadata::status::integrity_uncertain},
        {"UPDATE _lattice_observation_state SET format_version=2", metadata::status::unsupported_format},
        {"UPDATE _lattice_observation_state SET store_uuid='bad'", metadata::status::integrity_uncertain},
        {"UPDATE _lattice_observation_state SET audit_head='bad'", metadata::status::integrity_uncertain},
        {"UPDATE _lattice_observation_state SET capture_started_after=1", metadata::status::integrity_uncertain},
        {"UPDATE _lattice_observation_state SET schema_cookie=-1", metadata::status::integrity_uncertain},
        {"UPDATE _lattice_observation_insert_receipt SET conflicting_audit_id=0", metadata::status::integrity_uncertain}
    };
    for (const auto& [sql, expected] : cases) {
        SCOPED_TRACE(sql);
        database db(":memory:"); create_audit(db);
        ASSERT_EQ(metadata::install(db).code, metadata::status::ready_integrity_only);
        db.execute("PRAGMA ignore_check_constraints=ON"); db.execute(sql);
        EXPECT_EQ(inspect(db).code, expected);
        EXPECT_EQ(metadata::install(db).code, expected);
    }
}

TEST(ObservationMetadata, BookkeepingAndIgnoredDuplicatesPreserveEpochButSemanticEditRotatesIt) {
    database db(":memory:"); create_audit(db);
    const auto original = metadata::install(db);
    ASSERT_TRUE(original.value);
    insert(db, "same");
    db.execute("INSERT OR IGNORE INTO AuditLog(globalId) VALUES('SAME'),('same')");
    db.execute("UPDATE AuditLog SET isSynchronized=1");
    auto current = inspect(db); ASSERT_TRUE(current.value);
    EXPECT_EQ(current.value->history_epoch, original.value->history_epoch);
    EXPECT_EQ(current.value->audit_head, 1);
    EXPECT_GT(scalar(db, "SELECT seq FROM sqlite_sequence WHERE name='AuditLog'"), 1);
    db.execute("UPDATE AuditLog SET _rowid_=50");
    current = inspect(db); ASSERT_TRUE(current.value);
    EXPECT_NE(current.value->history_epoch, original.value->history_epoch);
    EXPECT_EQ(current.value->epoch_reason, "semantic_update");
    EXPECT_EQ(current.value->audit_head, 50);
    EXPECT_EQ(current.value->capture_started_after, 50);
}

TEST(ObservationMetadata, DeleteFloorAndReplaceConflictRemainTransactional) {
    for (int recursive : {0, 1}) {
        SCOPED_TRACE(recursive);
        database db(":memory:"); create_audit(db);
        db.execute("PRAGMA recursive_triggers=" + std::to_string(recursive));
        const auto original = metadata::install(db); ASSERT_TRUE(original.value);
        insert(db, "same"); insert(db, "other");
        db.execute("INSERT OR REPLACE INTO AuditLog(globalId) VALUES('SAME')");
        auto current = inspect(db); ASSERT_TRUE(current.value);
        EXPECT_EQ(current.value->pruned_through, 1);
        EXPECT_EQ(current.value->audit_head, 3);
        EXPECT_EQ(current.value->history_epoch, original.value->history_epoch);
        db.execute("BEGIN IMMEDIATE"); db.execute("DELETE FROM AuditLog WHERE id=3");
        const auto pending = metadata::inspect_in_snapshot(db); ASSERT_TRUE(pending.value);
        EXPECT_EQ(pending.value->pruned_through, 3);
        db.execute("ROLLBACK");
        current = inspect(db); ASSERT_TRUE(current.value);
        EXPECT_EQ(current.value->pruned_through, 1);
    }
}
