#include "observation_owner.hpp"
#include <lattice.hpp>
#include <bulk_mutation.hpp>
#include <algorithm>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <thread>

#if !defined(__EMSCRIPTEN__)
namespace lattice {
namespace {
namespace frames = observation_frames;
namespace replay = frames::replay;
[[noreturn]] void refuse(const char* message) { throw std::runtime_error(message); }
void require(bool condition, const char* message) { if (!condition) refuse(message); }
struct snapshot_failure { replay::code status; };
struct owned_statement {
    sqlite3_stmt* value = nullptr;
    owned_statement(sqlite3* db, const std::string& sql) {
        require(sql.size() <= 4096, "observation owner SQL bound");
        const int rc = sqlite3_prepare_v2(db, sql.c_str(), static_cast<int>(sql.size()), &value, nullptr);
        if (rc != SQLITE_OK) { sqlite3_finalize(value); value = nullptr; refuse("observation owner prepare"); }
        database::record_statement();
    }
    ~owned_statement() { sqlite3_finalize(value); }
    int step() { return sqlite3_step(value); }
    int64_t integer(int i) {
        require(sqlite3_column_type(value, i) == SQLITE_INTEGER, "observation owner integer type");
        return sqlite3_column_int64(value, i);
    }
};
struct connection_lock {
    sqlite3_mutex* value = nullptr;
    explicit connection_lock(sqlite3* db) {
        auto* mutex = sqlite3_db_mutex(db);
        require(mutex && sqlite3_mutex_try(mutex) == SQLITE_OK, "observation owner connection busy");
        value = mutex;
    }
    ~connection_lock() { if (value) sqlite3_mutex_leave(value); }
};
bool identifier(const std::string& value) {
    if (value.empty() || value.size() > 64 || value.front() == '_') return false;
    for (unsigned char c : value)
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '_')) return false;
    return true;
}
int64_t scalar(sqlite3* db, const std::string& sql) {
    owned_statement statement(db, sql);
    require(statement.step() == SQLITE_ROW, "observation owner scalar missing");
    const auto value = statement.integer(0);
    require(statement.step() == SQLITE_DONE, "observation owner scalar cardinality");
    return value;
}
void catalog_bound(sqlite3* db) {
    // Measure before the private install/inspection implementation copies DDL.
    // No user SQL/functions execute: only stock length/cast/count over schema.
    owned_statement statement(db, "SELECT count(*),coalesce(sum(length(CAST(sql AS BLOB))),0) FROM main.sqlite_master");
    require(statement.step() == SQLITE_ROW && statement.integer(0) <= 256 &&
            statement.integer(1) <= 256 * 1024, "observation owner catalog bound");
    require(statement.step() == SQLITE_DONE, "observation owner catalog cardinality");
}
} // namespace

// Deliberately one fixed adapter, not a caller-provided transaction closure.
// Members are declared so every native scope dies before the retained writer.
struct observation_owner_access {
    swift_lattice& owner;
    std::string model;
    std::shared_ptr<database> writer;
    std::unique_lock<std::mutex> topology;
    std::unique_ptr<connection_lock> connection;
    std::unique_ptr<database::observation_delivery_scope> delivery;
    std::unique_ptr<frames::write_scope> frame;
    std::thread::id thread = std::this_thread::get_id();
    int64_t user_changes = 0, user_rowid = 0;
    size_t admitted_rows = 0;
    bool counters_saved = false, transaction_owned = false, released = false;
    std::string key;

