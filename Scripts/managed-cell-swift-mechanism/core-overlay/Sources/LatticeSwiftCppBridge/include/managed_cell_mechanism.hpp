#pragma once
// Private diagnostic overlay only; absent unless explicitly opted in.
#if defined(LATTICE_MANAGED_CELL_SWIFT_MECHANISM)
#ifndef LATTICE_MANAGED_CELL_STATEMENT_REUSE
#error "Swift mechanism diagnostic requires the statement-reuse opt-in"
#endif
#include <cstdint>
namespace lattice {
struct managed_cell_mechanism_snapshot {
    bool read_ok = false;
    bool pool_present = false;
    bool raw_escaped = false;
    bool closed = false;
    bool disabled = false;
    uint64_t thread_statements = 0;
    uint64_t hits = 0;
    uint64_t prepares = 0;
    uint64_t retired = 0;
    uint64_t reset_failures = 0;
    uint64_t idle = 0;
    uint64_t retained_bytes = 0;
    uint64_t active = 0;
    uint64_t suspensions = 0;
};
}
#endif

// BEGIN COLD-PAGE-ATTRIBUTION
#if defined(LATTICE_MANAGED_CELL_SWIFT_MECHANISM)
#include <bridging.hpp>
namespace lattice {
// One synchronous 100-row page. No owner, row, statement or Swift pointer is retained.
struct cold_attribution_snapshot {
    bool complete = false;
    uint32_t errors = 0, completed_phases = 0, route = 0;
    uint64_t query_ns = 0, hydrate_ns = 0, boxing_ns = 0, model_map_ns = 0;
    uint64_t query_rows = 0, hydrate_rows = 0, boxing_rows = 0, model_map_rows = 0;
};
uint64_t coldAttributionBegin() noexcept;
void coldAttributionCancel(uint64_t capture) noexcept SWIFT_NAME(coldAttributionCancel(_:));
cold_attribution_snapshot coldAttributionEnd(uint64_t capture) noexcept SWIFT_NAME(coldAttributionEnd(_:));
uint64_t coldAttributionPhaseBegin(uint32_t phase, uint32_t route) noexcept
    SWIFT_NAME(coldAttributionPhaseBegin(_:route:));
void coldAttributionPhaseEnd(uint64_t capture, uint32_t phase, uint64_t rows) noexcept
    SWIFT_NAME(coldAttributionPhaseEnd(_:phase:rows:));
void coldAttributionPhaseAbort(uint64_t capture, uint32_t phase) noexcept;
class cold_attribution_phase {
    uint64_t capture_;
    uint32_t phase_;
public:
    explicit cold_attribution_phase(uint32_t phase, uint32_t route = 0) noexcept
        : capture_(coldAttributionPhaseBegin(phase, route)), phase_(phase) {}
    cold_attribution_phase(const cold_attribution_phase&) = delete;
    cold_attribution_phase& operator=(const cold_attribution_phase&) = delete;
    ~cold_attribution_phase() { coldAttributionPhaseAbort(capture_, phase_); }
    void finish(uint64_t rows) noexcept {
        coldAttributionPhaseEnd(capture_, phase_, rows);
        capture_ = 0;
    }
};
}

#endif
// END COLD-PAGE-ATTRIBUTION
