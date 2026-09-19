#include <lattice/observation_frames.hpp>
#include <stdexcept>
#include <thread>
#include <cstring>
#include <exception>
#include <lattice/db.hpp>
#include <array>
#include <algorithm>
#include <atomic>
#include <climits>
#include <iomanip>
#include <sstream>
#include <string_view>
#include <utility>
#include <vector>

#if !defined(__EMSCRIPTEN__)
namespace lattice::observation_frames {
// No callback, allocation or SQL. All callers hold the exclusively owned
// connection mutex; the fixed policy survives failure and follows moves.
struct database_maintenance_access {
    static sqlite3* handle(database& owner) noexcept { return owner.internal_handle(); }
    static void defer_automatic_optimize(database& owner) noexcept {
        owner.defer_destructor_optimize_ = true;
    }
};
namespace {
// Private format-2 derivative; format-1 source/receipts remain unchanged.
constexpr std::array<std::string_view, 15> install_sql = {
R"OBS(CREATE TABLE _lattice_observation_state (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    format_version INTEGER NOT NULL CHECK (format_version = 2),
    ddl_fingerprint TEXT NOT NULL,
    schema_cookie INTEGER NOT NULL,
    store_uuid TEXT NOT NULL CHECK (
        length(store_uuid) = 32 AND store_uuid NOT GLOB '*[^0-9a-f]*'),
    history_epoch TEXT NOT NULL CHECK (
        length(history_epoch) = 32 AND history_epoch NOT GLOB '*[^0-9a-f]*'),
    epoch_reason TEXT NOT NULL CHECK (epoch_reason IN (
        'installation', 'id_reuse', 'semantic_update',
        'explicit_reset', 'integrity_repair')),
    audit_head INTEGER NOT NULL CHECK (audit_head >= 0),
    capture_started_after INTEGER NOT NULL CHECK (
        capture_started_after >= 0 AND capture_started_after <= audit_head),
    pruned_through INTEGER NOT NULL CHECK (
        pruned_through >= 0 AND pruned_through <= audit_head)
);)OBS",
R"OBS(CREATE TABLE _lattice_observation_insert_receipt (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    conflicting_audit_id INTEGER
);)OBS",
R"OBS(INSERT INTO _lattice_observation_state
    (id, format_version, ddl_fingerprint, schema_cookie,
     store_uuid, history_epoch, epoch_reason,
     audit_head, capture_started_after, pruned_through)
VALUES
    (1, 2, :ddl_fingerprint, 0,
     lower(hex(randomblob(16))), lower(hex(randomblob(16))), 'installation',
     :initial_head, :initial_head, 0);)OBS",
R"OBS(INSERT INTO _lattice_observation_insert_receipt (id, conflicting_audit_id)
VALUES (1, NULL);)OBS",
R"OBS(CREATE TRIGGER _lattice_observation_audit_bi_v2
BEFORE INSERT ON AuditLog
BEGIN
    SELECT CASE WHEN
        (SELECT count(*) FROM _lattice_observation_state
         WHERE id = 1 AND format_version = 2) <> 1
        OR (SELECT count(*) FROM _lattice_observation_insert_receipt
            WHERE id = 1) <> 1
        THEN RAISE(ABORT, 'observation metadata missing or incompatible')
    END;
    UPDATE _lattice_observation_insert_receipt
    SET conflicting_audit_id = (
        SELECT id FROM AuditLog WHERE globalId = NEW.globalId LIMIT 1)
    WHERE id = 1;
END;)OBS",
R"OBS(CREATE TRIGGER _lattice_observation_audit_ai_v2
AFTER INSERT ON AuditLog
BEGIN
    SELECT CASE WHEN
        (SELECT count(*) FROM _lattice_observation_state
         WHERE id = 1 AND format_version = 2) <> 1
        OR (SELECT count(*) FROM _lattice_observation_insert_receipt
            WHERE id = 1) <> 1
        THEN RAISE(ABORT, 'observation metadata missing or incompatible')
    END;
    SELECT CASE WHEN NEW.id <= (SELECT audit_head FROM _lattice_observation_state WHERE id=1)
        AND (SELECT frame_key FROM _lattice_observation_write_context WHERE id=1) IS NOT NULL
        THEN RAISE(ABORT, 'owned observation frame cannot reuse audit IDs') END;
    UPDATE _lattice_observation_frames SET invalidated=1
    WHERE history_epoch=(SELECT history_epoch FROM _lattice_observation_state WHERE id=1
          AND (SELECT conflicting_audit_id FROM _lattice_observation_insert_receipt WHERE id=1) IS NOT NULL)
      AND first_audit_id <= (SELECT conflicting_audit_id FROM _lattice_observation_insert_receipt WHERE id=1)
      AND last_audit_id >= (SELECT conflicting_audit_id FROM _lattice_observation_insert_receipt WHERE id=1)
      AND NOT EXISTS(SELECT 1 FROM AuditLog WHERE id=(
          SELECT conflicting_audit_id FROM _lattice_observation_insert_receipt WHERE id=1));
    UPDATE _lattice_observation_state
    SET history_epoch = CASE WHEN NEW.id <= audit_head
            THEN lower(hex(randomblob(16))) ELSE history_epoch END,
        epoch_reason = CASE WHEN NEW.id <= audit_head
            THEN 'id_reuse' ELSE epoch_reason END,
        capture_started_after = CASE WHEN NEW.id <= audit_head
            THEN max(audit_head, NEW.id, 0) ELSE capture_started_after END,
        pruned_through = CASE WHEN NEW.id <= audit_head THEN 0
            ELSE max(pruned_through, coalesce((
                SELECT r.conflicting_audit_id
                FROM _lattice_observation_insert_receipt AS r
                WHERE r.id = 1
                  AND r.conflicting_audit_id IS NOT NULL
                  AND NOT EXISTS (
                      SELECT 1 FROM AuditLog AS a
                      WHERE a.id = r.conflicting_audit_id)
            ), 0)) END,
        audit_head = max(audit_head, NEW.id, 0)
    WHERE id = 1;
    SELECT CASE WHEN
        (SELECT count(*) FROM _lattice_observation_write_context WHERE id=1 AND protocol_version=1) <> 1
        OR EXISTS(SELECT 1 FROM _lattice_observation_write_context AS c,
                    _lattice_observation_state AS s
                  WHERE c.id=1 AND s.id=1 AND c.frame_key IS NOT NULL
                    AND c.history_epoch IS NOT s.history_epoch)
        THEN RAISE(ABORT, 'invalid observation frame context') END;
    INSERT INTO _lattice_observation_frames
        (history_epoch, frame_key, first_audit_id, last_audit_id, record_count, kind, invalidated)
    SELECT s.history_epoch, coalesce(c.frame_key,lower(hex(randomblob(16)))),
           NEW.id,NEW.id,1,CASE WHEN c.frame_key IS NULL THEN 'framing_unavailable' ELSE 'transaction' END,0
    FROM _lattice_observation_state AS s, _lattice_observation_write_context AS c
    WHERE s.id=1 AND c.id=1
    ON CONFLICT(history_epoch,frame_key) DO UPDATE SET
        last_audit_id=excluded.last_audit_id, record_count=record_count+1;
    UPDATE _lattice_observation_state
    SET pruned_through=max(pruned_through,coalesce((
        SELECT max(last_audit_id) FROM _lattice_observation_frames
        WHERE history_epoch=_lattice_observation_state.history_epoch AND invalidated=1),0))
    WHERE id=1;
    UPDATE _lattice_observation_insert_receipt
    SET conflicting_audit_id = NULL WHERE id = 1;
