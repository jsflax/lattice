#pragma once
#include <lattice/observation_metadata.hpp>
#include <memory>

#if !defined(__EMSCRIPTEN__)
namespace lattice { struct observation_owner_access; }
namespace lattice::observation_frames {
using observation_metadata::status;
using observation_metadata::reason;
using observation_metadata::state;
using observation_metadata::result;
using observation_metadata::visibility;

// PRIVATE format-2 experiment. Fresh stores only; neither upgrades nor accepts
// the qualified format-1 installation. No production callers or replay API.
struct install_options { int fail_after_statement = -1; }; // -1 or 0...14
// These private entry points defer opportunistic destructor optimize on this
// connection before validation, including failures. Strict cookies still apply;
// trusted explicit statistics maintenance remains an activation requirement.
result install(database&, install_options = {});
result inspect_in_snapshot(database&);

enum class phase { writing, resolving_commit, rollback_only, committed, rolled_back, outcome_unknown };
enum class outcome { committed, rolled_back, retry_commit_or_rollback, rollback_required,
                     outcome_unknown, invalid_context, database_error };
struct completion {
    outcome code = outcome::database_error;
    int sqlite_code = 0;
    bool transaction_open = false;
};
struct fault_options {
    // Fixed private seams: no callback executes under the connection mutex.
    bool fail_next_context_restore = false;
    bool fail_next_rollback = false;
};

// The caller retains and exclusively owns a plain database, on this thread,
// with NO existing authorizer, application hooks, custom functions/modules,
// outstanding prepared statements, or concurrent/raw-handle access. The scope
// holds the recursive SQLite mutex and owns authorizer policy until destruction.
// Opening a scope requires autocommit; it owns BEGIN IMMEDIATE through completion.
// Arbitrary caller transactions are refused: their prior writes cannot be given
// a complete-frame promise retroactively. Savepoints below join this outer frame.
//
// Ordinary database DML is permitted while writing. The authorizer rejects user
// transaction/DDL/PRAGMA controls, non-main writes, reserved metadata writes, and
// writes after failed COMMIT. The fixed methods below perform internal controls.
// Raw sqlite3/db_config/handler changes violate this private ownership boundary.
// This is NOT automatic database statement integration or a production policy.
// Context DML changes SQLite changes()/total_changes(); compatibility of these
// counters and insert IDs must be handled before public writer activation.
class write_scope final {
public:
    explicit write_scope(database&, fault_options = {}); // throws on admission failure
    ~write_scope(); // best-effort rollback; explicit completion reports failures
    write_scope(const write_scope&) = delete;
    write_scope& operator=(const write_scope&) = delete;
    write_scope(write_scope&&) = delete;
    write_scope& operator=(write_scope&&) = delete;
    phase current_phase() const;
    const std::string& frame_key() const;
    uint64_t savepoint(); // unique private token; throws on error
    void rollback_to(uint64_t);
    void release(uint64_t);
    completion commit();
    completion rollback();
private:
    friend struct ::lattice::observation_owner_access;
    write_scope(database&, const std::string& hooked_model);
    void begin_model_write(int sqlite_action);
    void end_model_write() noexcept;
    struct impl;
    std::unique_ptr<impl> impl_;
};
} // namespace lattice::observation_frames
#endif
