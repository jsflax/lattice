#pragma once
#include <lattice.hpp>
#include <experimental_owned_read.hpp>

// Test setup only. Swift calls the actual imported owning reader itself.
// Factory ownership exactly follows swift_lattice_ref::create's FRT1 convention.
namespace durable_runtime_fixture {
struct edge_counters {
    int32_t failures = 0, owners = 0, captures = 0, oracle_reads = 0, commits = 0;
    int32_t closes = 0, removed_files = 0;
    int32_t checkpoint_busy = -1, checkpoint_log = -1, checkpoint_done = -1;
};
lattice::swift_lattice_ref* make_edge_owner(const char* path) noexcept SWIFT_RETURNS_UNRETAINED;
std::string edge_cursor() noexcept;
bool finish_edge_owner(const lattice::swift_lattice_ref& owner,
                       const lattice::experimental_durable_page& page,
                       bool remove_file) noexcept;
edge_counters edge_statistics() noexcept;
bool edge_owner_expired() noexcept;
bool edge_backing_expired() noexcept;
}