END;)OBS",
R"OBS(CREATE TRIGGER _lattice_observation_audit_ad_v2
AFTER DELETE ON AuditLog
BEGIN
    SELECT CASE WHEN
        (SELECT count(*) FROM _lattice_observation_state
         WHERE id = 1 AND format_version = 2) <> 1
        THEN RAISE(ABORT, 'observation metadata missing or incompatible')
    END;
    UPDATE _lattice_observation_frames SET invalidated=1
    WHERE history_epoch=(SELECT history_epoch FROM _lattice_observation_state WHERE id=1)
      AND first_audit_id <= OLD.id AND last_audit_id >= OLD.id;
    UPDATE _lattice_observation_state
    SET pruned_through = max(pruned_through, OLD.id, coalesce((
            SELECT max(last_audit_id) FROM _lattice_observation_frames
            WHERE history_epoch=_lattice_observation_state.history_epoch AND invalidated=1),0)),
        audit_head = max(audit_head, OLD.id, 0)
    WHERE id = 1;
END;)OBS",
R"OBS(CREATE TRIGGER _lattice_observation_audit_au_v2
AFTER UPDATE ON AuditLog
WHEN
    OLD.id COLLATE BINARY IS NOT NEW.id COLLATE BINARY
    OR typeof(OLD.id) <> typeof(NEW.id)
    OR     OLD.globalId COLLATE BINARY IS NOT NEW.globalId COLLATE BINARY
    OR typeof(OLD.globalId) <> typeof(NEW.globalId)
    OR     OLD.tableName COLLATE BINARY IS NOT NEW.tableName COLLATE BINARY
    OR typeof(OLD.tableName) <> typeof(NEW.tableName)
    OR     OLD.operation COLLATE BINARY IS NOT NEW.operation COLLATE BINARY
    OR typeof(OLD.operation) <> typeof(NEW.operation)
    OR     OLD.rowId COLLATE BINARY IS NOT NEW.rowId COLLATE BINARY
    OR typeof(OLD.rowId) <> typeof(NEW.rowId)
    OR     OLD.globalRowId COLLATE BINARY IS NOT NEW.globalRowId COLLATE BINARY
    OR typeof(OLD.globalRowId) <> typeof(NEW.globalRowId)
    OR     OLD.changedFields COLLATE BINARY IS NOT NEW.changedFields COLLATE BINARY
    OR typeof(OLD.changedFields) <> typeof(NEW.changedFields)
    OR     OLD.changedFieldsNames COLLATE BINARY IS NOT NEW.changedFieldsNames COLLATE BINARY
    OR typeof(OLD.changedFieldsNames) <> typeof(NEW.changedFieldsNames)
    OR     OLD.isFromRemote COLLATE BINARY IS NOT NEW.isFromRemote COLLATE BINARY
    OR typeof(OLD.isFromRemote) <> typeof(NEW.isFromRemote)
    OR     OLD.timestamp COLLATE BINARY IS NOT NEW.timestamp COLLATE BINARY
    OR typeof(OLD.timestamp) <> typeof(NEW.timestamp)
    OR     OLD.synthesized COLLATE BINARY IS NOT NEW.synthesized COLLATE BINARY
    OR typeof(OLD.synthesized) <> typeof(NEW.synthesized)
BEGIN
    SELECT CASE WHEN
        (SELECT count(*) FROM _lattice_observation_state
         WHERE id = 1 AND format_version = 2) <> 1
        THEN RAISE(ABORT, 'observation metadata missing or incompatible')
    END;
    SELECT CASE WHEN (SELECT frame_key FROM _lattice_observation_write_context WHERE id=1) IS NOT NULL
        THEN RAISE(ABORT, 'owned observation frame cannot rewrite audit semantics') END;
    UPDATE _lattice_observation_state
    SET history_epoch = lower(hex(randomblob(16))),
        epoch_reason = 'semantic_update',
        capture_started_after = max(audit_head, OLD.id, NEW.id, 0),
        pruned_through = 0,
        audit_head = max(audit_head, OLD.id, NEW.id, 0)
    WHERE id = 1;
