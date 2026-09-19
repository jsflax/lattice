#pragma once
// PRIVATE, DEFAULT-OFF activation experiment. Deliberately absent from the
// Swift/C ABI umbrella. No public event subscription or arbitrary write closure.
#include <lattice/observation_replay.hpp>
#include <array>
#include <memory>
#include <string>

#if !defined(__EMSCRIPTEN__)
namespace lattice {
class swift_lattice;
class selected_mutation_batch;
struct observation_owner_access;
namespace observation_owned {
struct test_access;

// Fresh/internal trusted Core schema only: exactly one main-file model with one
// ordinary non-null Int64 field named value, no links/unions/indexed extensions,
// attachments, sync/retention worker, caller transaction, escaped raw handle or
// installed caller handlers. Stock SQLite + Core's own scalar functions/triggers
// are assumed; names alone do not authenticate custom VFS/auto-extensions.
// Enable installs/checks PRIVATE format2; it never upgrades/repairs old formats.
observation_frames::result enable(swift_lattice&, const std::string& model);

class transaction final {
public:
    // Caller retains the parent and exclusively owns normal writer use on this
    // thread until completion. A synchronous callback may open a NEW transaction
    // after commit returns native ownership to the parent. It may not destroy
    // the parent while this member call is returning.
    explicit transaction(swift_lattice&, const std::string& model);
    ~transaction();
    transaction(const transaction&) = delete;
    transaction& operator=(const transaction&) = delete;
    int64_t insert(int64_t value); // real model/audit triggers, Core UUID identity
    int64_t set(int64_t id, int64_t value);
    int64_t increment(const selected_mutation_batch&); // fixed value increment
    observation_frames::completion commit();
    observation_frames::completion rollback();
    const std::string& frame_key() const;
    // Completion reports a still-open/unknown transaction truthfully. On an
    // unresolved rollback error teardown logically closes the retained writer;
    // ordinary reuse is refused and the parent must be retired/recreated. No
    // continuation/async consumer may retain this thread-affine native scope.
private:
    std::unique_ptr<observation_owner_access> impl_;
};

struct model_row {
    int64_t id = 0, value = 0;
    std::array<char, 36> global_id{};
};
struct model_snapshot {
    observation_frames::replay::barrier barrier;
    std::unique_ptr<model_row[]> rows;
    size_t row_count = 0, allocated_bytes = 0;
};
struct snapshot_limits {
    size_t max_rows = 1024, max_bytes = 256 * 1024;
    observation_frames::replay::limits replay;
};
class model_capture final {
public:
    ~model_capture();
    model_capture(const model_capture&) = delete;
    model_capture& operator=(const model_capture&) = delete;
private:
    struct impl;
    std::unique_ptr<impl> impl_;
    model_capture(swift_lattice&, const std::string&, snapshot_limits,
                  std::shared_ptr<observation_frames::replay::stop_control>);
    void collect();
    model_snapshot finish();
    model_snapshot fail(observation_frames::replay::code) noexcept;
    friend struct test_access; // tests can split collect/barrier on SAME thread
    friend model_snapshot capture(swift_lattice&, const std::string&, snapshot_limits,
        std::shared_ptr<observation_frames::replay::stop_control>);
};
// Owned fresh READONLY connection, model rows + barrier in the SAME snapshot.
// Main only, fixed columns, fixed row/byte caps. These caps cover the returned
// model allocation; the separate replay limits cover protocol work/storage.
// SQLite/allocator bookkeeping is excluded. Admission can throw before capture;
// admitted read errors return a failed barrier and no partial rows/cursor.
// No SQL statement/connection survives
// return. Header replay uses the returned canonical barrier separately. Model
// values are this snapshot's values, not historical event afterimages.
model_snapshot capture(swift_lattice&, const std::string&, snapshot_limits = {},
    std::shared_ptr<observation_frames::replay::stop_control> = {});

// One synchronous, owned replay turn. Uses the same enabled-owner admission
// and physical main-file identity as capture; no caller-created database or
// borrowed writer read/interrupt target. Caller retains the parent through the
// call. The result owns only copied arrays/bytes: all reader resources are gone
// before return, so retaining a page cannot retain a WAL snapshot or the owner.
// A pre-cancelled turn does not acquire owner locks or create a reader. Active
// cancellation signals only this turn's stop_control. Admission/open failures
// can throw, as with capture; replay failures keep their exact diagnostic and
// cleanup status. Bridge callers must seal exceptions before entering Swift.
// Replay timeout/VM-step policy starts inside read_frames; preceding admission,
// connection initialization and identity lookup are not actively cancellable
// or covered by that timeout. This is not an end-to-end deadline API.
observation_frames::replay::page read_after(swift_lattice&, const std::string&,
    const observation_frames::replay::cursor&,
    observation_frames::replay::limits = {},
    std::shared_ptr<observation_frames::replay::stop_control> = {});
} // namespace observation_owned
} // namespace lattice
#endif
