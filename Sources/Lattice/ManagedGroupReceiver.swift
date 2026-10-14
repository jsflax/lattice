import Foundation
import CxxStdlib
import LatticeSwiftCppBridge

@_spi(ManagedOrdinary) public enum ManagedGroupReceiverError: Error, Sendable {
    case historyRequired
    case alreadyAttempted
    case incompatibleConfiguration
    case preparationRefused(String)
}

/// Custody is separate from operation completion. Native bool, not an empty
/// diagnostic or copied coordinates, establishes actual method completion.
@_spi(ManagedOrdinary) public struct ManagedGroupReceiverPreparation {
    public let receiver: ManagedGroupReceiver?
    public let failure: (any Error)?
    internal init(receiver: ManagedGroupReceiver?, failure: (any Error)?) {
        self.receiver = receiver
        self.failure = failure
    }
}

/// Opaque dormant original recipient custody, deliberately not Sendable. Native
/// owns a process-bound, monotonic registry of actual failed/successful owners.
/// Dropping/cancelling a Swift task is not cleanup, retirement or a refund. No
/// general Lattice/model accessor, current proof or close/cancel claim exists.
/// A pre-open refusal can leave its native ref empty; a nonnull Swift wrapper
/// is not a successful open or preservation receipt.
/// Use the creator context synchronously; actor isolation does not promise a
/// stable OS thread. Actual native creator/current/file/catalog checks decide.
@_spi(ManagedOrdinary) public final class ManagedGroupReceiver {
    private let history: lattice.swift_managed_history_startup
    private let context: lattice.swift_ordinary_open_context
    private var held = lattice.swift_managed_group_receiver()
    private var firstFailure: (any Error)?
    private var attempted = false

    // Native values retain the actual launch family/context. Do not retain the
    // Swift startup back from its owned receiver, which would create a cycle.
    internal init(history: lattice.swift_managed_history_startup,
                  context: lattice.swift_ordinary_open_context) {
        self.history = history
        self.context = context
    }

    /// Synchronous access on the actual creator thread, immediately after
    /// preparation. Native returns the SAME original archive capability;
    /// it rechecks completion, first failure, owner, creator and original end.
    public func preservedReceiver() throws -> OrdinaryReceiverPreservation {
        guard attempted, firstFailure == nil else {
            throw firstFailure ?? ManagedGroupReceiverError.preparationRefused("preparation unavailable")
        }
        var archive = lattice.swift_owned_receiver_preservation()
        var error = lattice.cxx_error()
        let completed = held.preservation(held: &archive, error: &error)
        guard completed, archive.valid() else {
            let message = error.msg.empty() ? "native original preservation unavailable" : String(error.msg)
            throw ManagedGroupReceiverError.preparationRefused(message)
        }
        guard error.msg.empty() else { throw error }
        return OrdinaryReceiverPreservation(archive)
    }

    internal func prepare(isolation: isolated (any Actor)?,
        for schema: [any Model.Type], configuration: Lattice.Configuration,
        expectedSchemaVersion: Int32) -> ManagedGroupReceiverPreparation {
        guard !attempted else {
            return .init(receiver: self, failure: ManagedGroupReceiverError.alreadyAttempted)
        }
        attempted = true // No body/open replay after any conversion/native failure.
        do {
            guard expectedSchemaVersion > 0, !configuration.isReadOnly,
                  case .file(let fileURL) = configuration.storage, fileURL.isFileURL,
                  configuration.ordinarySyncPolicy == .legacyProvisional,
                  configuration.ordinaryModelProfile == nil,
                  configuration.migration == nil, configuration.wssEndpoint == nil,
                  configuration.authorizationToken == nil,
                  configuration.recoverySourceExpectation == nil,
                  configuration.ipcTargets?.isEmpty != false,
                  configuration.syncFilter == nil, configuration.syncTuning == nil,
                  configuration.auditRetention == nil || configuration.auditRetention == 0,
                  configuration.busyTimeoutMs >= 0,
                  configuration.busyTimeoutMs <= 30_000,
                  !schema.isEmpty, schema.count <= 256,
                  Set(schema.map { ObjectIdentifier($0) }).count == schema.count else {
                throw ManagedGroupReceiverError.incompatibleConfiguration
            }
            // Actual retained registered context before scheduler/schema copies.
            guard context.validate_path(std.string(configuration.canonicalPath)) else {
                throw ManagedGroupReceiverError.preparationRefused(
                    String(lattice.last_bridge_error().pointee))
            }
            try Task.checkCancellation()
            var nativeConfig = configuration.cxxConfiguration(isolation: isolation)
            nativeConfig.target_schema_version = expectedSchemaVersion
            let nativeSchemas = Lattice._managedGroupReceiverSchemas(from: schema)
            var error = lattice.cxx_error()
            // The inout opaque ref is retained on this already-published wrapper
            // before Bool/error conversion. Native retains its original registry
            // entry before native open/preservation effects, including failures.
            let completed = lattice.swift_lattice_ref.prepareManagedGroupReceiver(
                swiftConfig: nativeConfig, schemas: nativeSchemas, startup: history,
                context: context, retained: &held, error: &error)
            guard completed else {
                let message = error.msg.empty() ? "native group receiver preparation refused" : String(error.msg)
                throw ManagedGroupReceiverError.preparationRefused(message)
            }
            guard error.msg.empty() else { throw error }
            // Cancellation after native work preserves exactly that held owner;
            // it neither releases debt nor converts known native failure to success.
            try Task.checkCancellation()
        } catch {
            firstFailure = error
        }
        return .init(receiver: self, failure: firstFailure)
    }
}