END;)OBS",
R"OBS(UPDATE _lattice_observation_state
SET schema_cookie = :final_schema_cookie
WHERE id = 1;)OBS",
R"OBS(CREATE TABLE _lattice_observation_frames (
    frame_id INTEGER PRIMARY KEY AUTOINCREMENT,
    history_epoch TEXT NOT NULL CHECK(length(history_epoch)=32 AND history_epoch NOT GLOB '*[^0-9a-f]*'),
    frame_key TEXT NOT NULL CHECK(length(frame_key)=32 AND frame_key NOT GLOB '*[^0-9a-f]*'),
    first_audit_id INTEGER NOT NULL CHECK(first_audit_id>0),
    last_audit_id INTEGER NOT NULL CHECK(last_audit_id>=first_audit_id),
    record_count INTEGER NOT NULL CHECK(typeof(record_count)='integer' AND record_count>0),
    kind TEXT NOT NULL CHECK(kind IN ('transaction','framing_unavailable')),
    invalidated INTEGER NOT NULL CHECK(invalidated IN (0,1))
);)OBS",
R"OBS(CREATE TABLE _lattice_observation_write_context (
    id INTEGER PRIMARY KEY CHECK(id=1),
    protocol_version INTEGER NOT NULL CHECK(protocol_version=1),
    frame_key TEXT,
    history_epoch TEXT,
    CHECK((frame_key IS NULL AND history_epoch IS NULL) OR
          (frame_key IS NOT NULL AND history_epoch IS NOT NULL AND
           length(frame_key)=32 AND frame_key NOT GLOB '*[^0-9a-f]*' AND
           length(history_epoch)=32 AND history_epoch NOT GLOB '*[^0-9a-f]*'))
);)OBS",
R"OBS(CREATE UNIQUE INDEX _lattice_observation_frame_key
ON _lattice_observation_frames(history_epoch,frame_key);)OBS",
R"OBS(INSERT INTO _lattice_observation_write_context(id,protocol_version,frame_key,history_epoch)
VALUES(1,1,NULL,NULL);)OBS",
R"OBS(CREATE INDEX _lattice_observation_invalidated_end ON _lattice_observation_frames(history_epoch,last_audit_id) WHERE invalidated=1;)OBS",
R"OBS(UPDATE _lattice_observation_state
SET schema_cookie = :final_schema_cookie
WHERE id = 1;)OBS",
};

struct object_definition { std::string_view type, name; size_t statement; };
// UTF-8 byte order by type, then name: canonical fingerprint serialization.
constexpr std::array<object_definition, 10> manifest{{
    {"index", "_lattice_observation_frame_key", 11},
    {"index", "_lattice_observation_invalidated_end", 13},
    {"table", "_lattice_observation_frames", 9},
    {"table", "_lattice_observation_insert_receipt", 1},
    {"table", "_lattice_observation_state", 0},
    {"table", "_lattice_observation_write_context", 10},
    {"trigger", "_lattice_observation_audit_ad_v2", 6},
    {"trigger", "_lattice_observation_audit_ai_v2", 5},
    {"trigger", "_lattice_observation_audit_au_v2", 7},
    {"trigger", "_lattice_observation_audit_bi_v2", 4}
}};
constexpr std::string_view state_table = "_lattice_observation_state";
constexpr std::string_view receipt_table = "_lattice_observation_insert_receipt";

result failure(status code, reason why, const char* message, int sqlite_code = 0) {
    result r; r.code = code; r.why = why; r.message = message; r.sqlite_code = sqlite_code;
    return r;
}
struct problem { result value; };
[[noreturn]] void reject(status code, reason why, const char* message, int rc = 0) {
    throw problem{failure(code, why, message, rc)};
}
void check_sql(int rc) {
    if (rc != SQLITE_OK) reject(status::database_error, reason::sqlite_failure,
                              "SQLite metadata operation failed", rc);
}
std::string lower(std::string_view text) {
    std::string value(text);
    for (auto& c : value) if (c >= 'A' && c <= 'Z') c = static_cast<char>(c + ('a' - 'A'));
    return value;
}
bool protected_table(std::string_view text) {
    const auto value = lower(text);
    return value == "auditlog" || value == state_table || value == receipt_table || value == "_lattice_observation_frames" || value == "_lattice_observation_write_context";
}
bool metadata_table(std::string_view text) {
    const auto value = lower(text);
    return value == state_table || value == receipt_table || value == "_lattice_observation_frames" || value == "_lattice_observation_write_context";
}
bool reserved(std::string_view text) { return lower(text).starts_with("_lattice_observation_"); }
std::string_view canonical(std::string_view sql) {
    auto space = [](char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; };
    while (!sql.empty() && space(sql.front())) sql.remove_prefix(1);
    while (!sql.empty() && space(sql.back())) sql.remove_suffix(1);
    if (!sql.empty() && sql.back() == ';') sql.remove_suffix(1);
    while (!sql.empty() && space(sql.back())) sql.remove_suffix(1);
    return sql;
}
std::string fingerprint() {
    uint64_t hash = 14695981039346656037ULL;
    auto feed = [&](std::string_view part) {
        for (const unsigned char c : part) { hash ^= c; hash *= 1099511628211ULL; }
    };
    for (const auto& object : manifest) {
        for (auto field : {object.type, object.name, canonical(install_sql[object.statement])}) {
            feed(std::to_string(field.size())); feed(":"); feed(field);
        }
    }
    std::ostringstream out; out << std::hex << std::setfill('0') << std::setw(16) << hash;
    return out.str();
}

class statement {
    sqlite3_stmt* value_ = nullptr;
public:
    statement(sqlite3* db, std::string_view sql) {
        if (sql.size() > INT_MAX) reject(status::database_error, reason::sqlite_failure, "SQL too large");
        const char* tail = nullptr;
        const int rc = sqlite3_prepare_v2(db, sql.data(), static_cast<int>(sql.size()), &value_, &tail);
        if (rc != SQLITE_OK) { sqlite3_finalize(value_); value_ = nullptr; check_sql(rc); }
        if (!value_ || (tail && !canonical(std::string_view(tail, sql.data() + sql.size() - tail)).empty())) {
            sqlite3_finalize(value_); value_ = nullptr;
            reject(status::database_error, reason::sqlite_failure, "Expected one metadata statement");
        }
        database::record_statement();
    }
    ~statement() { sqlite3_finalize(value_); }
    statement(const statement&) = delete;
    statement& operator=(const statement&) = delete;
    sqlite3_stmt* get() const { return value_; }
    bool row() {
        const int rc = sqlite3_step(value_);
        if (rc == SQLITE_ROW) return true;
        if (rc == SQLITE_DONE) return false;
        const char* sql = sqlite3_sql(value_);
        const auto diagnostic = std::string("SQLite metadata statement failed; fixed SQL=") +
            (sql ? std::string(sql, ::strnlen(sql, 256)) : std::string("unavailable"));
        reject(status::database_error, reason::sqlite_failure, diagnostic.c_str(), rc);
    }
    void text_parameter(int index, std::string_view value) {
        check_sql(sqlite3_bind_text(value_, index, value.data(), static_cast<int>(value.size()), SQLITE_TRANSIENT));
    }
    int type(int column) const { return sqlite3_column_type(value_, column); }
    int64_t integer(int column) const {
        if (type(column) != SQLITE_INTEGER) reject(status::integrity_uncertain, reason::invalid_state,
                                                  "Expected INTEGER metadata value");
        return sqlite3_column_int64(value_, column);
    }
    std::string text(int column) const {
        if (type(column) != SQLITE_TEXT) reject(status::integrity_uncertain, reason::invalid_state,
                                               "Expected TEXT schema/metadata value");
        const int bytes = sqlite3_column_bytes(value_, column);
        if (bytes < 0 || bytes > 64 * 1024) reject(status::integrity_uncertain, reason::invalid_state,
                                                "Schema/metadata text exceeds supported bound");
        if (bytes == 0) return {};
        const auto* data = sqlite3_column_text(value_, column);
        if (!data) reject(status::database_error, reason::sqlite_failure,
                          "SQLite metadata text unavailable", SQLITE_NOMEM);
        return std::string(reinterpret_cast<const char*>(data), static_cast<size_t>(bytes));
    }
};
void execute(sqlite3* db, std::string_view sql) {
    statement s(db, sql);
    if (s.row()) reject(status::database_error, reason::sqlite_failure, "Unexpected metadata result row");
}
int64_t scalar_integer(sqlite3* db, std::string_view sql) {
    statement s(db, sql);
    if (!s.row()) reject(status::integrity_uncertain, reason::invalid_state, "Missing scalar metadata row");
    const auto value = s.integer(0);
    if (s.row()) reject(status::integrity_uncertain, reason::invalid_state, "Multiple scalar metadata rows");
    return value;
}

