#pragma once

#include <cstdint>
#include <optional>
#include <string>

#if !defined(__EMSCRIPTEN__)
namespace lattice {
class database;

// PRIVATE FOUNDATION ONLY: no umbrella/modulemap/Swift/C export or callers.
// Every range has unavailable framing. This does not implement event replay,
// a snapshot/cursor barrier, repair, reset, or a retention lease.
namespace observation_metadata {

enum class status {
    not_installed,
    ready_integrity_only,
    unsupported_format,
    unsupported_audit_shape,
    unsupported_trigger_inventory,
    unsupported_foreign_key_inventory,
    unsupported_temp_inventory,
    triggers_disabled,
    integrity_uncertain,
    invalid_context,
    database_error,
    rollback_failed
};

enum class reason {
    none,
    closed_connection,
    snapshot_required,
    autocommit_required,
    write_transaction_required,
    read_only_connection,
    partial_installation,
    reserved_object,
    definition_changed,
    schema_changed,
    invalid_singleton,
    invalid_state,
    nonpositive_audit_id,
    invalid_sequence,
    sqlite_failure,
    injected_failure,
    rollback_failure
};

enum class visibility {
    snapshot_only,
    committed_by_this_call,
    pending_outer_commit
};

struct state {
    std::string store_uuid;
    std::string history_epoch;
    std::string epoch_reason;
    std::string ddl_fingerprint;
    int64_t schema_cookie = 0;
    int64_t audit_head = 0;
    int64_t capture_started_after = 0;
    int64_t pruned_through = 0;
};

struct result {
    status code = status::database_error;
    reason why = reason::none;
    visibility scope = visibility::snapshot_only;
    std::optional<state> value;
    int sqlite_code = 0;
    bool installed_now = false;
    bool owner_must_rollback = false;
    // A bounded static diagnostic, never audit payload or SQL parameter data.
    std::string message;
};

struct install_options {
    // Private deterministic qualification seam; no callback under SQLite's
    // mutex. -1 disables; 0...8 inject after the corresponding install step.
    int fail_after_statement = -1;
};

// The caller retains the database, owns exclusive use of its transaction,
// and invokes outside SQLite/application callbacks. Physical owner is main;
// attachments have their own independently installed owners and identities.
// Inspection requires an established main READ/WRITE snapshot, not merely an
// unstepped BEGIN DEFERRED. A cookie mismatch never repairs/reseeds metadata.
result inspect_in_snapshot(database&);

// Own BEGIN IMMEDIATE/COMMIT, autocommit required on entry. Success is marked
// committed only after COMMIT succeeds. Caller-write uses a unique savepoint,
// requires SQLITE_TXN_WRITE, and always returns pending_outer_commit.
// Caller savepoint names must not use the private prefix
// "_lattice_observation_install_". A saturated private counter fails closed.
//
// ACTIVATION GATE: until both metadata tables are explicitly excluded from
// lattice_db's update/change routing, installation is supported only on a
// plain, exclusively owned database with no lattice/application hooks. This
// increment adds no production caller; it must not be invoked on a live
// observed lattice_db. Do not temporarily replace hooks to bypass this gate.
// External writers that disable triggers, install TEMP/reentrant AuditLog
// writers, edit reserved metadata/writable_schema/schema_version, or replace
// the underlying file are outside this v1 protocol. Local disabled triggers
// are rejected. Audit-disabled model writes are not complete audit coverage.
result install(database&, install_options = {});
result install_in_write_transaction(database&, install_options = {});

} // namespace observation_metadata
} // namespace lattice
#endif