    explicit observation_owner_access(swift_lattice& target, const std::string& name)
        : owner(target), model(name), topology(target.attach_mutex_, std::try_to_lock) {
        require(topology.owns_lock(), "observation owner topology busy");
        require(identifier(model), "observation owner unsupported model identifier");
        {
            std::lock_guard<std::mutex> publication(owner.connection_ownership_mutex_);
            require(!owner.closed_.load(std::memory_order_acquire) && owner.db_, "observation owner closed");
            writer = owner.db_;
        }
        require(!writer->is_closed(), "observation writer closed");
        connection = std::make_unique<connection_lock>(writer->internal_handle());
        delivery = std::make_unique<database::observation_delivery_scope>(*writer);
        admit();
        user_changes = writer->changes();
        user_rowid = sqlite3_last_insert_rowid(raw());
        counters_saved = true;
    }
    sqlite3* raw() const noexcept { return writer->internal_handle(); }
    static sqlite3* reader_handle(database& reader) noexcept { return reader.internal_handle(); }
    void same_thread() const { require(thread == std::this_thread::get_id(), "observation owner thread changed"); }
    void admit() {
        const auto& config = owner.config_;
        require(!config.read_only && !config.is_in_memory() && config.websocket_url.empty() &&
                config.ipc_targets.empty() && config.audit_retention_seconds == 0,
                "observation owner unsupported configuration");
        require(owner.attachment_topology_valid_ && owner.attached_dbs_.empty() &&
                !sqlite3_db_name(raw(), 2), "observation owner attachments unsupported");
        require(!writer->raw_handle_escaped_.load(std::memory_order_acquire),
                "observation owner raw handle escaped");
        require(sqlite3_get_autocommit(raw()),
                "observation owner writer is not in autocommit");
        require(!sqlite3_next_stmt(raw(), nullptr),
                "observation owner writer has outstanding statement");
        require(owner.schemas_.size() == 1 && owner.schemas_.count(model) == 1 &&
                owner.union_schemas_.empty(), "observation owner fixed schema required");
        const auto& fields = owner.schemas_.at(model);
        require(fields.size() == 1 && fields.count("value") == 1, "observation owner fixed field required");
        const auto& field = fields.at("value");
        require(field.name == "value" && field.kind == property_kind::primitive &&
                field.type == column_type::integer && !field.nullable && !field.is_vector &&
                !field.is_geo_bounds && !field.is_full_text && !field.is_indexed &&
                !field.is_unique && !field.is_union && !field.no_history &&
                (field.column_name.empty() || field.column_name == "value"),
                "observation owner unsupported field");
        const auto constraints = owner.constraints_.find(model);
        require(constraints == owner.constraints_.end() || constraints->second.empty(),
                "observation owner constraints unsupported");
        require(scalar(raw(), "SELECT disabled FROM main._SyncControl WHERE id=1") == 0,
                "observation owner requires auditing enabled");
        catalog_bound(raw());
        require(writer->physical_identity("main", {}, true) != nullptr,
                "observation owner requires validated stock file identity");
    }
    void restore_counters() noexcept {
        if (!counters_saved) return;
        // SQL changes()/total_changes() outside this API still expose metadata
        // traffic. Only the wrapper result and last_insert_rowid are preserved.
        sqlite3_set_last_insert_rowid(raw(), user_rowid);
        writer->observation_changes_ = user_changes;
        writer->observation_native_changes_ = sqlite3_changes64(raw());
        writer->observation_native_total_ = sqlite3_total_changes64(raw());
        writer->observation_changes_valid_.store(true, std::memory_order_release);
    }
    void release_native() noexcept {
        if (released) return;
        restore_counters();
        if (transaction_owned) {
            owner.txn_owner_thread_.store(std::thread::id{}, std::memory_order_release);
            owner.observation_topology_owner_.store(std::thread::id{}, std::memory_order_release);
            transaction_owned = false;
        }
        delivery.reset();
        connection.reset();
        if (topology.owns_lock()) topology.unlock();
        released = true;
    }
    ~observation_owner_access() {
        if (released) return;
        // The caller cannot migrate an admitted scope across threads.
        if (thread != std::this_thread::get_id()) std::terminate();
        if (frame) {
            try { (void)frame->rollback(); } catch (...) {}
            frame.reset(); // private scope makes its final bounded rollback attempt
            if (!sqlite3_get_autocommit(raw())) {
                // database::close is a single atomic store: no join, wait, SQL
                // or parent shutdown while attachment/SQLite ownership is held.
                writer->close();
            }
        }
        release_native(); // destructor never delivers user callbacks
    }
    frames::result enable() {
        require(!owner.observation_owner_enabled_.load(std::memory_order_acquire),
                "observation owner already enabled");
        owner.observation_owner_model_ = model;
        owner.observation_owner_enabled_.store(true, std::memory_order_release);
        frames::result result;
        try { result = frames::install(*writer); }
        catch (...) {
            owner.observation_owner_enabled_.store(false, std::memory_order_release);
            owner.observation_owner_model_.clear();
            if (!sqlite3_get_autocommit(raw())) writer->close();
            throw;
        }
        if (result.code != frames::status::ready_integrity_only) {
            owner.observation_owner_enabled_.store(false, std::memory_order_release);
            owner.observation_owner_model_.clear();
            if (!sqlite3_get_autocommit(raw())) writer->close();
        }
        release_native();
        if (!writer->is_closed()) writer->drain_if_settled();
        return result;
    }
    void begin() {
        require(owner.observation_owner_enabled_.load(std::memory_order_acquire) &&
                owner.observation_owner_model_ == model, "observation owner not enabled for model");
        try { frame.reset(new frames::write_scope(*writer, model)); }
        catch (...) { if (!sqlite3_get_autocommit(raw())) writer->close(); throw; }
        key = frame->frame_key();
        owner.txn_owner_thread_.store(thread, std::memory_order_release);
        owner.observation_topology_owner_.store(thread, std::memory_order_release);
        transaction_owned = true;
        restore_counters(); // do not expose the context UPDATE as the prior user count
    }
    void before(size_t count) {
        same_thread();
        require(!released && frame && frame->current_phase() == frames::phase::writing,
                "observation owner no writable frame");
        require(count <= 128 - admitted_rows, "observation owner mutation bound");
        admitted_rows += count;
    }
    void after() noexcept {
        user_changes = writer->changes();
        user_rowid = sqlite3_last_insert_rowid(raw());
    }
    int64_t insert(int64_t value) {
        before(1);
        frame->begin_model_write(SQLITE_INSERT);
        try { auto id = writer->insert(model, {{"value", value}}); after(); frame->end_model_write(); return id; }
        catch (...) { after(); frame->end_model_write(); throw; }
    }
    int64_t set(int64_t id, int64_t value) {
        require(id > 0, "observation owner positive identity required");
        before(1);
        frame->begin_model_write(SQLITE_UPDATE);
        try { writer->update(model, id, {{"value", value}}); after(); frame->end_model_write(); return user_changes; }
        catch (...) { after(); frame->end_model_write(); throw; }
    }
    int64_t increment(const selected_mutation_batch& batch) {
        require(!batch.failed_ && batch.objects_.size() <= 128 && batch.operations_.size() == 1 &&
                batch.operations_[0].increment && batch.operations_[0].column == "value" &&
                std::holds_alternative<int64_t>(batch.operations_[0].value),
                "observation owner only bounded value increment permitted");
        before(batch.objects_.size());
        frame->begin_model_write(SQLITE_UPDATE);
        try { const auto changed = owner.apply_selected_mutations(batch); after(); frame->end_model_write(); return changed; }
        catch (...) { after(); frame->end_model_write(); throw; }
    }
    frames::completion complete(bool commit) {
        same_thread();
        if (released || !frame) return {frames::outcome::invalid_context, 0, false};
        const auto result = commit ? frame->commit() : frame->rollback();
        if (!result.transaction_open) {
            frame.reset();
            release_native();
            // A reentrant callback may create another owner now. No restoration
            // after this point may overwrite that newer transaction's counters.
            writer->drain_if_settled();
        }
        return result;
    }
    struct source_identity {
        std::string path;
        std::shared_ptr<const physical_store_identity> identity;
    };
    static source_identity snapshot_source(swift_lattice& owner, const std::string& model) {
        observation_owner_access admitted(owner, model);
        require(owner.observation_owner_enabled_.load(std::memory_order_acquire) &&
                owner.observation_owner_model_ == model, "observation snapshot not enabled");
        source_identity source{owner.config_.path, admitted.writer->physical_identity("main", {}, true)};
        require(source.identity != nullptr, "observation snapshot source identity unavailable");
        return source; // admitted releases all native ownership, without callbacks
    }
};