struct connection_scope {
    database& owner;
    sqlite3* db;
    sqlite3_mutex* mutex;
    explicit connection_scope(database& source) : owner(source), db(database_maintenance_access::handle(source)), mutex(nullptr) {
        if (!db || source.is_closed()) reject(status::invalid_context, reason::closed_connection, "Closed owner");
        mutex = sqlite3_db_mutex(db);
        if (!mutex) reject(status::invalid_context, reason::closed_connection, "Serialized owner required");
        sqlite3_mutex_enter(mutex);
        if (source.is_closed()) {
            sqlite3_mutex_leave(mutex); mutex = nullptr;
            reject(status::invalid_context, reason::closed_connection, "Closed owner");
        }
        database_maintenance_access::defer_automatic_optimize(owner);
    }
    ~connection_scope() { if (mutex) sqlite3_mutex_leave(mutex); }
};

struct inventory {
    std::array<bool, manifest.size()> found{};
    size_t count = 0;
    std::vector<std::string> tables;
};
void reject_foreign_keys(sqlite3* db, const std::string& table, const char* schema) {
    statement keys(db, "SELECT \"table\" FROM pragma_foreign_key_list(?1, ?2)");
    keys.text_parameter(1, table); keys.text_parameter(2, schema);
    while (keys.row()) {
        if (protected_table(table) || protected_table(keys.text(0)))
            reject(status::unsupported_foreign_key_inventory, reason::none,
                   "Foreign keys involving audit/metadata tables are unsupported");
    }
}
inventory read_inventory(sqlite3* db) {
    inventory result;
    statement main(db, "SELECT type,name,tbl_name,sql FROM main.sqlite_schema");
    while (main.row()) {
        const auto type = main.text(0), name = main.text(1), table = main.text(2);
        if (type == "table") result.tables.push_back(name);
        if (type == "trigger" && protected_table(table)) {
            const bool expected = std::any_of(manifest.begin(), manifest.end(), [&](const auto& o) {
                return o.type == "trigger" && o.name == name && lower(table) == "auditlog";
            });
            if (!expected) reject(status::unsupported_trigger_inventory, reason::reserved_object,
                                  "Unexpected audit/metadata trigger");
        }
        if (!reserved(name) && !metadata_table(table)) continue;
        const auto it = std::find_if(manifest.begin(), manifest.end(), [&](const auto& o) {
            return o.type == type && o.name == name;
        });
        if (it == manifest.end()) reject(status::integrity_uncertain, reason::reserved_object,
                                         "Unexpected reserved metadata object/index");
        const size_t index = static_cast<size_t>(it - manifest.begin());
        if (result.found[index]) reject(status::integrity_uncertain, reason::reserved_object,
                                        "Duplicate reserved metadata object");
        result.found[index] = true; ++result.count;
        if (main.type(3) != SQLITE_TEXT || canonical(main.text(3)) != canonical(install_sql[it->statement]))
            reject(status::integrity_uncertain, reason::definition_changed, "Metadata definition changed");
    }
    statement temp(db, "SELECT type,name,tbl_name FROM temp.sqlite_schema");
    while (temp.row()) {
        const auto type = temp.text(0), name = temp.text(1), table = temp.text(2);
        if (reserved(name) || protected_table(name) || (type == "trigger" && protected_table(table)))
            reject(status::unsupported_temp_inventory, reason::reserved_object,
                   "TEMP audit/metadata shadow or trigger is unsupported");
        if (type == "table") reject_foreign_keys(db, name, "temp");
    }
    for (const auto& table : result.tables) reject_foreign_keys(db, table, "main");
    return result;
}

