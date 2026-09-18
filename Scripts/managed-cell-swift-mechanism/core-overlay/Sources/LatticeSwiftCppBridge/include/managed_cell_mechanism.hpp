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
