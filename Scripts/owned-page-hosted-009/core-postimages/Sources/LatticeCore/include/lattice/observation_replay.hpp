#pragma once
#include <lattice/observation_frames.hpp>
#include <array>
#include <atomic>
#include <cstddef>
#include <memory>
#include <string_view>

#if !defined(__EMSCRIPTEN__)
namespace lattice::observation_frames::replay {

// PRIVATE native protocol consumer. No production writer/hook/consumer wiring.
using identity = std::array<char, 32>;
enum class code {
    ready, invalid_context, invalid_limits, invalid_cursor, foreign_store,
    history_reset, history_pruned, coverage_unavailable, framing_unavailable,
    metadata_uncertain, frame_too_large, resource_limit, cancelled, deadline,
    work_limit, busy, database_error, rollback_failed
};
enum class cursor_kind { origin, frame, snapshot_barrier };
struct cursor {
    identity store_uuid{}, history_epoch{}, frame_key{};
    int64_t frame_id = 0, after_audit_id = 0;
    cursor_kind kind = cursor_kind::origin;
};
// PRIVATE persistence representation of this existing cursor, not a new frame
// protocol. Exactly 139 ASCII bytes, with no trailing NUL:
// lrc1:{o|f|s}:store32:epoch32:key32:frame16:after16
// Identities and fixed-width nonnegative int64 values use lowercase hex.
// An absent frame key is exactly 32 '-' bytes (distinct from the valid all-zero
// hex identity). Stable kind tags do not serialize enum ordinals or padding.
inline constexpr size_t encoded_cursor_size = 139;
using encoded_cursor = std::array<char, encoded_cursor_size>;
// Allocation-free; invalid shape, unknown version, noncanonical bytes or any
// other input length return invalid_cursor and leave the output unchanged.
// Decode only validates transport and shape. read_frames still authenticates
// store/epoch/anchor, pruning and coverage against its retained snapshot. This
// token is neither a retention lease nor an authenticated capability.
code encode_cursor(const cursor&, encoded_cursor&) noexcept;
code decode_cursor(std::string_view, cursor&) noexcept;
struct snapshot_state {
    identity store_uuid{}, history_epoch{};
    int64_t audit_head = 0, capture_started_after = 0, pruned_through = 0;
};
struct stop_control { std::atomic<bool> cancelled{false}; };
struct limits {
    size_t max_frames = 64, max_rows = 1024, max_bytes = 1024 * 1024;
    uint64_t max_vm_steps = 2000000;
    int timeout_ms = 5000;
};
struct diagnostic {
    code status = code::database_error;
    int sqlite_code = 0;
    observation_metadata::status metadata_status = observation_metadata::status::not_installed;
    bool cleanup_ok = true;
    int64_t boundary_frame_id = 0, boundary_first_audit_id = 0, boundary_last_audit_id = 0;
};
struct text_field {
    uint32_t offset = 0, size = 0;
    bool is_null = true;
};
struct integer_field { int64_t value = 0; bool is_null = true; };
// Headers preserve stored NULLs and bytes, including embedded NUL. No current
// model values or changedFields payload is reconstructed or late-bound.
struct audit_header {
    int64_t id = 0;
    text_field global_id, table_name, operation, global_row_id, changed_field_names;
    integer_field row_id, is_from_remote, synthesized;
};
struct frame_header {
    identity key{};
    int64_t id = 0, first_audit_id = 0, last_audit_id = 0;
    size_t row_offset = 0, row_count = 0;
};
struct page {
    diagnostic result;
    snapshot_state snapshot;
    cursor next;
    bool has_cursor = false, at_head = false;
    size_t frame_count = 0, row_count = 0, text_bytes = 0, allocated_bytes = 0;
    // Fixed allocations, no growing vectors/strings or transient second frame.
    // max_bytes covers sizeof(page), these arrays and the text arena. Allocator
    // bookkeeping and SQLite internal memory are not included in that budget.
    std::unique_ptr<frame_header[]> frames;
    std::unique_ptr<audit_header[]> rows;
    std::unique_ptr<char[]> text;
    std::string_view value(text_field field) const noexcept {
        return field.is_null || field.size == 0 || field.offset > text_bytes || field.size > text_bytes - field.offset ? std::string_view{} :
            std::string_view(text.get() + field.offset, field.size);
    }
};
struct barrier {
    diagnostic result;
    snapshot_state snapshot;
    cursor resume;
    bool has_cursor = false;
};

class read_scope;
struct opened {
    diagnostic result;
    std::unique_ptr<read_scope> scope;
};

// Retained plain owner, same thread, exclusively used for the whole scope.
// No owner retention is performed by this API: the caller keeps database alive
// through scope destruction, on the creating thread, and finalizes any caller
// statements before finishing/destroying the scope.
// No outstanding statements/transaction, application hooks, custom functions or
// modules, existing authorizer/progress/custom busy handler, concurrent raw
// access, or attachments. This is an explicit PRIVATE compatibility boundary.
// A read-only authorizer prevents caller DML/control/DDL and admits only a small
// scalar-function set (count/min/max/coalesce/ifnull/typeof/length). Caller SELECTs and
// capture_barrier see one established main snapshot. The caller owns the model
// snapshot's row/byte accounting; barrier capture returns only a fixed token.
// Scope must be finished/destroyed before yielding to an async consumer. The
// cooperative deadline does not asynchronously destroy an idle retained scope.
// No borrowed-writer interrupt target is installed. Busy fails immediately and
// the prior ordinary busy timeout is restored. No v1/v2 repair or upgrade occurs.
class read_scope final {
public:
    ~read_scope();
    read_scope(const read_scope&) = delete;
    read_scope& operator=(const read_scope&) = delete;
    barrier capture_barrier();
    // Only succeeds for a history whose capture began at zero. Otherwise an
    // explicit snapshot barrier is required; no preinstallation gap is hidden.
    barrier origin();
    page read_after(const cursor&);
    diagnostic finish() noexcept;
private:
    struct impl;
    std::unique_ptr<impl> impl_;
    explicit read_scope(std::unique_ptr<impl>);
    friend opened open(database&, limits, std::shared_ptr<stop_control>);
};
opened open(database&, limits = {}, std::shared_ptr<stop_control> = {});
// Fully owned result; statements, read transaction, handlers and mutex are all
// released before return, including error/cancellation paths.
page read_frames(database&, const cursor&, limits = {}, std::shared_ptr<stop_control> = {});

} // namespace lattice::observation_frames::replay
#endif