void validate_audit(sqlite3* db) {
    constexpr std::array<std::pair<std::string_view, std::string_view>, 12> columns{{
        {"id", "INTEGER"}, {"globalId", "TEXT"}, {"tableName", "TEXT"}, {"operation", "TEXT"},
        {"rowId", "INTEGER"}, {"globalRowId", "TEXT"}, {"changedFields", "TEXT"},
        {"changedFieldsNames", "TEXT"}, {"isFromRemote", "INTEGER"}, {"isSynchronized", "INTEGER"},
        {"timestamp", "REAL"}, {"synthesized", "INTEGER"}
    }};
    statement info(db, "SELECT cid,name,type,\"notnull\",pk,hidden FROM pragma_table_xinfo('AuditLog','main')");
    size_t count = 0;
    while (info.row()) {
        if (count >= columns.size() || info.integer(0) != static_cast<int64_t>(count) ||
            info.text(1) != columns[count].first || info.text(2) != columns[count].second ||
            info.integer(3) != 0 || info.integer(4) != (count == 0 ? 1 : 0) || info.integer(5) != 0)
            reject(status::unsupported_audit_shape, reason::none, "Unsupported AuditLog columns");
        ++count;
    }
    if (count != columns.size()) reject(status::unsupported_audit_shape, reason::none, "Missing AuditLog columns");
    const char* type = nullptr; const char* collation = nullptr;
    int not_null = 0, primary_key = 0, autoincrement = 0;
    check_sql(sqlite3_table_column_metadata(db, "main", "AuditLog", "id", &type, &collation,
                                          &not_null, &primary_key, &autoincrement));
    if (!primary_key || !autoincrement) reject(status::unsupported_audit_shape, reason::none,
                                              "AuditLog INTEGER AUTOINCREMENT key required");
    check_sql(sqlite3_table_column_metadata(db, "main", "AuditLog", "globalId", &type, &collation,
                                          &not_null, &primary_key, &autoincrement));
    if (!collation || std::string_view(collation) != "NOCASE")
        reject(status::unsupported_audit_shape, reason::none, "AuditLog globalId NOCASE required");
    statement indexes(db, "SELECT name,\"unique\",partial FROM pragma_index_list('AuditLog','main')");
    size_t unique_count = 0;
    while (indexes.row()) {
        if (indexes.integer(1) == 0) continue;
        if (++unique_count != 1 || indexes.integer(2) != 0)
            reject(status::unsupported_audit_shape, reason::none, "Additional/partial unique audit index");
        statement key(db, "SELECT cid,name,desc,coll,\"key\" FROM pragma_index_xinfo(?1,'main')");
        key.text_parameter(1, indexes.text(0));
        size_t keys = 0;
        while (key.row()) {
            if (key.integer(4) == 0) continue;
            if (++keys != 1 || key.integer(0) != 1 || key.text(1) != "globalId" ||
                key.integer(2) != 0 || key.text(3) != "NOCASE")
                reject(status::unsupported_audit_shape, reason::none, "Unsupported unique audit key");
        }
        if (keys != 1) reject(status::unsupported_audit_shape, reason::none, "Missing globalId unique key");
    }
    if (unique_count != 1) reject(status::unsupported_audit_shape, reason::none, "Missing globalId uniqueness");
}
struct bounds { int64_t maximum = 0, sequence = 0; };
bounds audit_bounds(sqlite3* db) {
    statement invalid(db, "SELECT id FROM main.AuditLog WHERE id <= 0 LIMIT 1");
    if (invalid.row()) reject(status::integrity_uncertain, reason::nonpositive_audit_id,
                              "Nonpositive retained audit ID");
    bounds b;
    statement maximum(db, "SELECT MAX(id) FROM main.AuditLog");
    if (!maximum.row()) reject(status::integrity_uncertain, reason::invalid_state, "Missing audit maximum");
    if (maximum.type(0) != SQLITE_NULL) b.maximum = maximum.integer(0);
    statement sequence(db, "SELECT seq FROM main.sqlite_sequence WHERE name='AuditLog'");
    if (sequence.row()) {
        b.sequence = sequence.integer(0);
        if (b.sequence < 0 || sequence.row()) reject(status::integrity_uncertain, reason::invalid_sequence,
                                                     "Invalid/duplicate AuditLog sequence");
    }
    // IGNORE may advance sequence beyond head; UPDATE of _rowid_ may place
    // MAX(id) above sequence. Both are legitimate and independently bounded.
    return b;
}
bool hex_id(const std::string& value) {
    return value.size() == 32 && value.find_first_not_of("0123456789abcdef") == std::string::npos;
}
result inspect_locked(sqlite3* db, bool allow_active_context = false) {
    int enabled = 0; check_sql(sqlite3_db_config(db, SQLITE_DBCONFIG_ENABLE_TRIGGER, -1, &enabled));
    if (!enabled) return failure(status::triggers_disabled, reason::none, "Local triggers are disabled");
    validate_audit(db);
    const auto inventory = read_inventory(db);
    const auto bounds = audit_bounds(db);
    if (inventory.count == 0) { result r; r.code = status::not_installed; return r; }
    if (inventory.count != manifest.size())
        return failure(status::integrity_uncertain, reason::partial_installation, "Partial metadata installation");
    statement row(db, "SELECT id,format_version,ddl_fingerprint,schema_cookie,store_uuid,history_epoch,epoch_reason,"
                      "audit_head,capture_started_after,pruned_through FROM main._lattice_observation_state LIMIT 2");
    if (!row.row() || row.integer(0) != 1) reject(status::integrity_uncertain, reason::invalid_singleton,
                                               "Missing observation singleton");
    if (row.integer(1) != 2) return failure(status::unsupported_format, reason::none, "Unsupported metadata format");
    state value;
    value.ddl_fingerprint = row.text(2); value.schema_cookie = row.integer(3);
    value.store_uuid = row.text(4); value.history_epoch = row.text(5); value.epoch_reason = row.text(6);
    value.audit_head = row.integer(7); value.capture_started_after = row.integer(8); value.pruned_through = row.integer(9);
    if (row.row()) reject(status::integrity_uncertain, reason::invalid_singleton, "Multiple observation rows");
    statement receipt(db, "SELECT id,conflicting_audit_id FROM main._lattice_observation_insert_receipt LIMIT 2");
    if (!receipt.row() || receipt.integer(0) != 1 ||
        (receipt.type(1) != SQLITE_NULL && receipt.integer(1) <= 0) || receipt.row())
        reject(status::integrity_uncertain, reason::invalid_singleton, "Invalid insertion receipt singleton");
    constexpr std::array<std::string_view, 5> reasons{{"installation", "id_reuse", "semantic_update", "explicit_reset", "integrity_repair"}};
    if (value.ddl_fingerprint != fingerprint() || value.schema_cookie < 0 || value.schema_cookie > INT32_MAX ||
        !hex_id(value.store_uuid) || !hex_id(value.history_epoch) ||
        std::find(reasons.begin(), reasons.end(), value.epoch_reason) == reasons.end() ||
        value.audit_head < bounds.maximum || value.audit_head < 0 || value.capture_started_after < 0 ||
        value.capture_started_after > value.audit_head || value.pruned_through < 0 || value.pruned_through > value.audit_head)
        return failure(status::integrity_uncertain, reason::invalid_state, "Invalid observation state/bounds");
    if (value.schema_cookie != scalar_integer(db, "PRAGMA main.schema_version"))
        return failure(status::integrity_uncertain, reason::schema_changed, "Unacknowledged schema change");
    statement context(db,"SELECT id,protocol_version,frame_key,history_epoch FROM main._lattice_observation_write_context LIMIT 2");
    if (!context.row() || context.integer(0)!=1 || context.integer(1)!=1)
        reject(status::integrity_uncertain,reason::invalid_singleton,"Invalid frame context singleton");
    const bool active=context.type(2)!=SQLITE_NULL;
    if ((active && (!allow_active_context || !hex_id(context.text(2)) || context.text(3)!=value.history_epoch)) ||
        (!active && context.type(3)!=SQLITE_NULL) || context.row())
        reject(status::integrity_uncertain,reason::invalid_state,"Committed/invalid frame context");
    result r; r.code = status::ready_integrity_only; r.value = std::move(value); return r;
}

