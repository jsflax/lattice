#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
// Internal SDK transport linkage, deliberately outside every public product
// header and the LatticeSwiftCppBridge umbrella. Only the fixed HTTPS receiver
// imports this module. This is a trusted implementation boundary, not a claim
// of protection from hostile code already linked into the same process.
#ifdef __cplusplus
extern "C" {
#endif
bool lattice_managed_directory_received_v1(uint64_t cookie,
    const void* me, size_t me_count, const void* groups, size_t groups_count,
    const void* entitlement, size_t entitlement_count);
void lattice_managed_directory_failed_v1(uint64_t cookie);
bool lattice_managed_receiver_directory_received_v1(uint64_t cookie,
    const void* me, size_t me_count, const void* groups, size_t groups_count, const void* status, size_t status_count);
void lattice_managed_receiver_directory_failed_v1(uint64_t cookie);
#ifdef __cplusplus
}
#endif
