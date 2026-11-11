import Testing

/// The relay apply fault hook is process-wide. Nested suites share one
/// serialization scope so every installed hook remains exclusive until cleared.
@Suite("Relay apply fault ownership", .serialized)
struct RelayApplyFaultScope {}