// Each invocation holds the owner SQLite mutex. Names are unique within this
// process; the private prefix is reserved from caller savepoint names.
std::atomic<uint64_t> next_savepoint{1};
uint64_t savepoint_number() {
    auto next = next_savepoint.load(std::memory_order_relaxed);
    for (;;) {
        if (next == UINT64_MAX)
            reject(status::invalid_context, reason::none, "Private savepoint identity exhausted");
        if (next_savepoint.compare_exchange_weak(next, next + 1, std::memory_order_relaxed)) return next;
    }
}
result installation_locked(sqlite3* db, bool caller_owned, install_options options) {
    if (options.fail_after_statement < -1 || options.fail_after_statement > 14)
        return failure(status::invalid_context, reason::none, "Invalid private fault point");
    if (sqlite3_db_readonly(db, "main") != 0)
        return failure(status::invalid_context, reason::read_only_connection, "Writable main owner required");
    if ((!caller_owned && !sqlite3_get_autocommit(db)) ||
        (caller_owned && (sqlite3_get_autocommit(db) || sqlite3_txn_state(db, "main") != SQLITE_TXN_WRITE)))
        return failure(status::invalid_context, caller_owned ? reason::write_transaction_required : reason::autocommit_required,
                       "Incorrect installation transaction context");
    const std::string savepoint = "_lattice_observation_install_" + std::to_string(savepoint_number());
    bool scope_open = false;
    auto rollback = [&]() -> bool {
        try {
            if (caller_owned) { execute(db, "ROLLBACK TO " + savepoint); execute(db, "RELEASE " + savepoint); }
            else execute(db, "ROLLBACK");
            scope_open = false; return true;
        } catch (...) { return false; }
    };
    try {
        execute(db, caller_owned ? "SAVEPOINT " + savepoint : "BEGIN IMMEDIATE");
        scope_open = true;
        auto r = inspect_locked(db);
        if (r.code != status::not_installed && r.code != status::ready_integrity_only) throw problem{std::move(r)};
        if (r.code == status::not_installed) {
            const auto bounds = audit_bounds(db);
            const auto head = std::max(bounds.maximum, bounds.sequence);
            const auto ddl_fingerprint = fingerprint();
            for (size_t i = 0; i < install_sql.size(); ++i) {
                statement operation(db, install_sql[i]);
                if (i == 2) {
                    check_sql(sqlite3_bind_int64(operation.get(), sqlite3_bind_parameter_index(operation.get(), ":initial_head"), head));
                    operation.text_parameter(sqlite3_bind_parameter_index(operation.get(), ":ddl_fingerprint"), ddl_fingerprint);
                } else if (i == 8 || i == 14) {
                    const auto cookie = scalar_integer(db, "PRAGMA main.schema_version");
                    check_sql(sqlite3_bind_int64(operation.get(), sqlite3_bind_parameter_index(operation.get(), ":final_schema_cookie"), cookie));
                }
                if (operation.row()) reject(status::database_error, reason::sqlite_failure, "Unexpected installation row");
                if (options.fail_after_statement == static_cast<int>(i))
                    reject(status::database_error, reason::injected_failure, "Injected installation failure");
            }
            r = inspect_locked(db);
            if (r.code != status::ready_integrity_only) throw problem{std::move(r)};
            r.installed_now = true;
        }
        execute(db, caller_owned ? "RELEASE " + savepoint : "COMMIT");
        scope_open = false;
        r.scope = caller_owned ? visibility::pending_outer_commit : visibility::committed_by_this_call;
        return r;
    } catch (const problem& p) {
        if (scope_open && !rollback()) {
            auto r = failure(status::rollback_failed, reason::rollback_failure, "Installation rollback failed", p.value.sqlite_code);
            r.owner_must_rollback = true; return r;
        }
        return p.value;
    } catch (...) {
        const bool failed_rollback = scope_open && !rollback();
        auto r = failure(failed_rollback ? status::rollback_failed : status::database_error,
                         failed_rollback ? reason::rollback_failure : reason::sqlite_failure,
                         "Metadata installation failed");
        r.owner_must_rollback = failed_rollback; return r;
    }
}

template<class Function> result with_connection(database& owner, Function&& body) {
    try { connection_scope scope(owner); return body(scope.db); }
    catch (const problem& p) { return p.value; }
    catch (...) { return failure(status::database_error, reason::sqlite_failure, "Metadata operation failed"); }
}
} // namespace

result inspect_in_snapshot(database& owner) {
    return with_connection(owner, [](sqlite3* db) {
        if (sqlite3_get_autocommit(db) || sqlite3_txn_state(db, "main") == SQLITE_TXN_NONE)
            return failure(status::invalid_context, reason::snapshot_required, "Established main snapshot required");
        return inspect_locked(db);
    });
}
result install(database& owner, install_options options) {
    return with_connection(owner, [&](sqlite3* db) { return installation_locked(db, false, options); });
}

struct write_scope::impl {
    connection_scope connection;
    fault_options faults;
    std::thread::id thread = std::this_thread::get_id();
    phase state = phase::writing;
    std::string key, epoch;
    std::string hooked_model; // nonempty only for the fixed internal owner adapter
    int hooked_action = 0; // admitted only around one fixed adapter operation
    std::vector<uint64_t> points;
    bool internal = false, policy_installed = false;

