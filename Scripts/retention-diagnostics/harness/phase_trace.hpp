#pragma once
#include <sqlite3.h>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <limits>
#include <thread>

// Diagnostic-only connection-local recorder. The owner installs this after its
// command wait, runs one synchronous tick, removes the hook, and
// only then reads/formats it. No callback allocation, logging, lock, SQL, payload
// copying, expanded SQL or application callback. Text selects a fixed enum;
// unknown SQL gets only a bounded prefix fingerprint (not an identity proof).
// No SQL, paths, bound values, thread IDs or pointers are emitted. Background
// threads remain enabled; each record says whether it ran on the tick thread.
namespace retention_phases {
enum class phase : uint8_t {
    other, epoch_read, claim, watermark_max, watermark_store, watermark_bound,
    floor_schema, floor_migration, floor_read, vector_catalog, local_audit_head, watermark_cleanup, cursor_read, disabled_read,
    receipt_schema, begin, disable_sync, delete_audit, delete_sync,
    delete_receipts, restore_sync, commit, rollback, release_claim
};
inline const char* name(phase p) noexcept {
    switch (p) {
#define PHASE_NAME(value) case phase::value: return #value
        PHASE_NAME(other); PHASE_NAME(epoch_read); PHASE_NAME(claim);
        PHASE_NAME(watermark_max); PHASE_NAME(watermark_store);
        PHASE_NAME(watermark_bound); PHASE_NAME(floor_schema); PHASE_NAME(floor_migration);
        PHASE_NAME(floor_read); PHASE_NAME(vector_catalog); PHASE_NAME(local_audit_head);
        PHASE_NAME(watermark_cleanup); PHASE_NAME(cursor_read); PHASE_NAME(disabled_read);
        PHASE_NAME(receipt_schema); PHASE_NAME(begin); PHASE_NAME(disable_sync);
        PHASE_NAME(delete_audit); PHASE_NAME(delete_sync); PHASE_NAME(delete_receipts);
        PHASE_NAME(restore_sync); PHASE_NAME(commit); PHASE_NAME(rollback);
        PHASE_NAME(release_claim);
#undef PHASE_NAME
    }
    return "other";
}
inline bool prefix(const char* text, const char* expected) noexcept {
    return std::strncmp(text, expected, std::strlen(expected)) == 0;
}
inline const char* trim(const char* text) noexcept {
    if (!text) return "";
    while (*text == ' ' || *text == '\t' || *text == '\r' || *text == '\n') ++text;
    return text;
}
inline phase classify(const char* input) noexcept {
    const char* s = trim(input);
    if (prefix(s, "SELECT unixepoch('subsec')")) return phase::epoch_read;
    if (prefix(s, "INSERT INTO _lattice_meta(key, value) VALUES('audit_prune_at'")) return phase::claim;
    if (prefix(s, "SELECT COALESCE(MAX(id), 0) AS m FROM AuditLog")) return phase::watermark_max;
    if (prefix(s, "INSERT OR REPLACE INTO _lattice_meta(key, value) VALUES(?, ?)")) return phase::watermark_store;
    if (prefix(s, "SELECT MAX(CAST(value AS INTEGER)) AS m FROM _lattice_meta")) return phase::watermark_bound;
    if (prefix(s, "PRAGMA table_info(_lattice_replication_slots)")) return phase::floor_schema;
    if (std::strcmp(s, "ALTER TABLE _lattice_replication_slots ADD COLUMN is_observer INTEGER NOT NULL DEFAULT 0") == 0) return phase::floor_migration;
    if (std::strcmp(s, "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE ?") == 0) return phase::vector_catalog;
    if (std::strcmp(s, "SELECT MAX(id) AS max_id FROM AuditLog") == 0) return phase::local_audit_head;
    if (prefix(s, "SELECT COUNT(*) AS cnt, MIN(upload_floor) AS floor")) return phase::floor_read;
    if (prefix(s, "DELETE FROM _lattice_meta WHERE key LIKE 'audit_wm:%'")) return phase::watermark_cleanup;
    if (prefix(s, "SELECT COUNT(*) AS c FROM _lattice_replication_slots")) return phase::cursor_read;
    if (prefix(s, "SELECT disabled FROM _SyncControl")) return phase::disabled_read;
    if (prefix(s, "CREATE TABLE IF NOT EXISTS _lattice_applied_receipts")) return phase::receipt_schema;
    if (prefix(s, "BEGIN ") || std::strcmp(s, "BEGIN") == 0) return phase::begin;
    if (prefix(s, "UPDATE _SyncControl SET disabled = 1 WHERE id = 1")) return phase::disable_sync;
    if (prefix(s, "DELETE FROM AuditLog WHERE id <= ?")) return phase::delete_audit;
    if (prefix(s, "DELETE FROM _lattice_sync_state WHERE audit_entry_id <= ?")) return phase::delete_sync;
    if (prefix(s, "DELETE FROM _lattice_applied_receipts WHERE rowid <=")) return phase::delete_receipts;
    if (prefix(s, "UPDATE _SyncControl SET disabled = ? WHERE id = 1")) return phase::restore_sync;
    if (std::strcmp(s, "COMMIT") == 0) return phase::commit;
    if (std::strcmp(s, "ROLLBACK") == 0) return phase::rollback;
    if (prefix(s, "DELETE FROM _lattice_meta WHERE key = 'audit_prune_at' AND value = ?")) return phase::release_claim;
    return phase::other;
}
inline uint64_t now_ns() noexcept {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}
inline void increment(uint64_t& value) noexcept {
    if (value != std::numeric_limits<uint64_t>::max()) ++value;
}
struct interval {
    phase label = phase::other;
    uint64_t start_ns = 0, end_ns = 0, sqlite_profile_ns = 0;
    uint64_t unknown_sql_fingerprint = 0;
    uint16_t fingerprint_bytes = 0;
    bool fingerprint_truncated = false;
    bool finished = false, started_on_tick_thread = false, ended_on_tick_thread = false;
};
inline void fingerprint_unknown(interval& row, const char* sql) noexcept {
    // Fixed work and storage; never inspect expanded SQL or copy literal text.
    // This non-cryptographic bounded fingerprint aids source matching only;
    // collisions/truncation cannot qualify an otherwise unknown statement.
    constexpr uint16_t limit = 512;
    row.unknown_sql_fingerprint = UINT64_C(14695981039346656037);
    while (row.fingerprint_bytes < limit && sql[row.fingerprint_bytes]) {
        row.unknown_sql_fingerprint ^= static_cast<unsigned char>(sql[row.fingerprint_bytes++]);
        row.unknown_sql_fingerprint *= UINT64_C(1099511628211);
    }
    row.fingerprint_truncated = sql[row.fingerprint_bytes] != 0;
}
struct recorder {
    static constexpr size_t capacity = 256;
    static constexpr size_t active_capacity = 32;
    struct active_statement { sqlite3_stmt* statement = nullptr; size_t index = 0; };
    // Constructed on the synchronous tick thread and immutable thereafter.
    // SQLite FULLMUTEX serializes callback writes; the owner reads only after
    // unregistering the hook. No new lock or thread scheduling is introduced.
    const std::thread::id tick_thread = std::this_thread::get_id();
    std::array<interval, capacity> records{};
    std::array<active_statement, active_capacity> active{};
    size_t count = 0;
    uint64_t trigger_callbacks = 0, duplicate_starts = 0, dropped_records = 0;
    uint64_t active_overflow = 0, unmatched_profiles = 0, missing_sql = 0;
    uint64_t statement_callbacks = 0, profile_callbacks = 0;

