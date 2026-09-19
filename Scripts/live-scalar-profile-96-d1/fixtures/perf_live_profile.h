#pragma once
/* Diagnostic-only C seam. Not a shipped/activated profiling API. */
#if defined(LATTICE_PERF_LIVE_PROFILE) && LATTICE_PERF_LIVE_PROFILE == 1
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
struct lattice_perf_live_snapshot {
    uint64_t abi_version, enabled, faults;
    uint64_t managed_calls, prepare_calls, bind_name_calls, step_calls;
    uint64_t extract_calls, finalize_calls, row_returns;
    uint64_t prepare_ns, bind_name_ns, step_ns, extract_ns, finalize_ns;
};
/* Calling-thread only. Mode changes/reset are allowed only between samples.
 * faults is sticky until reset: 1 clock, 2 overflow, 4 nested native span,
 * 8 mode/reset while a managed query is active. A nonzero fault invalidates
 * the diagnostic sample; it never changes a database result or SQL policy. */
void lattice_perf_live_reset(int enabled);
struct lattice_perf_live_snapshot lattice_perf_live_read_snapshot(void);
/* Returns 1 on success. No fabricated zero duration on clock failure. */
int lattice_perf_thread_cpu_ns(uint64_t *out);
#ifdef __cplusplus
}
#endif
#endif
