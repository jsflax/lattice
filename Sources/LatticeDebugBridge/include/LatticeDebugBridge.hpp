#ifndef lattice_debug_bridge_hpp
#define lattice_debug_bridge_hpp
#ifdef __cplusplus
// The convenience umbrella also defines unrelated non-inline exception helpers.
// Include the underlying declarations to avoid emitting duplicate Core symbols.
#include <lattice.hpp>

// Additive diagnostic helpers over the published Core API. Every function
// contains C++ exceptions and reports them through lattice::last_bridge_error.
namespace lattice_debug {
// Test-only forwarding to Core's existing generation active-read witness.
// No new Core behavior. Configure a quiescent reader; callback runs after
// in_flight increments and before SQL. The internal Swift wrapper is DEBUG-only.
bool set_generation_query_gap_for_testing(const lattice::swift_lattice_ref& reference,
                                          void* context,
                                          void (*callback)(void*),
                                          void (*destroy)(void*))
    SWIFT_NAME(setGenerationQueryGapForTesting(_:context:callback:destroy:));
#if LATTICE_HAS_FRT
lattice::dynamic_object_ref* get_object(const lattice::dynamic_object_ref& parent,
                                      const std::string& name)
    SWIFT_NAME(getObject(_:named:)) SWIFT_RETURNS_UNRETAINED;
lattice::dynamic_object_ref* list_object(const lattice::dynamic_object_ref& parent,
                                       const std::string& name, size_t index)
    SWIFT_NAME(listObject(_:named:at:)) SWIFT_RETURNS_UNRETAINED;
#else
lattice::dynamic_object_ref get_object(const lattice::dynamic_object_ref& parent,
                                     const std::string& name) SWIFT_NAME(getObject(_:named:));
lattice::dynamic_object_ref list_object(const lattice::dynamic_object_ref& parent,
                                      const std::string& name, size_t index) SWIFT_NAME(listObject(_:named:at:));
#endif
size_t list_count(const lattice::dynamic_object_ref& parent, const std::string& name)
    SWIFT_NAME(listCount(_:named:));
}
#endif
#endif
