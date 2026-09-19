#pragma once
// PRIVATE native-only construction/unwrap seam. No parent/SQL acquisition here.
#include <experimental_durable_page.hpp>
#include <lattice/observation_replay.hpp>
#if !defined(__EMSCRIPTEN__)
namespace lattice {
struct experimental_durable_bridge_access {
    // Consume only an owned replay::page after its reader/scope cleanup. Trusts
    // the native producer's actual array capacities/allocated_bytes contract.
    // No payload clones; failure diagnostics remain explicit and non-advancing.
    static experimental_durable_page adopt(observation_frames::replay::page) noexcept;
    // Native read job must retain this shared flag for its complete operation.
    // Empty wrapper -> empty pointer; caller must reject failed make(), rather
    // than silently proceeding without its intended cancellation capability.
    static std::shared_ptr<observation_frames::replay::stop_control> stop(
        const experimental_durable_stop_control&) noexcept;
};
}
#endif