namespace observation_owned {
frames::result enable(swift_lattice& owner, const std::string& model) {
    observation_owner_access admitted(owner, model);
    return admitted.enable();
}
transaction::transaction(swift_lattice& owner, const std::string& model)
    : impl_(std::make_unique<observation_owner_access>(owner, model)) { impl_->begin(); }
transaction::~transaction() = default;
int64_t transaction::insert(int64_t value) { return impl_->insert(value); }
int64_t transaction::set(int64_t id, int64_t value) { return impl_->set(id, value); }
int64_t transaction::increment(const selected_mutation_batch& batch) { return impl_->increment(batch); }
frames::completion transaction::commit() { return impl_->complete(true); }
frames::completion transaction::rollback() { return impl_->complete(false); }
const std::string& transaction::frame_key() const { impl_->same_thread(); return impl_->key; }

replay::page read_after(swift_lattice& owner, const std::string& model,
                        const replay::cursor& cursor, replay::limits limits,
                        std::shared_ptr<replay::stop_control> stop) {
    auto cancelled = [&] { return stop && stop->cancelled.load(std::memory_order_acquire); };
    auto cancelled_page = [] {
        replay::page result;
        result.result.status = replay::code::cancelled;
        return result;
    };
    if (cancelled()) return cancelled_page();
    const auto source = observation_owner_access::snapshot_source(owner, model);
    if (cancelled()) return cancelled_page();
    database reader(source.path, database::open_mode::read_only, 0);
    const auto actual = reader.physical_identity("main", {}, true);
    require(actual && *actual == *source.identity, "observation replay physical identity changed");
    // read_frames finishes the scope even on failure. Local reader destruction
    // then closes the private handle before this owned page reaches the caller.
    return replay::read_frames(reader, cursor, limits, std::move(stop));
}

struct model_capture::impl {
    std::unique_ptr<database> reader;
    std::unique_ptr<replay::read_scope> scope;
    std::string model;
    snapshot_limits limits;
    model_snapshot output;
    bool collected = false, finished = false;
    impl(swift_lattice& owner, const std::string& name, snapshot_limits cap,
         std::shared_ptr<replay::stop_control> stop) : model(name), limits(cap) {
        require(cap.max_rows > 0 && cap.max_rows <= 1024 && cap.max_bytes <= 256 * 1024 &&
                cap.max_bytes >= sizeof(model_snapshot) + cap.max_rows * sizeof(model_row),
                "observation snapshot invalid limits");
        const auto source = observation_owner_access::snapshot_source(owner, model);
        reader = std::make_unique<database>(source.path, database::open_mode::read_only, 0);
        const auto actual = reader->physical_identity("main", {}, true);
        require(actual && *actual == *source.identity, "observation snapshot physical identity changed");
        auto opened = replay::open(*reader, cap.replay, std::move(stop));
        output.barrier.result = opened.result;
        scope = std::move(opened.scope);
        if (!scope) return;
        output.rows = std::make_unique<model_row[]>(cap.max_rows);
        output.allocated_bytes = sizeof(model_snapshot) + cap.max_rows * sizeof(model_row);
    }
    ~impl() { if (scope) (void)scope->finish(); }
};
model_capture::model_capture(swift_lattice& owner, const std::string& model, snapshot_limits cap,
                             std::shared_ptr<replay::stop_control> stop)
    : impl_(std::make_unique<impl>(owner, model, cap, std::move(stop))) {}
model_capture::~model_capture() = default;
void model_capture::collect() {
    auto& self = *impl_;
    require(!self.finished && !self.collected, "observation snapshot already consumed");
    if (!self.scope) return;
    owned_statement statement(observation_owner_access::reader_handle(*self.reader),
                              "SELECT id,globalId,value FROM main.\"" + self.model + "\" ORDER BY id");
    for (;;) {
        const auto rc = statement.step();
        if (rc == SQLITE_DONE) break;
        if (rc != SQLITE_ROW) throw snapshot_failure{replay::code::database_error};
        if (self.output.row_count == self.limits.max_rows)
            throw snapshot_failure{replay::code::resource_limit};
        auto& row = self.output.rows[self.output.row_count];
        row.id = statement.integer(0); row.value = statement.integer(2);
        require(row.id > 0 && sqlite3_column_type(statement.value, 1) == SQLITE_TEXT &&
                sqlite3_column_bytes(statement.value, 1) == 36, "observation snapshot identity shape");
        const auto* text = sqlite3_column_text(statement.value, 1);
        require(text != nullptr && !std::memchr(text, 0, 36), "observation snapshot identity bytes");
        std::memcpy(row.global_id.data(), text, 36);
        ++self.output.row_count;
    }
    self.collected = true;
}
model_snapshot model_capture::fail(replay::code status) noexcept {
    auto& self = *impl_;
    model_snapshot result;
    result.barrier.result.status = status;
    if (self.scope) {
        const auto cleanup = self.scope->finish();
        result.barrier.result.cleanup_ok = cleanup.cleanup_ok && cleanup.status == replay::code::ready;
        if (!result.barrier.result.cleanup_ok) result.barrier.result.status = replay::code::rollback_failed;
    }
    self.scope.reset(); self.reader.reset(); self.output = {}; self.finished = true;
    return result;
}
model_snapshot model_capture::finish() {
    auto& self = *impl_;
    require(!self.finished, "observation snapshot already finished");
    if (!self.scope) { self.finished = true; self.reader.reset(); return std::move(self.output); }
    require(self.collected, "observation snapshot must collect model first");
    self.output.barrier = self.scope->capture_barrier();
    if (self.output.barrier.result.status != replay::code::ready)
        return fail(self.output.barrier.result.status);
    const auto cleanup = self.scope->finish();
    self.scope.reset(); self.reader.reset(); self.finished = true;
    if (cleanup.status != replay::code::ready || !cleanup.cleanup_ok) {
        self.output = {};
        self.output.barrier.result = cleanup;
        self.output.barrier.has_cursor = false;
    }
    return std::move(self.output);
}
model_snapshot capture(swift_lattice& owner, const std::string& model, snapshot_limits cap,
                       std::shared_ptr<replay::stop_control> stop) {
    model_capture scope(owner, model, cap, std::move(stop));
    try { scope.collect(); return scope.finish(); }
    catch (const snapshot_failure& error) {
        auto status = error.status;
        // collect's caller statement has finalized during unwinding. Only now
        // may protocol capture diagnose cancellation/deadline on this scope.
        if (status == replay::code::database_error && scope.impl_->scope) {
            const auto diagnostic = scope.impl_->scope->capture_barrier().result.status;
            if (diagnostic != replay::code::ready) status = diagnostic;
        }
        return scope.fail(status);
    }
    catch (const std::bad_alloc&) { return scope.fail(replay::code::resource_limit); }
    catch (...) { return scope.fail(replay::code::database_error); }
}
} // namespace observation_owned
} // namespace lattice
#endif
