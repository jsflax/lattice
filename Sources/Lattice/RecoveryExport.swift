import Foundation
import LatticeSwiftCppBridge
import CxxStdlib

/// Inactive qualification surface, shared only with this package's ServerKit.
/// These are independent logical payload limits, not mount/source authority.
package struct RecoveryExportNativeLimits: Sendable {
    package let entries: Int
    package let fieldBytes: Int
    package let rawBytes: Int
    package let wireBytes: Int

    package init(entries: Int, fieldBytes: Int, rawBytes: Int, wireBytes: Int) throws {
        guard (1...1_000).contains(entries), (1...1_048_576).contains(fieldBytes),
              rawBytes >= fieldBytes, rawBytes <= 4_194_304,
              (16...8_388_608).contains(wireBytes) else { throw RecoveryExportNativeError.invalidLimits }
        self.entries = entries; self.fieldBytes = fieldBytes
        self.rawBytes = rawBytes; self.wireBytes = wireBytes
    }
}
package enum RecoveryExportNativeError: Error, Sendable, Equatable {
    case invalidLimits, unsupportedBackend, bridge(String)
}
package enum RecoveryExportNativeStatus: Int32, Sendable {
    case invalid = 0, ready, empty, unprotected, stopped, busy, failed, enqueued, consumed, refused
}
package struct RecoveryExportNativeResult: Sendable {
    package let status: RecoveryExportNativeStatus
    package let message: String?
}

/// Core proves these values retain only scalar/lock/control state. They never
/// retain a native owner, endpoint/page, callback context or payload/error.
package final class RecoveryExportNativeStop: @unchecked Sendable {
    private let value: lattice.server_export_stop
    fileprivate init(_ value: lattice.server_export_stop) { self.value = value }
    package var isValid: Bool { value.isValid() }
    package var isStopped: Bool { value.stopped() }
    package var resourcesReleased: Bool { value.resourcesReleased() }
    package func stop() { value.requestStop() }
}
package final class RecoveryExportNativeCompletion: @unchecked Sendable {
    private let value: lattice.server_export_completion
    fileprivate init(_ value: lattice.server_export_completion) { self.value = value }
    package var isValid: Bool { value.isValid() }
    package var permitsAdvance: Bool { value.permitsAdvance() }
    @discardableResult package func record(success: Bool) -> Bool { value.recordResult(success: success) }
}

private final class RecoveryExportSinkContext {
    let onIO: @Sendable () -> Bool
    let enqueue: @Sendable (UnsafeBufferPointer<UInt8>, UInt64) -> Int32
    let released: @Sendable () -> Void
    init(onIO: @escaping @Sendable () -> Bool,
         enqueue: @escaping @Sendable (UnsafeBufferPointer<UInt8>, UInt64) -> Int32,
         released: @escaping @Sendable () -> Void) {
        self.onIO = onIO; self.enqueue = enqueue; self.released = released
    }
    deinit { precondition(onIO(), "recovery export context must release on IO"); released() }
}
private func recoveryExportMessage() -> String? {
    let message = String(lattice.last_bridge_error().pointee)
    return message.isEmpty ? nil : String(decoding: message.utf8.prefix(768), as: UTF8.self)
}

