import Foundation
import LatticeSwiftCppBridge
import CxxStdlib

package enum RecoveryRelayNativeError: Error, Sendable { case refused(String) }
private func recoveryRelayMessage() -> String {
    let message = String(lattice.last_bridge_error().pointee)
    return String(decoding: message.utf8.prefix(768), as: UTF8.self)
}
package final class RecoveryRelayNativeStop: @unchecked Sendable {
    private let value: lattice.relay_recovery_stop
    fileprivate init(_ value: lattice.relay_recovery_stop) { self.value = value }
    package var isLive: Bool { value.live() }
    package var isDrained: Bool { value.drained() }
    package func stop() { value.stop() }
}
/// This portable result retains only copied IDs and a payload-free counted
/// publication token. It may cross from the IO worker to its completion.
package final class RecoveryRelayNativeResult: @unchecked Sendable {
    private let value: lattice.relay_recovery_result
    package let status: Int32
    package let ids: [UUID]
    package let error: String?
    package var publishable: Bool { value.publishable() }
    fileprivate init(_ value: lattice.relay_recovery_result) {
        self.value = value; status = value.statusCode()
        let raw = value.ids()
        var ids: [UUID] = []; ids.reserveCapacity(Int(raw.size()))
        for index in 0..<raw.size() { if let id = UUID(uuidString: String(raw[index])) { ids.append(id) } }
        self.ids = ids
        let message = recoveryRelayMessage(); error = message.isEmpty ? nil : message
    }
}
private final class RecoveryRelayRouteContext {
    let onIO: @Sendable () -> Bool
    let current: @Sendable () -> Bool
    init(onIO: @escaping @Sendable () -> Bool, current: @escaping @Sendable () -> Bool) {
        self.onIO = onIO; self.current = current
    }
    deinit { precondition(onIO(), "real relay route context must release on IO") }
}
/// Package-only actual setup wrapper. The public ServerKit overload supplies
/// its real connection cell; no app-facing native admission factory exists.
package final class RecoveryRelayNativeSetup {
    private var value: lattice.relay_recovery_setup?
    private let onIO: @Sendable () -> Bool
    package let stop: RecoveryRelayNativeStop
    package let descriptor: Data
    package init(owner: Lattice, policy: Data, connection: Data,
                 onIO: @escaping @Sendable () -> Bool, current: @escaping @Sendable () -> Bool) throws {
        precondition(onIO())
        guard policy.count <= 32_768, connection.count <= 8_192,
              let policyText = String(data: policy, encoding: .utf8),
              let connectionText = String(data: connection, encoding: .utf8),
              let ref = owner.backend.asCxxLatticeRef else {
            throw RecoveryRelayNativeError.refused("relay bridge input or backend unavailable")
        }
        let route = RecoveryRelayRouteContext(onIO: onIO, current: current)
        let retained = Unmanaged.passRetained(route).toOpaque()
        let handle = ref.openRelayRecoverySetup(policy: std.string(policyText), connection: std.string(connectionText),
            context: retained, current: { pointer in
                guard let pointer else { return 0 }
                let route = Unmanaged<RecoveryRelayRouteContext>.fromOpaque(pointer).takeUnretainedValue()
                precondition(route.onIO()); return route.current() ? 1 : 0
            }, destroy: { pointer in
                guard let pointer else { return }
                let route = Unmanaged<RecoveryRelayRouteContext>.fromOpaque(pointer).takeRetainedValue()
                precondition(route.onIO()); withExtendedLifetime(route) {}
            })
        guard handle.valid() else { throw RecoveryRelayNativeError.refused(recoveryRelayMessage()) }
        let text = String(handle.descriptor())
        guard !text.isEmpty, text.utf8.count <= 32_768 else {
            handle.closeOnIO(); throw RecoveryRelayNativeError.refused(recoveryRelayMessage())
        }
        self.onIO = onIO; value = handle; stop = .init(handle.stopToken()); descriptor = Data(text.utf8)
    }
    deinit { precondition(onIO()); value?.closeOnIO() }
    package func authorize(_ data: Data) throws {
        precondition(onIO())
        guard data.count <= 32_768, let text = String(data: data, encoding: .utf8),
              let value, value.finishAuthorization(std.string(text)) else {
            throw RecoveryRelayNativeError.refused(recoveryRelayMessage())
        }
    }
    package func receive(_ data: Data) throws -> RecoveryRelayNativeResult {
        precondition(onIO())
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8), let value else {
            throw RecoveryRelayNativeError.refused("relay frame bound or retired setup")
        }
        return .init(value.receive(std.string(text)))
    }
    package func close() { precondition(onIO()); value?.closeOnIO(); value = nil }
}
