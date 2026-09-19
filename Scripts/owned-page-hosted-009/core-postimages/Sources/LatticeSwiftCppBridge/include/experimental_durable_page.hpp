#pragma once
#ifdef __cplusplus
#include <bridging.hpp>
#include <array>
#include <cstdint>
#include <memory>
#include <string>

#if !defined(__EMSCRIPTEN__)
namespace lattice {
struct experimental_durable_bridge_access;
struct experimental_durable_page_test_access;

// PRIVATE experimental value edge. Deliberately absent from the umbrella and
// module map until the actual owner/Swift routing and resource policy qualify.
// Codes are explicit bridge values, never replay enum ordinals:
// 0 ready, 1 invalid_context, 2 invalid_limits, 3 invalid_cursor,
// 4 foreign_store, 5 history_reset, 6 history_pruned, 7 coverage_unavailable,
// 8 framing_unavailable, 9 metadata_uncertain, 10 frame_too_large,
// 11 resource_limit, 12 cancelled, 13 deadline, 14 work_limit, 15 busy,
// 16 database_error, 17 rollback_failed.
struct experimental_durable_diagnostic {
    int32_t status = 1;
    int32_t sqlite_code = 0;
    // 0 not_installed, 1 ready_integrity_only, 2 unsupported_format,
    // 3 unsupported_audit_shape, 4 unsupported_trigger_inventory,
    // 5 unsupported_foreign_key_inventory, 6 unsupported_temp_inventory,
    // 7 triggers_disabled, 8 integrity_uncertain, 9 invalid_context,
    // 10 database_error, 11 rollback_failed.
    int32_t metadata_status = 0;
    bool cleanup_ok = true;
    int64_t boundary_frame_id = 0;
    int64_t boundary_first_audit_id = 0;
    int64_t boundary_last_audit_id = 0;
};
struct experimental_durable_frame_header {
    int64_t id = 0, first_audit_id = 0, last_audit_id = 0;
    uint64_t row_offset = 0, row_count = 0;
};
struct experimental_durable_text_field {
    uint64_t byte_count = 0;
    bool is_null = true;
};
struct experimental_durable_integer_field {
    int64_t value = 0;
    bool is_null = true;
};
struct experimental_durable_snapshot {
    int64_t audit_head = 0, capture_started_after = 0, pruned_through = 0;
};

// Copies share one immutable backing containing the native page arrays/arena
// and its canonical 139-byte cursor. No owner, database, statement, read scope,
// stop control or callback is retained. Destruction performs no SQL.
class experimental_durable_page final {
public:
    experimental_durable_page() noexcept = default;
    experimental_durable_diagnostic result() const noexcept;
    int32_t status_code() const noexcept SWIFT_NAME(statusCode());
    std::string error_message() const SWIFT_NAME(errorMessage());
    bool has_cursor() const noexcept SWIFT_NAME(hasCursor());
    bool at_head() const noexcept SWIFT_NAME(atHead());
    uint64_t frame_count() const noexcept SWIFT_NAME(frameCount());
    uint64_t row_count() const noexcept SWIFT_NAME(rowCount());
    uint64_t text_bytes() const noexcept SWIFT_NAME(textBytes());
    // Requested native object/array/arena bytes: replay's allocated_bytes,
    // replacing sizeof(replay::page) with sizeof(backing), which includes the
    // token. Includes unused array/arena capacity. Excludes allocator and
    // shared_ptr control-block bookkeeping and each caller's fixed-size handle
    // (including inline failure diagnostics and snapshot counters/identities).
    // This is accounting information, not a reservation or admission policy.
    uint64_t allocated_backing_bytes() const noexcept SWIFT_NAME(allocatedBackingBytes());
    bool shares_backing(const experimental_durable_page&) const noexcept
        SWIFT_NAME(sharesBacking(with:));
    // Preserves the native fixed snapshot even for a failed/no-backing result.
    // Zero/default native state remains zero; this does not assert validity.
    experimental_durable_snapshot snapshot() const noexcept;

    // Bounds/field errors follow sealed(): return the default value and set
    // last_bridge_error. Read that slot immediately on the same thread.
    // Raw audit text is byte-addressed: NULL, empty, invalid UTF-8 and embedded
    // NUL remain distinct. No C-string conversion, borrowed view or extra arena.
    experimental_durable_frame_header frame(uint64_t index) const SWIFT_NAME(frame(_:));
    uint8_t frame_key_byte(uint64_t frame, uint64_t byte) const
        SWIFT_NAME(frameKeyByte(frame:byte:));
    int64_t audit_id(uint64_t row) const SWIFT_NAME(auditId(row:));
    // text field: 0 globalId, 1 tableName, 2 operation, 3 globalRowId,
    // 4 changedFieldsNames. These are stored audit headers, not model values.
    experimental_durable_text_field text_field(uint64_t row, int32_t field) const
        SWIFT_NAME(textField(row:field:));
    uint8_t text_byte(uint64_t row, int32_t field, uint64_t byte) const
        SWIFT_NAME(textByte(row:field:byte:));
    // integer field: 0 rowId, 1 isFromRemote, 2 synthesized.
    experimental_durable_integer_field integer_field(uint64_t row, int32_t field) const
        SWIFT_NAME(integerField(row:field:));
    // Snapshot identities are exactly 32 raw bytes each (0 store, 1 epoch),
    // including the original native bytes on failed/no-backing results.
    uint8_t snapshot_identity_byte(int32_t identity, uint64_t byte) const
        SWIFT_NAME(snapshotIdentityByte(identity:byte:));
    uint64_t cursor_byte_count() const noexcept SWIFT_NAME(cursorByteCount());
    uint8_t cursor_byte(uint64_t byte) const SWIFT_NAME(cursorByte(_:));
private:
    struct impl;
    std::shared_ptr<const impl> impl_;
    experimental_durable_diagnostic fallback_;
    experimental_durable_snapshot fallback_snapshot_;
    std::array<char, 32> fallback_store_uuid_{}, fallback_history_epoch_{};
    friend struct experimental_durable_bridge_access;
    friend struct experimental_durable_page_test_access;
};

// One operation's stop flag, shared only by copies of that handle. make()
// allocates the flag under sealed(), with no parent/database/SQL acquisition.
// An empty/default handle is invalid. Allocation failure returns that empty
// handle and leaves the sealed diagnostic. No global or writer interrupt.
class experimental_durable_stop_control final {
public:
    experimental_durable_stop_control() noexcept = default;
    static experimental_durable_stop_control make();
    bool is_valid() const noexcept SWIFT_NAME(isValid());
    bool is_cancelled() const noexcept SWIFT_NAME(isCancelled());
    bool same_operation(const experimental_durable_stop_control&) const noexcept
        SWIFT_NAME(sameOperation(as:));
    // Exactly a release-store of true, or a no-op for an empty handle. Does not
    // clear/set bridge errors, invoke callbacks, wait, or acknowledge cleanup.
    void cancel() const noexcept;
private:
    struct impl;
    std::shared_ptr<impl> impl_;
    friend struct experimental_durable_bridge_access;
};
} // namespace lattice
#endif
#endif
