// Diagnostic only. All Core calls use exact unchanged 7b11.
#include <lattice/lattice.hpp>
#include <lattice/sync.hpp>
#include <lattice/log.hpp>
#include <nlohmann/json.hpp>
#include <cerrno>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <unistd.h>

struct RetentionFloorRaceRow { int64_t value = 0; };
LATTICE_SCHEMA(RetentionFloorRaceRow, value);
namespace {
using namespace lattice;
using json = nlohmann::json;
constexpr int64_t rows = 12;
constexpr const char* target = "floor-race-writer";
constexpr const char* resolved = "resolved-writer";
void require(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
void emit(json value) { value["pid"] = getpid(); std::cout << value.dump() << '\n' << std::flush; }
configuration config(const std::string& path) {
    configuration c(path); c.busy_timeout_ms = 5000; c.audit_retention_seconds = 0; return c;
}
int64_t scalar(database& db, const std::string& sql) {
    const auto values = db.query(sql);
    require(values.size() == 1 && values[0].size() == 1, "scalar shape");
    return std::get<int64_t>(values[0].begin()->second);
}
json pending(database& db, const char* sync_id) {
    json values = json::array();
    const auto floor = read_upload_floor(db, sync_id);
    for (const auto& entry : query_audit_log_for_sync(db, sync_id, std::nullopt, floor, 32))
        values.push_back({{"id", entry.id}, {"globalId", entry.global_id}});
    return values;
}
json state(database& db) {
    json audit = json::array(), models = json::array();
    for (const auto& row : db.query("SELECT id,globalId FROM AuditLog ORDER BY id"))
        audit.push_back({{"id", std::get<int64_t>(row.at("id"))}, {"globalId", std::get<std::string>(row.at("globalId"))}});
    for (const auto& row : db.query("SELECT id,value FROM RetentionFloorRaceRow ORDER BY id"))
        models.push_back({{"id", std::get<int64_t>(row.at("id"))}, {"value", std::get<int64_t>(row.at("value"))}});
    return {{"audit", audit}, {"modelRows", models}, {"pending", pending(db, target)},
            {"targetRegistered", scalar(db, "SELECT COUNT(*) FROM _lattice_replication_slots WHERE sync_id='floor-race-writer'") == 1},
            {"targetFloor", read_upload_floor(db, target)},
            {"sequence", scalar(db, "SELECT seq FROM sqlite_sequence WHERE name='AuditLog'")}};
}
void seed(const std::string& path, const std::string& mutation) {
    require(!std::filesystem::exists(path), "seed refuses existing fixture");
    lattice_db owner(config(path)); auto& db = owner.db();
    owner.begin_transaction();
    for (int64_t n = 1; n <= rows; ++n) owner.add(RetentionFloorRaceRow{n});
    owner.commit();
    // Like existing floor tests, advance a resolved frontier; do not mark the
    // audit globally synchronized, which would hide a newly pending channel.
    const char* initial = mutation == "reset" ? target : resolved;
    register_replication_slot(db, initial);
    advance_upload_floor(db, initial, rows);
    require(pending(db, initial).empty(), "initial writer still pending below floor");
    owner.record_audit_watermark(); owner.backdate_audit_watermarks(1200);
    db.execute("CREATE TABLE IF NOT EXISTS _lattice_applied_receipts (globalId TEXT PRIMARY KEY)");
    require(scalar(db, "SELECT COUNT(*) FROM AuditLog") == rows, "seed audit count");
    require(scalar(db, "SELECT COUNT(*) FROM AuditLog WHERE isSynchronized=0") == rows, "seed pending premise");
    const auto snapshot = state(db);
    require(snapshot.at("sequence") == rows, "seed sequence");
    emit({{"kind", "seed"}, {"state", snapshot}, {"sqliteVersion", sqlite3_libversion()},
          {"sqliteSourceID", sqlite3_sourceid()}, {"initialWriter", initial}});
    owner.close();
}
struct trace_state {
    sqlite3* connection = nullptr;
    int floor_rows = 0, floor_profiles = 0, barriers = 0, begin_count = 0;
    int64_t floor_count = -1, floor_value = -1;
    bool failed = false;
    static bool is_floor(const char* sql) noexcept {
        return sql && (std::strcmp(sql, "SELECT COUNT(*) as cnt, MIN(upload_floor) as safe_id FROM _lattice_replication_slots WHERE is_observer = 0") == 0 ||
                       std::strcmp(sql, "SELECT COUNT(*) AS cnt, MIN(upload_floor) AS floor FROM _lattice_replication_slots WHERE is_observer = 0") == 0);
    }
    static bool write_all(const char* bytes, size_t size) noexcept {
        while (size) {
            const auto written = ::write(STDOUT_FILENO, bytes, size);
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) return false;
            bytes += written; size -= static_cast<size_t>(written);
        }
        return true;
    }
    static int trace(unsigned event, void* context, void* pointer, void*) noexcept {
        auto& self = *static_cast<trace_state*>(context);
        auto* stmt = static_cast<sqlite3_stmt*>(pointer);
        const char* sql = sqlite3_sql(stmt);
        if (is_floor(sql)) {
            if (event == SQLITE_TRACE_ROW) {
                ++self.floor_rows;
                self.floor_count = sqlite3_column_int64(stmt, 0);
                self.floor_value = sqlite3_column_int64(stmt, 1);
            }
            if (event == SQLITE_TRACE_PROFILE) ++self.floor_profiles;
        }
        if (event != SQLITE_TRACE_STMT || !sql) return 0;
        if (std::strcmp(sql, "BEGIN IMMEDIATE") == 0) ++self.begin_count;
        if (std::strcmp(sql, "CREATE TABLE IF NOT EXISTS _lattice_applied_receipts (  globalId TEXT PRIMARY KEY)") != 0) return 0;
        ++self.barriers;
        bool floor_statement_gone = true;
        for (auto* active = sqlite3_next_stmt(self.connection, nullptr); active; active = sqlite3_next_stmt(self.connection, active))
            if (is_floor(sqlite3_sql(active))) floor_statement_gone = false;
        // Only fixed metadata getters and pipe I/O: no SQL, heap formatting,
        // logger, timing sleeps, or user callbacks inside the trace callback.
        const bool premise = self.barriers == 1 && self.floor_rows == 1 && self.floor_profiles == 1 &&
            self.floor_count == 1 && self.floor_value == rows && self.begin_count == 0 &&
            sqlite3_get_autocommit(self.connection) == 1 &&
            sqlite3_txn_state(self.connection, "main") == SQLITE_TXN_NONE && floor_statement_gone;
        if (!premise) {
            constexpr char failed[] = "{\"kind\":\"barrierPremiseFailed\"}\n";
            self.failed = true; write_all(failed, sizeof(failed) - 1); return 0;
        }
        constexpr char ready[] = "{\"kind\":\"floorBarrier\",\"floorCount\":1,\"floorValue\":12,\"floorFinalized\":true,\"autocommit\":true,\"transactionState\":0,\"beginCount\":0}\n";
        if (!write_all(ready, sizeof(ready) - 1)) { self.failed = true; return 0; }
        char command = 0; ssize_t count;
        do { count = ::read(STDIN_FILENO, &command, 1); } while (count < 0 && errno == EINTR);
        if (count != 1 || command != 'G') self.failed = true;
        return 0;
    }
};
void prune(const std::string& path, const std::string& operation) {
    lattice_db owner(config(path)); auto& db = owner.db();
    trace_state trace; trace.connection = db.handle();
    require(sqlite3_trace_v2(trace.connection, SQLITE_TRACE_STMT | SQLITE_TRACE_ROW | SQLITE_TRACE_PROFILE,
                           trace_state::trace, &trace) == SQLITE_OK, "trace install");
    // Restore before trace's stack lifetime ends, including thrown prune paths.
    struct trace_guard { sqlite3* db; ~trace_guard() { sqlite3_trace_v2(db, 0, nullptr, nullptr); } } guard{trace.connection};
    const auto deleted = operation == "age" ? owner.prune_audit_log(600) : owner.safe_compact_audit_log();
    require(!trace.failed && trace.barriers == 1 && trace.floor_rows == 1 && trace.floor_profiles == 1 &&
            trace.floor_count == 1 && trace.floor_value == rows && trace.begin_count == 1, "trace handshake/order");
    require(sqlite3_trace_v2(trace.connection, 0, nullptr, nullptr) == SQLITE_OK, "trace remove");
    emit({{"kind", "pruned"}, {"operation", operation}, {"deleted", deleted}, {"floorRows", trace.floor_rows},
          {"floorProfiles", trace.floor_profiles}, {"barriers", trace.barriers}, {"beginCount", trace.begin_count}});
    // owner/guard destruction order keeps connection alive through guard removal.
}
void mutate(const std::string& path, const std::string& mutation) {
    lattice_db owner(config(path)); auto& db = owner.db();
    const auto before = state(db);
    if (mutation == "register") {
        require(!before.at("targetRegistered").get<bool>(), "target already registered");
        register_replication_slot(db, target);
    } else {
        require(before.at("targetRegistered").get<bool>() && before.at("targetFloor") == rows, "reset target premise");
        owner.reset_sync_state(target);
    }
    const auto after = state(db);
    require(after.at("targetRegistered").get<bool>() && after.at("targetFloor") == 0, "mutator floor not zero");
    require(after.at("pending").size() == rows && after.at("audit") == after.at("pending"), "pending identities before prune");
    emit({{"kind", "mutated"}, {"mutation", mutation}, {"before", before}, {"after", after}});
    owner.close();
}
void inspect(const std::string& path) {
    database db(path, database::open_mode::read_only, 5000);
    emit({{"kind", "inspected"}, {"state", state(db)}});
}
}
int main(int argc, char** argv) {
    try {
        require(argc == 4, "role path operation/mutation required");
        lattice::set_log_level(lattice::log_level::off);
        const std::string role = argv[1], path = argv[2], variant = argv[3];
        require(std::filesystem::path(path).is_absolute(), "absolute owned fixture required");
        if (role == "seed" || role == "mutate") require(variant == "register" || variant == "reset", "mutation name");
        if (role == "prune") require(variant == "age" || variant == "compact", "operation name");
        if (role == "seed") seed(path, variant);
        else if (role == "prune") prune(path, variant);
        else if (role == "mutate") mutate(path, variant);
        else if (role == "inspect") { require(variant == "final", "inspection variant"); inspect(path); }
        else throw std::runtime_error("unknown role");
        return 0;
    } catch (const std::exception& error) {
        emit({{"kind", "failure"}, {"message", error.what()}}); return 2;
    }
}
