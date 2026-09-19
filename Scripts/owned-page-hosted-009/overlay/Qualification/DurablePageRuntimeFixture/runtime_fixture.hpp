#pragma once
#include <experimental_durable_page.hpp>
#include <error.hpp>
#include <cstdint>

// Test-only value surface. The native owner factory stays in the C++ TU with
// its accepted macOS FRT1 ABI; forcing FRT0 in Swift does not rebuild that owner.
namespace durable_runtime_fixture {
struct counters {
    int32_t failures = 0;
    int32_t real_reads = 0, captures = 0, commits = 0;
    int32_t writer_counters_preserved = 0, owner_closes = 0, owner_destructions = 0;
    int32_t checkpoint_busy = -1, checkpoint_log = -1, checkpoint_done = -1;
    int32_t pre_cancel_reads = 0, pre_cancel_status = -1;
    bool pre_cancel_cleanup = false, pre_cancel_file_absent = false;
};
lattice::experimental_durable_page make_page(const char*, const lattice::experimental_durable_stop_control&) noexcept;
lattice::experimental_durable_page pre_cancelled_read(const char*, const lattice::experimental_durable_stop_control&) noexcept;
counters statistics() noexcept;
bool backing_expired() noexcept;
// Expected data is copied directly from the native replay::page BEFORE adopt
// and owner close. It retains no page, reader, owner, stop control or callback.
int64_t expected_number(int32_t group, uint64_t row, int32_t field) noexcept;
uint8_t expected_byte(int32_t group, uint64_t row, int32_t field, uint64_t byte) noexcept;
}
