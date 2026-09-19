#include <lattice/observation_replay.hpp>
#include <lattice/db.hpp>
#include <algorithm>
#include <chrono>
#include <cstring>
#include <initializer_list>
#include <limits>
#include <new>
#include <thread>
#include <utility>

#if !defined(__EMSCRIPTEN__)
namespace lattice::observation_frames::replay {
namespace {
struct failure { diagnostic value; };
[[noreturn]] void fail(code status, int sqlite = 0) { throw failure{{status, sqlite}}; }
[[noreturn]] void frame_failure(code status, int64_t id, int64_t first, int64_t last) {
    diagnostic value{status}; value.boundary_frame_id = id;
    value.boundary_first_audit_id = first; value.boundary_last_audit_id = last;
    throw failure{value};
}
void check(int rc) { if (rc != SQLITE_OK) fail((rc & 255) == SQLITE_BUSY || (rc & 255) == SQLITE_LOCKED ? code::busy : code::database_error, rc); }
bool hex(identity value) noexcept {
    return std::all_of(value.begin(), value.end(), [](char c) { return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'); });
}
bool cursor_shape(const cursor& value) noexcept {
    if (!hex(value.store_uuid) || !hex(value.history_epoch) ||
        value.frame_id < 0 || value.after_audit_id < 0) return false;
    switch (value.kind) {
        case cursor_kind::origin:
            return value.frame_id == 0 && value.after_audit_id == 0 && value.frame_key == identity{};
        case cursor_kind::frame:
            return value.frame_id > 0 && value.after_audit_id > 0 && hex(value.frame_key);
        case cursor_kind::snapshot_barrier:
            return value.frame_id == 0 ? value.frame_key == identity{} :
                value.after_audit_id > 0 && hex(value.frame_key);
        default: return false;
    }
}
void cursor_number(encoded_cursor& text, size_t offset, int64_t number) noexcept {
    constexpr char digits[] = "0123456789abcdef";
    auto value = static_cast<uint64_t>(number);
    for (size_t i = 16; i != 0; --i) {
        text[offset + i - 1] = digits[value & 15];
        value >>= 4;
    }
}
bool cursor_number(std::string_view text, size_t offset, int64_t& number) noexcept {
    // All callers have already checked the exact 139-byte transport length.
    // Limit the high nibble before conversion, so no uint64-to-int64 overflow
    // or implementation-defined signed conversion can enter the cursor.
    if (text[offset] < '0' || text[offset] > '7') return false;
    uint64_t value = 0;
    for (size_t i = 0; i != 16; ++i) {
        const char c = text[offset + i];
        const int digit = c >= '0' && c <= '9' ? c - '0' :
            c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1;
        if (digit < 0) return false;
        value = (value << 4) | static_cast<uint64_t>(digit);
    }
    number = static_cast<int64_t>(value);
    return true;
}
identity fixed(const char* bytes, size_t count) {
    if (!bytes || count != 32) fail(code::metadata_uncertain);
    identity value{}; std::memcpy(value.data(), bytes, value.size());
    if (!hex(value)) fail(code::metadata_uncertain);
    return value;
}
struct statement {
    sqlite3_stmt* value = nullptr;
    statement(sqlite3* db, const char* sql) {
        const int rc = sqlite3_prepare_v2(db, sql, -1, &value, nullptr);
        if (rc != SQLITE_OK) { if (value) sqlite3_finalize(value); value = nullptr; check(rc); }
    }
    ~statement() { if (value) sqlite3_finalize(value); }
    statement(const statement&) = delete;
    statement& operator=(const statement&) = delete;
    void bind(int index, int64_t value_) { check(sqlite3_bind_int64(value, index, value_)); }
    bool row() {
        const int rc = sqlite3_step(value);
        if (rc == SQLITE_ROW) return true;
        if (rc == SQLITE_DONE) return false;
        check(rc); return false;
    }
    int64_t integer(int column) const {
        if (sqlite3_column_type(value, column) != SQLITE_INTEGER) fail(code::metadata_uncertain);
        return sqlite3_column_int64(value, column);
    }
    std::string_view text(int column) const {
        if (sqlite3_column_type(value, column) != SQLITE_TEXT) fail(code::metadata_uncertain);
        const auto* bytes = reinterpret_cast<const char*>(sqlite3_column_text(value, column));
        const int count = sqlite3_column_bytes(value, column);
        if (!bytes) fail(code::resource_limit, SQLITE_NOMEM);
        return {bytes, static_cast<size_t>(count)};
    }
    identity id(int column) const { const auto bytes = text(column); return fixed(bytes.data(), bytes.size()); }
};
void sql(sqlite3* db, const char* text) { check(sqlite3_exec(db, text, nullptr, nullptr, nullptr)); }
int64_t scalar(sqlite3* db, const char* text) {
    statement query(db, text);
    if (!query.row()) fail(code::metadata_uncertain);
    const auto value = query.integer(0);
    if (query.row()) fail(code::metadata_uncertain);
    return value;
}
bool valid(limits value) noexcept {
    return value.max_frames > 0 && value.max_frames <= 256 && value.max_rows > 0 && value.max_rows <= 4096 &&
        value.max_bytes >= sizeof(page) && value.max_bytes <= 8 * 1024 * 1024 &&
        value.max_vm_steps >= 128 && value.max_vm_steps <= 50000000 && value.timeout_ms > 0 && value.timeout_ms <= 30000;
}
void empty(page& value) noexcept {
    value.frames.reset(); value.rows.reset(); value.text.reset();
    value.frame_count = value.row_count = value.text_bytes = value.allocated_bytes = 0;
    value.has_cursor = value.at_head = false;
}
} // namespace

code encode_cursor(const cursor& value, encoded_cursor& output) noexcept {
    if (!cursor_shape(value)) return code::invalid_cursor;
    encoded_cursor text{};
    constexpr std::string_view prefix = "lrc1:";
    std::copy(prefix.begin(), prefix.end(), text.begin());
    switch (value.kind) {
        case cursor_kind::origin: text[5] = 'o'; break;
        case cursor_kind::frame: text[5] = 'f'; break;
        case cursor_kind::snapshot_barrier: text[5] = 's'; break;
        default: return code::invalid_cursor;
    }
    for (const size_t offset : {6, 39, 72, 105, 122}) text[offset] = ':';
    std::copy(value.store_uuid.begin(), value.store_uuid.end(), text.begin() + 7);
    std::copy(value.history_epoch.begin(), value.history_epoch.end(), text.begin() + 40);
    if (value.frame_id == 0) std::fill_n(text.begin() + 73, 32, '-');
    else std::copy(value.frame_key.begin(), value.frame_key.end(), text.begin() + 73);
    cursor_number(text, 106, value.frame_id);
    cursor_number(text, 123, value.after_audit_id);
    output = text;
    return code::ready;
}

code decode_cursor(std::string_view text, cursor& output) noexcept {
    // Reject oversized/truncated views before examining any bytes. All later
    // loops and copies have fixed bounds independent of the supplied length.
    if (text.size() != encoded_cursor_size || text.substr(0, 5) != "lrc1:") return code::invalid_cursor;
    for (const size_t offset : {6, 39, 72, 105, 122})
        if (text[offset] != ':') return code::invalid_cursor;
    cursor value;
    switch (text[5]) {
        case 'o': value.kind = cursor_kind::origin; break;
        case 'f': value.kind = cursor_kind::frame; break;
        case 's': value.kind = cursor_kind::snapshot_barrier; break;
        default: return code::invalid_cursor;
    }
    std::copy_n(text.begin() + 7, 32, value.store_uuid.begin());
    std::copy_n(text.begin() + 40, 32, value.history_epoch.begin());
    if (!cursor_number(text, 106, value.frame_id) || !cursor_number(text, 123, value.after_audit_id))
        return code::invalid_cursor;
    if (value.frame_id == 0) {
        for (size_t i = 73; i != 105; ++i) if (text[i] != '-') return code::invalid_cursor;
    } else std::copy_n(text.begin() + 73, 32, value.frame_key.begin());
    if (!cursor_shape(value)) return code::invalid_cursor;
    output = value;
    return code::ready;
}

struct read_scope::impl {
    database& owner;
    sqlite3* db;
    sqlite3_mutex* mutex = nullptr;
    limits cap;
    std::shared_ptr<stop_control> stop;
    std::thread::id thread = std::this_thread::get_id();
    std::chrono::steady_clock::time_point deadline;
    snapshot_state state;
    diagnostic finished_result{code::ready};
    code stopped = code::ready;
    uint64_t work = 0;
    int prior_busy = 0;
    bool locked = false, begun = false, policies = false, busy_changed = false, internal = true, ended = false;

    static int progress(void* opaque) noexcept {
        auto& self = *static_cast<impl*>(opaque);
        self.work += 128;
        if (self.stop && self.stop->cancelled.load(std::memory_order_relaxed)) self.stopped = code::cancelled;
        else if (std::chrono::steady_clock::now() >= self.deadline) self.stopped = code::deadline;
        else if (self.work >= self.cap.max_vm_steps) self.stopped = code::work_limit;
        return self.stopped == code::ready ? 0 : 1;
    }
    static int authorize(void* opaque, int action, const char*, const char* function, const char* schema, const char*) noexcept {
        auto& self = *static_cast<impl*>(opaque);
        if (self.internal) return SQLITE_OK;
        switch (action) {
            case SQLITE_SELECT: case SQLITE_RECURSIVE: return SQLITE_OK;
            case SQLITE_FUNCTION:
                if (function) for (const auto* allowed : {"count", "min", "max", "coalesce", "ifnull", "typeof", "length"})
                    if (sqlite3_stricmp(function, allowed) == 0) return SQLITE_OK;
                return SQLITE_DENY;
            case SQLITE_READ: return !schema || std::strcmp(schema, "main") == 0 ? SQLITE_OK : SQLITE_DENY;
            default: return SQLITE_DENY;
        }
    }
    void live() {
        if (thread != std::this_thread::get_id() || ended || owner.is_closed())
            fail(code::invalid_context);
        if (stop && stop->cancelled.load(std::memory_order_relaxed)) stopped = code::cancelled;
        else if (std::chrono::steady_clock::now() >= deadline) stopped = code::deadline;
        if (stopped != code::ready) fail(stopped, SQLITE_INTERRUPT);
        if (sqlite3_get_autocommit(db)) fail(code::invalid_context);
    }
    diagnostic translate(diagnostic value) const noexcept {
        if (stopped != code::ready && (value.sqlite_code & 255) == SQLITE_INTERRUPT) value.status = stopped;
        return value;
    }
    void catalog_bound() {
        // Bound the preexisting strict inspector's catalog/token backing before
        // invoking it, in this same immutable snapshot. No schema-cookie waiver.
        statement catalog(db, "SELECT name,sql FROM main.sqlite_schema UNION ALL SELECT name,sql FROM temp.sqlite_schema LIMIT 257");
        size_t objects = 0, bytes = 0;
        while (catalog.row()) {
            if (++objects > 256) fail(code::resource_limit);
            const auto name = catalog.text(0);
            if (name.size() > 256) fail(code::resource_limit);
            bytes += name.size();
            if (sqlite3_column_type(catalog.value, 1) != SQLITE_NULL) bytes += catalog.text(1).size();
            if (bytes > 256 * 1024) fail(code::resource_limit);
        }
    }
    void singleton_bound(const char* name, const char* query) {
        // The inspector reads singleton text into std::strings; cap corrupted
        // stored values before those copies. Missing/partial schemas remain the
        // inspector's integrity decision. No text value is copied here.
        statement exists(db, "SELECT 1 FROM main.sqlite_schema WHERE type='table' AND name=?1");
        check(sqlite3_bind_text(exists.value, 1, name, -1, SQLITE_STATIC));
        if (!exists.row()) return;
        statement cells(db, query);
        while (cells.row()) {
            const int columns = sqlite3_column_count(cells.value);
            if (columns > 16) fail(code::resource_limit);
            for (int i = 0; i < columns; ++i) {
                const int type = sqlite3_column_type(cells.value, i);
                if ((type == SQLITE_TEXT || type == SQLITE_BLOB) && sqlite3_column_bytes(cells.value, i) > 1024)
                    fail(code::resource_limit);
            }
        }
    }
    explicit impl(database& source, limits bounds, std::shared_ptr<stop_control> control)
        : owner(source), db(source.handle()), cap(bounds), stop(std::move(control)),
          deadline(std::chrono::steady_clock::now() + std::chrono::milliseconds(bounds.timeout_ms)) {
        try {
            if (!valid(cap)) fail(code::invalid_limits);
            if (!db || owner.is_closed() || !(mutex = sqlite3_db_mutex(db))) fail(code::invalid_context);
            if (sqlite3_mutex_try(mutex) != SQLITE_OK) fail(code::busy);
            locked = true;
            if (owner.is_closed() || !sqlite3_get_autocommit(db) || sqlite3_next_stmt(db, nullptr)) fail(code::invalid_context);
            prior_busy = static_cast<int>(scalar(db, "PRAGMA busy_timeout"));
            if (prior_busy < 0) fail(code::invalid_context);
            check(sqlite3_busy_timeout(db, 0)); busy_changed = true;
            check(sqlite3_set_authorizer(db, authorize, this)); policies = true;
            sqlite3_progress_handler(db, 128, progress, this);
            if (stop && stop->cancelled.load(std::memory_order_relaxed)) fail(code::cancelled);
            sql(db, "BEGIN DEFERRED"); begun = true;
            { statement pin(db, "SELECT rootpage FROM main.sqlite_schema LIMIT 1"); (void)pin.row(); }
            if (sqlite3_txn_state(db, "main") != SQLITE_TXN_READ) fail(code::invalid_context);
            {
                statement schemas(db, "PRAGMA database_list");
                while (schemas.row()) {
                    const auto name = schemas.text(1);
                    if (name != "main" && name != "temp") fail(code::invalid_context);
                }
            }
            catalog_bound();
            singleton_bound("_lattice_observation_state", "SELECT * FROM main._lattice_observation_state LIMIT 3");
            singleton_bound("_lattice_observation_write_context", "SELECT * FROM main._lattice_observation_write_context LIMIT 3");
            const auto inspected = observation_frames::inspect_in_snapshot(owner);
            if (inspected.code != observation_metadata::status::ready_integrity_only || !inspected.value) {
                diagnostic error{code::metadata_uncertain, inspected.sqlite_code};
                error.metadata_status = inspected.code;
                throw failure{error};
            }
            const auto& value = *inspected.value;
            state = {fixed(value.store_uuid.data(), value.store_uuid.size()),
                     fixed(value.history_epoch.data(), value.history_epoch.size()),
                     value.audit_head, value.capture_started_after, value.pruned_through};
            internal = false;
            live();
        } catch (const failure& error) {
            auto value = translate(error.value); const auto cleanup = finish(); value.cleanup_ok = cleanup.cleanup_ok;
            throw failure{value};
        } catch (const std::bad_alloc&) {
            diagnostic value{code::resource_limit, SQLITE_NOMEM}; value.cleanup_ok = finish().cleanup_ok;
            throw failure{value};
        } catch (...) {
            diagnostic value{code::database_error}; value.cleanup_ok = finish().cleanup_ok;
            throw failure{value};
        }
    }
    ~impl() { (void)finish(); }
    diagnostic finish() noexcept {
        if (ended) return finished_result;
        if (thread != std::this_thread::get_id()) return {code::invalid_context, 0, observation_metadata::status::not_installed, false};
        diagnostic result{code::ready};
        internal = true;
        if (policies) sqlite3_progress_handler(db, 0, nullptr, nullptr);
        if (begun && !sqlite3_get_autocommit(db)) {
            const int rc = sqlite3_exec(db, "ROLLBACK", nullptr, nullptr, nullptr);
            if (rc != SQLITE_OK || !sqlite3_get_autocommit(db)) {
                result = {code::rollback_failed, rc, observation_metadata::status::not_installed, false};
                owner.close();
            }
        }
        if (policies) { sqlite3_set_authorizer(db, nullptr, nullptr); policies = false; }
        if (busy_changed) { sqlite3_busy_timeout(db, prior_busy); busy_changed = false; }
        if (locked) { sqlite3_mutex_leave(mutex); locked = false; }
        ended = true; finished_result = result; return result;
    }
    cursor base() const noexcept { cursor value; value.store_uuid = state.store_uuid; value.history_epoch = state.history_epoch; return value; }
    cursor barrier_cursor() {
        live(); cursor value = base(); value.kind = cursor_kind::snapshot_barrier; value.after_audit_id = state.audit_head;
        statement last(db, "SELECT frame_id,frame_key,first_audit_id,last_audit_id FROM main._lattice_observation_frames ORDER BY frame_id DESC LIMIT 1");
        if (last.row()) {
            const auto id = last.integer(0), first = last.integer(2), end = last.integer(3);
            // A barrier may recover after an epoch reset or pruning, including
            // an invalidated historical anchor. Its shape and range must still
            // produce a cursor that this same snapshot can accept on replay.
            if (id <= 0 || first <= 0 || end < first || end > state.audit_head)
                fail(code::metadata_uncertain);
            value.frame_id = id; value.frame_key = last.id(1);
        }
        return value;
    }
    void validate(const cursor& after) {
        live();
        if (after.store_uuid != state.store_uuid) fail(code::foreign_store);
        if (after.history_epoch != state.history_epoch) fail(code::history_reset);
        if (after.frame_id < 0 || after.after_audit_id < 0 || after.after_audit_id > state.audit_head) fail(code::invalid_cursor);
        if (after.after_audit_id < state.pruned_through) fail(code::history_pruned);
        if (after.after_audit_id < state.capture_started_after) fail(code::coverage_unavailable);
        if (after.kind == cursor_kind::origin) {
            if (after.frame_id || after.after_audit_id || after.frame_key != identity{}) fail(code::invalid_cursor);
            return;
        }
        if (after.kind != cursor_kind::frame && after.kind != cursor_kind::snapshot_barrier) fail(code::invalid_cursor);
        if (!after.frame_id) {
            if (after.kind != cursor_kind::snapshot_barrier || after.frame_key != identity{}) fail(code::invalid_cursor);
            return;
        }
        statement anchor(db, "SELECT history_epoch,frame_key,last_audit_id,kind FROM main._lattice_observation_frames WHERE frame_id=?1");
        anchor.bind(1, after.frame_id);
        if (!anchor.row() || anchor.id(1) != after.frame_key) fail(code::invalid_cursor);
        if (after.kind == cursor_kind::frame &&
            (anchor.id(0) != state.history_epoch || anchor.integer(2) != after.after_audit_id || anchor.text(3) != "transaction"))
            fail(code::invalid_cursor);
        if (after.kind == cursor_kind::snapshot_barrier && anchor.integer(2) > after.after_audit_id) fail(code::invalid_cursor);
    }
    void no_uncovered_rows(int64_t after, int64_t before) {
        statement gap(db, "SELECT id FROM main.AuditLog WHERE id>?1 AND id<?2 LIMIT 1");
        gap.bind(1, after); gap.bind(2, before);
        if (gap.row()) fail(code::metadata_uncertain);
    }
    text_field text_into(statement& source, int column, page& output, size_t text_capacity) {
        if (sqlite3_column_type(source.value, column) == SQLITE_NULL) return {};
        const auto bytes = source.text(column);
        if (bytes.size() > text_capacity - output.text_bytes) fail(code::frame_too_large);
        text_field value{static_cast<uint32_t>(output.text_bytes), static_cast<uint32_t>(bytes.size()), false};
        if (!bytes.empty()) std::memcpy(output.text.get() + output.text_bytes, bytes.data(), bytes.size());
        output.text_bytes += bytes.size(); return value;
    }
    integer_field integer_from(statement& source, int column) {
        if (sqlite3_column_type(source.value, column) == SQLITE_NULL) return {};
        return {source.integer(column), false};
    }
    page read(const cursor& after) {
        validate(after);
        page output; output.snapshot = state; output.next = after; output.has_cursor = true;
        const size_t fixed_bytes = sizeof(page) + cap.max_frames * sizeof(frame_header) + cap.max_rows * sizeof(audit_header);
        if (fixed_bytes > cap.max_bytes) fail(code::invalid_limits);
        const size_t text_capacity = cap.max_bytes - fixed_bytes;
        output.frames = std::make_unique<frame_header[]>(cap.max_frames);
        output.rows = std::make_unique<audit_header[]>(cap.max_rows);
        if (text_capacity) output.text = std::make_unique<char[]>(text_capacity);
        output.allocated_bytes = cap.max_bytes;
        statement headers(db, "SELECT frame_id,history_epoch,frame_key,first_audit_id,last_audit_id,record_count,kind,invalidated "
                              "FROM main._lattice_observation_frames WHERE frame_id>?1 ORDER BY frame_id LIMIT ?2");
        headers.bind(1, after.frame_id); headers.bind(2, static_cast<int64_t>(cap.max_frames + 1));
        while (headers.row()) {
            live();
            if (output.frame_count == cap.max_frames) { output.result.status = code::ready; return output; }
            const int64_t id = headers.integer(0), first = headers.integer(3), last = headers.integer(4), count = headers.integer(5);
            const auto key = headers.id(2);
            if (headers.id(1) != state.history_epoch || id <= output.next.frame_id || first <= output.next.after_audit_id ||
                last < first || last > state.audit_head || count <= 0 || headers.integer(7) != 0) fail(code::metadata_uncertain);
            no_uncovered_rows(output.next.after_audit_id, first);
            if (headers.text(6) == "framing_unavailable") {
                // Deliver a known prefix first. Its next cursor still points
                // before this range, so the next call reports the explicit gap.
                if (output.frame_count) { output.result.status = code::ready; return output; }
                frame_failure(code::framing_unavailable, id, first, last);
            }
            if (headers.text(6) != "transaction") fail(code::metadata_uncertain);
            if (static_cast<uint64_t>(count) > cap.max_rows - output.row_count) {
                if (!output.frame_count) frame_failure(code::frame_too_large, id, first, last);
                output.result.status = code::ready; return output;
            }
            const size_t row_start = output.row_count, text_start = output.text_bytes;
            try {
                statement rows(db, "SELECT id,globalId,tableName,operation,rowId,globalRowId,changedFieldsNames,isFromRemote,synthesized "
                                   "FROM main.AuditLog WHERE id>=?1 AND id<=?2 ORDER BY id LIMIT ?3");
                rows.bind(1, first); rows.bind(2, last); rows.bind(3, count + 1);
                int64_t previous = 0;
                while (rows.row()) {
                    live();
                    if (output.row_count - row_start >= static_cast<uint64_t>(count)) fail(code::metadata_uncertain);
                    auto& row = output.rows[output.row_count];
                    row.id = rows.integer(0);
                    if (row.id <= previous || (!previous && row.id != first)) fail(code::metadata_uncertain);
                    previous = row.id;
                    row.global_id = text_into(rows, 1, output, text_capacity);
                    row.table_name = text_into(rows, 2, output, text_capacity);
                    row.operation = text_into(rows, 3, output, text_capacity);
                    row.row_id = integer_from(rows, 4);
                    row.global_row_id = text_into(rows, 5, output, text_capacity);
                    row.changed_field_names = text_into(rows, 6, output, text_capacity);
                    row.is_from_remote = integer_from(rows, 7);
                    row.synthesized = integer_from(rows, 8);
                    ++output.row_count;
                }
                if (output.row_count - row_start != static_cast<uint64_t>(count) || previous != last) fail(code::metadata_uncertain);
            } catch (const failure& error) {
                if (error.value.status != code::frame_too_large) throw;
                if (!output.frame_count) frame_failure(code::frame_too_large, id, first, last);
                output.row_count = row_start; output.text_bytes = text_start;
                output.result.status = code::ready; return output;
            }
            output.frames[output.frame_count++] = {key, id, first, last, row_start, static_cast<size_t>(count)};
            output.next = base(); output.next.kind = cursor_kind::frame;
            output.next.frame_id = id; output.next.frame_key = key; output.next.after_audit_id = last;
        }
        if (output.next.after_audit_id != state.audit_head) fail(code::metadata_uncertain);
        output.at_head = true; output.result.status = code::ready; return output;
    }
};

read_scope::read_scope(std::unique_ptr<impl> value) : impl_(std::move(value)) {}
read_scope::~read_scope() = default;
opened open(database& owner, limits cap, std::shared_ptr<stop_control> stop) {
    opened value;
    try {
        // Allocate the outer owner before acquiring any SQLite resource, so an
        // allocation failure cannot hide cleanup failure from a live impl.
        std::unique_ptr<read_scope> scope(new read_scope(nullptr));
        scope->impl_ = std::make_unique<read_scope::impl>(owner, cap, std::move(stop));
        value.scope = std::move(scope);
        value.result.status = code::ready;
    } catch (const failure& error) { value.result = error.value; }
      catch (const std::bad_alloc&) { value.result.status = code::resource_limit; }
      catch (...) { value.result.status = code::database_error; }
    return value;
}
diagnostic read_scope::finish() noexcept { return impl_->finish(); }
barrier read_scope::capture_barrier() {
    barrier value; value.snapshot = impl_->state;
    try {
        value.resume = impl_->barrier_cursor(); value.snapshot = impl_->state;
        value.has_cursor = true; value.result.status = code::ready;
    } catch (const failure& error) { value.result = impl_->translate(error.value); }
      catch (...) { value.result.status = code::database_error; }
    if (value.result.status != code::ready) value.result.cleanup_ok = impl_->finish().cleanup_ok;
    return value;
}
barrier read_scope::origin() {
    barrier value; value.snapshot = impl_->state;
    try {
        impl_->live();
        if (impl_->state.pruned_through) fail(code::history_pruned);
        if (impl_->state.capture_started_after) fail(code::coverage_unavailable);
        value.resume = impl_->base(); value.snapshot = impl_->state;
        value.has_cursor = true; value.result.status = code::ready;
    } catch (const failure& error) { value.result = impl_->translate(error.value); }
      catch (...) { value.result.status = code::database_error; }
    if (value.result.status != code::ready) value.result.cleanup_ok = impl_->finish().cleanup_ok;
    return value;
}
page read_scope::read_after(const cursor& after) {
    try { return impl_->read(after); }
    catch (const failure& error) {
        page value; value.result = impl_->translate(error.value); value.snapshot = impl_->state;
        value.result.cleanup_ok = impl_->finish().cleanup_ok; return value;
    } catch (const std::bad_alloc&) {
        page value; value.result.status = code::resource_limit; value.result.cleanup_ok = impl_->finish().cleanup_ok; return value;
    } catch (...) {
        page value; value.result.status = code::database_error; value.result.cleanup_ok = impl_->finish().cleanup_ok; return value;
    }
}
page read_frames(database& owner, const cursor& after, limits cap, std::shared_ptr<stop_control> stop) {
    auto session = open(owner, cap, std::move(stop));
    if (!session.scope) { page value; value.result = session.result; return value; }
    auto value = session.scope->read_after(after);
    const auto cleanup = session.scope->finish();
    value.result.cleanup_ok = value.result.cleanup_ok && cleanup.cleanup_ok;
    if (!cleanup.cleanup_ok && value.result.status == code::ready) { empty(value); value.result = cleanup; }
    return value;
}
} // namespace lattice::observation_frames::replay
#endif
