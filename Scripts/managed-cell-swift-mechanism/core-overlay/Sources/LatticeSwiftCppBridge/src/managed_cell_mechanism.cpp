// Private stock-runtime mechanism diagnostic; no raw handle or callback changes.
#include <lattice.hpp>
#if defined(LATTICE_MANAGED_CELL_SWIFT_MECHANISM)
#include "../../LatticeCore/src/managed_cell_pool.hpp"
namespace lattice {
// A distinct friend avoids an ODR conflict with existing GTest test_access.
struct managed_cell_swift_mechanism_access {
    static managed_cell_mechanism_snapshot read(const database& db) {
        managed_cell_mechanism_snapshot out;
        out.closed = db.is_closed();
        out.raw_escaped = db.raw_handle_escaped_.load(std::memory_order_acquire);
        out.thread_statements = database::thread_statement_count();
        if (const auto* pool = db.managed_cell_pool_) {
            const auto value = pool->inspect();
            out.pool_present = true;
            out.hits = value.hits;
            out.prepares = value.prepares;
            out.retired = value.retired;
            out.reset_failures = value.reset_failures;
            out.idle = value.idle;
            out.retained_bytes = value.retained_bytes;
            out.active = value.active;
            out.suspensions = value.suspensions;
            out.disabled = value.disabled;
        }
        out.read_ok = true;
        return out;
    }
};
managed_cell_mechanism_snapshot
swift_lattice_ref::managed_cell_mechanism_snapshot_for_test() const noexcept {
    // impl() is PRIVATE: an out-of-line member is required, not a free caller.
    // The synchronous benchmark retains the live query owner and does not
    // concurrently close/reopen it. This does not introduce a writer lease.
    try { return managed_cell_swift_mechanism_access::read(impl().db()); }
    catch (...) { return {}; } // read_ok=false rejects diagnostic acceptance.
}
}
#endif

// BEGIN COLD-PAGE-ATTRIBUTION
#if defined(LATTICE_MANAGED_CELL_SWIFT_MECHANISM)
#include <chrono>
#include <limits>
namespace lattice {
namespace {
struct cold_attribution_state {
    bool active = false;
    uint64_t epoch = 0, started = 0;
    uint32_t current = 0;
    cold_attribution_snapshot result;
};
// Each synchronous fixture stays on its current thread. Inactive calls are no-ops.
// A crossing to another thread cannot borrow this record or produce completeness.
thread_local cold_attribution_state cold_state;
uint64_t cold_now() noexcept {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}
void cold_error() noexcept {
    if (cold_state.result.errors != std::numeric_limits<uint32_t>::max())
        ++cold_state.result.errors;
}
}
uint64_t coldAttributionBegin() noexcept {
    if (cold_state.active) { cold_error(); return 0; }
    // Never reuse a token on this thread after wraparound.
    if (cold_state.epoch == std::numeric_limits<uint64_t>::max()) return 0;
    ++cold_state.epoch;
    cold_state.active = true;
    cold_state.current = 0;
    cold_state.started = 0;
    cold_state.result = {};
    return cold_state.epoch;
}
void coldAttributionCancel(uint64_t capture) noexcept {
    if (capture && cold_state.active && capture == cold_state.epoch) {
        cold_state.active = false;
        cold_state.current = 0;
    }
}
uint64_t coldAttributionPhaseBegin(uint32_t phase, uint32_t route) noexcept {
    if (!cold_state.active) return 0;
    if (cold_state.current || phase < 1 || phase > 4 ||
        phase != cold_state.result.completed_phases + 1 ||
        (phase == 1 ? (route != 1 && route != 2) : route != 0)) {
        cold_error(); return 0;
    }
    if (phase == 1) cold_state.result.route = route; // 1 live; 2 generation.
    cold_state.current = phase;
    cold_state.started = cold_now();
    return cold_state.epoch;
}
void coldAttributionPhaseEnd(uint64_t capture, uint32_t phase, uint64_t rows) noexcept {
    if (!capture) return;
    if (!cold_state.active || capture != cold_state.epoch) return;
    if (cold_state.current != phase || phase < 1 || phase > 4) {
        cold_error(); return;
    }
    const auto now = cold_now();
    if (now < cold_state.started || rows != 100) cold_error();
    const auto elapsed = now >= cold_state.started ? now - cold_state.started : 0;
    switch (phase) {
    case 1: cold_state.result.query_ns = elapsed; cold_state.result.query_rows = rows; break;
    case 2: cold_state.result.hydrate_ns = elapsed; cold_state.result.hydrate_rows = rows; break;
    case 3: cold_state.result.boxing_ns = elapsed; cold_state.result.boxing_rows = rows; break;
    case 4: cold_state.result.model_map_ns = elapsed; cold_state.result.model_map_rows = rows; break;
    }
    cold_state.current = 0;
    ++cold_state.result.completed_phases;
}
void coldAttributionPhaseAbort(uint64_t capture, uint32_t phase) noexcept {
    if (!capture || !cold_state.active || capture != cold_state.epoch) return;
    cold_error();
    if (cold_state.current == phase) cold_state.current = 0;
}
cold_attribution_snapshot coldAttributionEnd(uint64_t capture) noexcept {
    if (!capture || !cold_state.active || capture != cold_state.epoch) return {};
    auto out = cold_state.result;
    out.complete = out.errors == 0 && out.completed_phases == 4 && cold_state.current == 0;
    coldAttributionCancel(capture);
    return out;
}
}

#endif
// END COLD-PAGE-ATTRIBUTION