    struct internal_sql {
        impl& self;
        explicit internal_sql(impl& s) : self(s) { self.internal = true; }
        ~internal_sql() { self.internal = false; }
    };
    static int authorize(void* opaque, int action, const char* table, const char* detail,
                         const char* schema, const char* trigger) noexcept {
        auto& self = *static_cast<impl*>(opaque);
        if (self.internal) return SQLITE_OK;
        switch (action) {
            case SQLITE_FUNCTION:
                if (!self.hooked_model.empty() && detail &&
                    (sqlite3_stricmp(detail,"changes") == 0 || sqlite3_stricmp(detail,"total_changes") == 0))
                    return SQLITE_DENY;
                return SQLITE_OK;
            case SQLITE_SELECT: case SQLITE_READ: case SQLITE_RECURSIVE: return SQLITE_OK;
            case SQLITE_PRAGMA:
                // Exact read-only metadata used by selected-batch preflight.
                if (self.hooked_model.empty() || !table) return SQLITE_DENY;
                if (std::strcmp(table,"database_list") == 0 && !detail) return SQLITE_OK;
                if (std::strcmp(table,"table_info") == 0 && detail && schema &&
                    std::strcmp(schema,"main") == 0 && self.hooked_model == detail) return SQLITE_OK;
                return SQLITE_DENY;
            case SQLITE_INSERT: case SQLITE_UPDATE: case SQLITE_DELETE: {
                if (self.state != phase::writing || sqlite3_get_autocommit(self.connection.db) ||
                    !schema || std::strcmp(schema, "main") != 0 || !table) return SQLITE_DENY;
                constexpr const char* prefix = "_lattice_observation_";
                const bool metadata = sqlite3_strnicmp(table, prefix, static_cast<int>(std::strlen(prefix))) == 0;
                const bool system = sqlite3_strnicmp(table, "sqlite_", 7) == 0;
                const bool trusted = trigger &&
                    (std::strcmp(trigger, "_lattice_observation_audit_bi_v2") == 0 ||
                     std::strcmp(trigger, "_lattice_observation_audit_ai_v2") == 0 ||
                     std::strcmp(trigger, "_lattice_observation_audit_ad_v2") == 0 ||
                     std::strcmp(trigger, "_lattice_observation_audit_au_v2") == 0);
                if (!self.hooked_model.empty() && !metadata) {
                    if (self.hooked_model == table) {
                        if (trigger || action != self.hooked_action) return SQLITE_DENY;
                    } else if (std::strcmp(table,"AuditLog") == 0) {
                        const bool model_audit = trigger && action == SQLITE_INSERT &&
                            ((self.hooked_action == SQLITE_INSERT &&
                              self.hooked_model.size() + 11 == std::strlen(trigger) &&
                              std::strncmp(trigger, "Audit", 5) == 0 &&
                              std::strncmp(trigger + 5, self.hooked_model.c_str(), self.hooked_model.size()) == 0 &&
                              std::strcmp(trigger + 5 + self.hooked_model.size(), "Insert") == 0) ||
                             (self.hooked_action == SQLITE_UPDATE &&
                              self.hooked_model.size() + 16 == std::strlen(trigger) &&
                              std::strncmp(trigger, "AuditLog_Update_", 16) == 0 &&
                              std::strcmp(trigger + 16, self.hooked_model.c_str()) == 0));
                        if (!model_audit) return SQLITE_DENY;
                    } else return SQLITE_DENY;
                }
                return system || (metadata && !trusted) ? SQLITE_DENY : SQLITE_OK;
            }
            default: return SQLITE_DENY; // user controls, DDL, PRAGMA, ATTACH and DETACH
        }
    }
    void same_thread() const {
        if (thread != std::this_thread::get_id()) throw std::logic_error("Frame scope is thread-affine");
    }
    void writing() const {
        same_thread();
        if (state != phase::writing || sqlite3_get_autocommit(connection.db))
            throw std::logic_error("Frame scope is not writable");
    }
    void unhook() noexcept {
        if (policy_installed) { sqlite3_set_authorizer(connection.db, nullptr, nullptr); policy_installed = false; }
    }
    void context(bool set) {
        statement operation(connection.db, set ?
            "UPDATE main._lattice_observation_write_context SET frame_key=?1,history_epoch=?2 WHERE id=1" :
            "UPDATE main._lattice_observation_write_context SET frame_key=NULL,history_epoch=NULL WHERE id=1");
        if (set) { operation.text_parameter(1, key); operation.text_parameter(2, epoch); }
        if (operation.row()) throw std::logic_error("Unexpected context row");
        if (sqlite3_changes(connection.db) != 1) throw std::logic_error("Missing context singleton");
    }
    explicit impl(database& owner, fault_options options, std::string model = {})
        : connection(owner), faults(options), hooked_model(std::move(model)) {
        bool begun = false;
        const char* admission_stage = "precondition";
        try {
            if (!sqlite3_get_autocommit(connection.db) || sqlite3_next_stmt(connection.db, nullptr))
                throw std::logic_error("Exclusive autocommit owner without prepared statements required");
            admission_stage = "begin";
            execute(connection.db, "BEGIN IMMEDIATE"); begun = true;
            admission_stage = "inspect";
            const auto metadata = inspect_locked(connection.db);
            if (metadata.code != status::ready_integrity_only || !metadata.value)
                throw std::runtime_error("Valid format-2 metadata required");
            epoch = metadata.value->history_epoch;
            {
                admission_stage = "key";
                statement random(connection.db, "SELECT lower(hex(randomblob(16)))");
                if (!random.row()) throw std::runtime_error("Frame key unavailable");
                key = random.text(0);
            }
            {
                admission_stage = "collision";
                statement collision(connection.db, "SELECT 1 FROM main._lattice_observation_frames WHERE history_epoch=?1 AND frame_key=?2");
                collision.text_parameter(1, epoch); collision.text_parameter(2, key);
                if (collision.row()) throw std::runtime_error("Frame key collision");
            }
            admission_stage = "context";
            context(true);
            admission_stage = "authorizer";
            check_sql(sqlite3_set_authorizer(connection.db, authorize, this)); policy_installed = true;
        } catch (...) {
            const auto original = std::current_exception();
            unhook();
            if (begun && !sqlite3_get_autocommit(connection.db)) {
                try { execute(connection.db, "ROLLBACK"); } catch (...) { /* caller must inspect/recover owner */ }
            }
            try { std::rethrow_exception(original); }
            catch (const problem& p) {
                throw std::runtime_error(p.value.message + " admission=" + admission_stage +
                    " sqlite=" + std::to_string(p.value.sqlite_code) +
                    " transactionOpen=" + std::to_string(!sqlite3_get_autocommit(connection.db)));
            }
        }
    }
    ~impl() {
        // Thread-affinity/exclusive ownership are preconditions, including teardown.
        internal_sql controls(*this);
        if (state == phase::writing || state == phase::resolving_commit || state == phase::rollback_only) {
            try { if (!sqlite3_get_autocommit(connection.db)) execute(connection.db, "ROLLBACK"); } catch (...) {}
        }
        unhook();
    }
    completion finish_commit() {
        same_thread();
        if (state != phase::writing && state != phase::resolving_commit)
            return {outcome::invalid_context, 0, !sqlite3_get_autocommit(connection.db)};
        if (sqlite3_get_autocommit(connection.db)) {
            state = phase::outcome_unknown; unhook(); return {outcome::outcome_unknown, 0, false};
        }
        internal_sql controls(*this);
        int error = SQLITE_ERROR;
        bool cleared = false;
        try {
            const auto metadata = inspect_locked(connection.db, true);
            if (metadata.code != status::ready_integrity_only || !metadata.value || metadata.value->history_epoch != epoch)
                throw std::runtime_error("Frame metadata changed during transaction");
            statement current(connection.db, "SELECT frame_key FROM main._lattice_observation_write_context WHERE id=1");
            if (!current.row() || current.text(0) != key) throw std::runtime_error("Frame context changed");
            // This read must finalize before COMMIT (including an empty transaction).
        } catch (const problem& p) {
            error = p.value.sqlite_code;
            const bool open = !sqlite3_get_autocommit(connection.db);
            state = open ? phase::rollback_only : phase::outcome_unknown;
            if (!open) unhook();
            return {open ? outcome::rollback_required : outcome::outcome_unknown,error,open};
        } catch (...) {
            const bool open = !sqlite3_get_autocommit(connection.db);
            state = open ? phase::rollback_only : phase::outcome_unknown;
            if (!open) unhook();
            return {open ? outcome::rollback_required : outcome::outcome_unknown,error,open};
        }
        try {
            context(false); cleared = true;
            execute(connection.db, "COMMIT");
            state = phase::committed; points.clear(); unhook();
            return {outcome::committed, SQLITE_OK, false};
        } catch (const problem& p) { error = p.value.sqlite_code; }
          catch (...) { error = SQLITE_ERROR; }
        if (sqlite3_get_autocommit(connection.db)) {
            // An error plus autocommit does not prove durable commit or rollback.
            state = phase::outcome_unknown; points.clear(); unhook();
            return {outcome::outcome_unknown, error, false};
        }
        if (cleared) {
            try {
                if (faults.fail_next_context_restore) {
                    faults.fail_next_context_restore = false; throw std::runtime_error("Injected restore failure");
                }
                context(true); state = phase::resolving_commit;
                return {outcome::retry_commit_or_rollback, error, true};
            } catch (...) {}
        }
        state = phase::rollback_only;
        return {outcome::rollback_required, error, true};
    }
    completion finish_rollback() {
        same_thread();
        if (state != phase::writing && state != phase::resolving_commit && state != phase::rollback_only)
            return {outcome::invalid_context, 0, !sqlite3_get_autocommit(connection.db)};
        if (sqlite3_get_autocommit(connection.db)) {
            state = phase::outcome_unknown; unhook(); return {outcome::outcome_unknown, 0, false};
        }
        internal_sql controls(*this);
        int error = SQLITE_ERROR;
        try {
            if (faults.fail_next_rollback) { faults.fail_next_rollback = false; throw std::runtime_error("Injected rollback failure"); }
            execute(connection.db, "ROLLBACK");
            state = phase::rolled_back; points.clear(); unhook();
            return {outcome::rolled_back, SQLITE_OK, false};
        } catch (const problem& p) { error = p.value.sqlite_code; } catch (...) {}
        const bool open = !sqlite3_get_autocommit(connection.db);
        state = open ? phase::rollback_only : phase::outcome_unknown;
        if (!open) unhook();
        return {open ? outcome::rollback_required : outcome::outcome_unknown, error, open};
    }
};

