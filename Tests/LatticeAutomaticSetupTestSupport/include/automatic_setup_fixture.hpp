#pragma once
#include <lattice.hpp>
#include <cstdint>
#include <memory>

namespace lattice::automatic_setup_test_support {
// Finite test observations only. No SQLite handle, owner or admission escapes.
struct holder_facts {
    bool acquisitionSucceeded=false;
    bool workerFinished=true;
    bool releaseRequested=false;
    bool acquisitionTimedOut=false;
    bool safetyDeadlineReleased=false;
    bool writerRetired=true;
    // 0 normal; 1 unavailable owner/state; 2 missing handle/mutex; 3 unsupported platform;
    // 4 acquisition deadline; 5 canceled before acquisition; 6 mutex refusal;
    // 7 worker failure; 8 safety release.
    int32_t status=1;
};
class writer_mutex_hold {
    struct state;
    std::shared_ptr<state> value_;
    explicit writer_mutex_hold(std::shared_ptr<state>) noexcept;
    friend writer_mutex_hold hold_actual_writer(const swift_lattice_ref&) noexcept;
public:
    writer_mutex_hold()=default;
    holder_facts facts() const noexcept;
    // Thread-safe signal only: no join, SQLite call or writer destruction.
    void request_release() const noexcept SWIFT_NAME(requestRelease());
    // Invoke on the opening store's keyed IO lane before dropping the last copy.
    // Swift asserts actual key/pool membership; keyed turns can change threads.
    // Releases/joins the sole worker, then clears the actual writer on that lane.
    bool retire_on_io() const noexcept SWIFT_NAME(retireOnIO());
};
// Caller retains this actual ref across the synchronous acquisition rendezvous.
// Fixed 2s acquisition and 8s hold safety bounds. Safety release is never a
// successful contention oracle. Neither bound changes production setup policy.
writer_mutex_hold hold_actual_writer(const swift_lattice_ref&) noexcept SWIFT_NAME(holdActualWriter(_:));
}
