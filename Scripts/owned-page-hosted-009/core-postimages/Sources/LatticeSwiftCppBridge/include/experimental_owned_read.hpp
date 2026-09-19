#pragma once
#ifdef __cplusplus
#include <bridging.hpp>

#if defined(LATTICE_EXPERIMENTAL_OWNED_READ) && LATTICE_EXPERIMENTAL_OWNED_READ && !defined(__EMSCRIPTEN__)
#if !LATTICE_HAS_FRT
#error "Experimental owned read requires matching FRT1 native and Swift owner ABI"
#endif
#include <experimental_durable_page.hpp>
#include <cstdint>
#include <string>

namespace lattice {
class swift_lattice_ref;

// PRIVATE opt-in edge. Defaults and accepted ranges match replay::limits;
// validation includes the fixed frame/row allocation before owner admission.
// max_bytes covers replay payload/descriptor allocations, not SQLite/allocator
// memory. Adoption adds fixed backing/token overhead, reported by the page.
struct experimental_owned_read_limits {
    uint64_t max_frames = 64;
    uint64_t max_rows = 1024;
    uint64_t max_bytes = 1024 * 1024;
    uint64_t max_vm_steps = 2000000;
    int64_t timeout_ms = 5000;
};

// Caller retains the ref through entry. The edge then owns a shared parent
// through synchronous read/cleanup/adoption; the returned page retains none.
// Does not enable/install the protocol, capture a model, or accept a path.
// Model is 1..64 ASCII identifier bytes (not leading '_'); cursor is exactly
// the canonical 139-byte transport. Invalid model/stop/owner: status 1;
// invalid limits: 2; invalid transport: 3. Such checks do not open a reader.
// Admission/open exceptions are sealed into last_bridge_error plus an empty
// invalid-context page. Read TLS immediately on this thread, before another
// sealed call. Native replay failures keep their exact diagnostic/snapshot.
// A valid pre-cancelled request returns cancelled before parent admission.
// Active cancellation is local to this stop. Timeout/VM-step policy starts
// inside read_frames, not owner admission/open/identity preflight; no hard
// end-to-end deadline or SQLite connection-memory bound is claimed.
// Qualification scope remains macOS FRT1 owner ABI; this is not an iOS/native
// FRT0 or public SDK event stream surface. All importers must match owner ABI.
experimental_durable_page experimental_owned_read(
    const swift_lattice_ref& owner,
    const std::string& model,
    const std::string& cursor,
    const experimental_owned_read_limits& limits,
    const experimental_durable_stop_control& stop) noexcept
    SWIFT_NAME(experimentalOwnedRead(_:model:cursor:limits:stop:));
} // namespace lattice
#endif
#endif