/// Deliberately not Sendable. Only an IO-owned take-once box may retain this
/// object. All handle copies, including final destruction, stay on that lane.
package final class RecoveryExportNativeEndpoint {
    private var value: lattice.server_export_endpoint?
    private let onIO: @Sendable () -> Bool
    package let stop: RecoveryExportNativeStop

    package init(forQualification owner: Lattice, limits: RecoveryExportNativeLimits,
                 onIO: @escaping @Sendable () -> Bool,
                 enqueue: @escaping @Sendable (UnsafeBufferPointer<UInt8>, UInt64) -> Int32,
                 contextReleased: @escaping @Sendable () -> Void) throws {
        precondition(onIO(), "recovery export factory must run on IO")
        guard let ref = owner.backend.asCxxLatticeRef else { throw RecoveryExportNativeError.unsupportedBackend }
        var nativeLimits = lattice.server_export_limits()
        nativeLimits.entries = Int64(limits.entries); nativeLimits.field_bytes = Int64(limits.fieldBytes)
        nativeLimits.raw_bytes = Int64(limits.rawBytes); nativeLimits.wire_bytes = Int64(limits.wireBytes)
        let context = RecoveryExportSinkContext(onIO: onIO, enqueue: enqueue, released: contextReleased)
        let retained = Unmanaged.passRetained(context).toOpaque()
        // Nonnull, nonthrowing destroy is always supplied: Core consumes the
        // retain on every outcome. Never separately release a failed factory.
        let handle = ref.makeServerExportEndpointForQualification(context: retained, enqueue: { pointer, bytes, count, serial in
            guard let pointer, let length = Int(exactly: count), length >= 0,
                  length == 0 || bytes != nil else { return 0 }
            let context = Unmanaged<RecoveryExportSinkContext>.fromOpaque(pointer).takeUnretainedValue()
            precondition(context.onIO(), "recovery export sink must run on IO")
            return context.enqueue(UnsafeBufferPointer(start: bytes, count: length), serial)
        }, destroy: { pointer in
            guard let pointer else { return }
            let context = Unmanaged<RecoveryExportSinkContext>.fromOpaque(pointer).takeRetainedValue()
            precondition(context.onIO(), "recovery export context must release on IO")
            withExtendedLifetime(context) {}
        }, limits: nativeLimits)
        let error = recoveryExportMessage()
        guard handle.isValid() else { throw RecoveryExportNativeError.bridge(error ?? "native endpoint refused") }
        self.onIO = onIO; self.value = handle; self.stop = .init(handle.stopToken())
        precondition(stop.isValid)
    }
    deinit { precondition(onIO(), "native endpoint final release must run on IO"); value?.closeOnIO() }
    package func prepare(after: Int64, count: Int) -> RecoveryExportNativePage {
        precondition(onIO())
        guard let value else { return .init(emptyOnIO: onIO) }
        let page = value.prepareHistory(afterAuditId: after, maximumEntries: Int64(count))
        return .init(page, message: recoveryExportMessage(), onIO: onIO)
    }
    package func close() {
        precondition(onIO()); value?.closeOnIO(); value = nil
    }
}
package final class RecoveryExportNativePage {
    private var value: lattice.server_export_page?
    private let onIO: @Sendable () -> Bool
    package let result: RecoveryExportNativeResult
    package let count: Int
    package let lastID: Int64?
    package let serial: UInt64
    package let completion: RecoveryExportNativeCompletion
    fileprivate init(_ value: lattice.server_export_page, message: String?, onIO: @escaping @Sendable () -> Bool) {
        precondition(onIO()); self.value = value; self.onIO = onIO
        result = .init(status: .init(rawValue: value.statusCode()) ?? .failed, message: message)
        count = Int(value.count()); lastID = value.hasLastAuditId() ? value.lastAuditId() : nil; serial = value.serial()
        completion = .init(value.completionToken())
    }
    fileprivate convenience init(emptyOnIO onIO: @escaping @Sendable () -> Bool) {
        self.init(lattice.server_export_page(), message: "endpoint already retired", onIO: onIO)
    }
    deinit { precondition(onIO(), "native page final release must run on IO"); value?.closeOnIO() }
    package func consume() -> RecoveryExportNativeResult {
        precondition(onIO())
        guard let value else { return .init(status: .consumed, message: nil) }
        let status = RecoveryExportNativeStatus(rawValue: value.consume()) ?? .failed
        let message = recoveryExportMessage()
        value.closeOnIO(); self.value = nil
        return .init(status: status, message: message)
    }
    package func close() { precondition(onIO()); value?.closeOnIO(); value = nil }
}