    static int callback(unsigned event, void* context, void* statement, void* detail) noexcept {
        auto& self = *static_cast<recorder*>(context);
        auto* key = static_cast<sqlite3_stmt*>(statement);
        if (event == SQLITE_TRACE_STMT) {
            const auto started = now_ns();
            increment(self.statement_callbacks);
            // SQLite uses the same prepared-statement pointer for trigger
            // subprogram notifications. They are comments, not new executions.
            if (prefix(trim(static_cast<const char*>(detail)), "--")) {
                increment(self.trigger_callbacks); return 0;
            }
            for (const auto& slot : self.active) {
                if (slot.statement == key) { increment(self.duplicate_starts); return 0; }
            }
            const char* sql = sqlite3_sql(key);
            if (!sql) { increment(self.missing_sql); return 0; }
            active_statement* free = nullptr;
            for (auto& slot : self.active) if (!slot.statement) { free = &slot; break; }
            if (!free) { increment(self.active_overflow); return 0; }
            if (self.count == capacity) { increment(self.dropped_records); return 0; }
            const auto index = self.count++;
            auto& row = self.records[index];
            row.label = classify(sql); row.start_ns = started;
            row.started_on_tick_thread = std::this_thread::get_id() == self.tick_thread;
            if (row.label == phase::other) fingerprint_unknown(row, sql);
            *free = {key, index};
        } else if (event == SQLITE_TRACE_PROFILE) {
            const auto ended = now_ns();
            increment(self.profile_callbacks);
            for (auto& slot : self.active) {
                if (slot.statement != key) continue;
                auto& record = self.records[slot.index];
                record.end_ns = ended;
                if (detail) std::memcpy(&record.sqlite_profile_ns, detail, sizeof(uint64_t));
                record.ended_on_tick_thread = std::this_thread::get_id() == self.tick_thread;
                record.finished = true;
                slot = {};
                return 0;
            }
            increment(self.unmatched_profiles);
        }
        return 0;
    }
};
static_assert(sizeof(recorder) <= 16 * 1024, "Bounded scalar trace storage exceeded");
struct registration {
    sqlite3* connection;
    bool installed = false;
    explicit registration(sqlite3* value) noexcept : connection(value) {}
    registration(const registration&) = delete;
    registration& operator=(const registration&) = delete;
    ~registration() {
        // Remove before recorder/connection destruction on any exceptional
        // path. This only unregisters the trace hook; it runs no SQL.
        if (installed) sqlite3_trace_v2(connection, 0, nullptr, nullptr);
    }
    int install(recorder& value) noexcept {
        const int code = sqlite3_trace_v2(connection, SQLITE_TRACE_STMT | SQLITE_TRACE_PROFILE,
                                         recorder::callback, &value);
        installed = code == SQLITE_OK;
        return code;
    }
    int remove() noexcept {
        const int code = sqlite3_trace_v2(connection, 0, nullptr, nullptr);
        if (code == SQLITE_OK) installed = false;
        return code;
    }
};
} // namespace retention_phases
