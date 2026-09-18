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
