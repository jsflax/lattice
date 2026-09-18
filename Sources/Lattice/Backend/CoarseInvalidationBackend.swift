import Foundation
import LatticeSwiftCppBridge

/// Internal wake source for bounded latest-state observation. This is a hint,
/// not an audit cursor, durable transaction ID, or proof of cross-process
/// coverage. The callback runs inline in a Core hook and must only update
/// bounded state under leaf locks. It must not query or invoke application code.
protocol CoarseInvalidationBackend: Sendable {
    func _addCoarseInvalidationHook(
        _ signal: @escaping @Sendable (InvalidationReason) -> Void
    ) throws -> UInt64
    func _removeCoarseInvalidationHook(_ token: UInt64) throws
}

enum CoarseInvalidationError: Error, Sendable, Equatable {
    case registrationFailed
    case removalFailed
}

private final class CoarseInvalidationClosure: Sendable {
    let signal: @Sendable (InvalidationReason) -> Void
    init(_ signal: @escaping @Sendable (InvalidationReason) -> Void) {
        self.signal = signal
    }
}

extension CxxBackend: CoarseInvalidationBackend {
    func _addCoarseInvalidationHook(
        _ signal: @escaping @Sendable (InvalidationReason) -> Void
    ) throws -> UInt64 {
        let box = CoarseInvalidationClosure(signal)
        // Core consumes the retained context even on failure. A second Swift
        // release here would double-free after native allocation failure.
        let context = Unmanaged.passRetained(box).toOpaque()
        let token = ref.add_coarse_invalidation_hook(
            context,
            { context, reason in
                guard let context else { return }
                let box = Unmanaged<CoarseInvalidationClosure>
                    .fromOpaque(context).takeUnretainedValue()
                box.signal(InvalidationReason(rawValue: Int32(reason)) ?? .advance)
            },
            { context in
                guard let context else { return }
                Unmanaged<CoarseInvalidationClosure>
                    .fromOpaque(context).release()
            }
        )
        guard token != 0 else { throw CoarseInvalidationError.registrationFailed }
        return token
    }

    func _removeCoarseInvalidationHook(_ token: UInt64) throws {
        guard ref.remove_coarse_invalidation_hook(token) else {
            throw CoarseInvalidationError.removalFailed
        }
    }
}