write_scope::write_scope(database& owner, fault_options options) {
    try { impl_ = std::make_unique<impl>(owner, options); }
    catch (const problem& p) { throw std::runtime_error(p.value.message); }
}
write_scope::write_scope(database& owner, const std::string& hooked_model) {
    if (hooked_model.empty()) throw std::logic_error("Missing hooked model");
    try { impl_ = std::make_unique<impl>(owner, fault_options{}, hooked_model); }
    catch (const problem& p) { throw std::runtime_error(p.value.message); }
}
write_scope::~write_scope() = default;
void write_scope::begin_model_write(int action) {
    impl_->writing();
    if (impl_->hooked_model.empty() || impl_->hooked_action != 0 ||
        (action != SQLITE_INSERT && action != SQLITE_UPDATE))
        throw std::logic_error("Invalid fixed model write admission");
    impl_->hooked_action = action;
}
void write_scope::end_model_write() noexcept { impl_->hooked_action = 0; }
phase write_scope::current_phase() const { impl_->same_thread(); return impl_->state; }
const std::string& write_scope::frame_key() const { impl_->same_thread(); return impl_->key; }
uint64_t write_scope::savepoint() {
    impl_->writing(); const auto token = savepoint_number();
    // Allocate before SQL; a bad_alloc must not create an untracked savepoint.
    impl_->points.push_back(token);
    try {
        impl::internal_sql controls(*impl_);
        execute(impl_->connection.db, "SAVEPOINT _lattice_observation_frame_" + std::to_string(token));
    } catch (...) { impl_->points.pop_back(); throw; }
    return token;
}
void write_scope::rollback_to(uint64_t token) {
    impl_->writing(); auto& points = impl_->points;
    const auto found = std::find(points.begin(), points.end(), token);
    if (found == points.end()) throw std::logic_error("Unknown frame savepoint");
    impl::internal_sql controls(*impl_);
    execute(impl_->connection.db, "ROLLBACK TO _lattice_observation_frame_" + std::to_string(token));
    points.erase(found + 1, points.end());
}
void write_scope::release(uint64_t token) {
    impl_->writing(); auto& points = impl_->points;
    const auto found = std::find(points.begin(), points.end(), token);
    if (found == points.end()) throw std::logic_error("Unknown frame savepoint");
    impl::internal_sql controls(*impl_);
    execute(impl_->connection.db, "RELEASE _lattice_observation_frame_" + std::to_string(token));
    points.erase(found, points.end());
}
completion write_scope::commit() { return impl_->finish_commit(); }
completion write_scope::rollback() { return impl_->finish_rollback(); }
} // namespace lattice::observation_frames
#endif
