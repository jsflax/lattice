import Foundation
import CxxStdlib
import LatticeSwiftCppBridge

@_spi(ManagedOrdinary) public enum ManagedOrdinaryStartupError: Error, Sendable {
    case receiveRefused
    case unregisteredPath
    case incompatibleConfiguration
    case openRefused(String)
}

/// Local launch custody only. This is not Sendable; receive and open on the
/// owning executor before any Lattice native cache/open. There is no public
/// path/record/nonce/configuration constructor. Server mounted history uses a
/// separate issuer and never accepts this local launch context.
@_spi(ManagedOrdinary) public final class ManagedOrdinaryStartup {
    internal let native: lattice.swift_ordinary_open_context
    private let history: lattice.swift_managed_history_startup?
    // One same-context preparation. Never replace/drop a failed native original.
    private var groupReceiverAttempt: ManagedGroupReceiver?
    private init(_ native: lattice.swift_ordinary_open_context,
                 history: lattice.swift_managed_history_startup? = nil) throws {
        guard native.valid() else { throw ManagedOrdinaryStartupError.receiveRefused }
        self.native = native; self.history = history
    }
    public static func receiveEngramPrimary() throws -> ManagedOrdinaryStartup {
        try .init(lattice.swift_ordinary_open_context.receive_engram_primary())
    }
    public static func receiveEngramHistory() throws -> ManagedOrdinaryStartup {
        try historyOwner(lattice.swift_managed_history_startup.receive_engram_history())
    }
    public static func receiveEngramPairedHistory() throws -> ManagedOrdinaryStartup {
        try historyOwner(lattice.swift_managed_history_startup.receive_engram_paired_history())
    }
    public static func receiveEngramDaemonHistory() throws -> ManagedOrdinaryStartup {
        try historyOwner(lattice.swift_managed_history_startup.receive_engram_daemon_history())
    }
    private static func historyOwner(_ issued: lattice.swift_managed_history_startup) throws -> ManagedOrdinaryStartup {
        guard issued.valid() else { throw ManagedOrdinaryStartupError.receiveRefused }
        let path = issued.primary_path()
        guard !path.empty() else { throw ManagedOrdinaryStartupError.receiveRefused }
        return try .init(issued.context_for_path(path), history: issued)
    }
    public var primaryPath: String { String(native.primary_path()) }
    /// Read-only selection data from the same retained launch family. Only
    /// context(forRegisteredPath:) and Native can admit an actual member.
    public var registeredPaths: [String] {
        guard let history else { return [primaryPath] }
        return history.registered_paths().map { String($0) }
    }
    /// Selection among the actual receiver's registered stores transports its
    /// retained family owner. This method cannot add a path to that family.
    public func context(forRegisteredPath path: String) throws -> ManagedOrdinaryStartup {
        guard let history else { throw ManagedOrdinaryStartupError.unregisteredPath }
        return try .init(history.context_for_path(std.string(path)), history: history)
    }
    /// Prepare only the registered GROUP recipient under this actual historical
    /// launch. This returns custody even on failure; it never exposes a Lattice,
    /// starts WSS/IPC, or grants row/import/current/outcome authority. The caller
    /// must retain the preparation's receiver before inspecting its failure.
    public func prepareGroupReceiver(
        isolation: isolated (any Actor)? = #isolation,
        for schema: [any Model.Type], configuration: Lattice.Configuration,
        expectedSchemaVersion: Int32) -> ManagedGroupReceiverPreparation {
        if let held = groupReceiverAttempt {
            return .init(receiver: held, failure: ManagedGroupReceiverError.alreadyAttempted)
        }
        // Before any native opening, cancellation may refuse without an owner.
        do { try Task.checkCancellation() }
        catch { return .init(receiver: nil, failure: error) }
        guard let history else {
            return .init(receiver: nil, failure: ManagedGroupReceiverError.historyRequired)
        }
        let held = ManagedGroupReceiver(history: history, context: native)
        groupReceiverAttempt = held // Publish custody before native/conversion work.
        return held.prepare(isolation: isolation, for: schema,
                            configuration: configuration,
                            expectedSchemaVersion: expectedSchemaVersion)
    }
    internal func validate(path: String) throws {
        guard native.validate_path(std.string(path)) else {
            throw ManagedOrdinaryStartupError.openRefused(String(lattice.last_bridge_error().pointee))
        }
    }
}

extension Lattice {
    /// The launch exchange has already completed before any cache/open/schema
    /// work. Historical source enrollment is genuine native post-COMMIT work;
    /// this opening call grants no recovery, WSS, ACK or administrative route.
    @_spi(ManagedOrdinary) public init(isolation: isolated (any Actor)? = #isolation,
        for schema: [any Model.Type], configuration: Configuration,
        managedStartup: ManagedOrdinaryStartup, expectedSchemaVersion: Int32) throws {
        try self.init(isolation: isolation, for: schema, configuration: configuration,
                      isSynchronizing: false, managedStartup: managedStartup,
                      managedExpectedSchemaVersion: expectedSchemaVersion)
    }
}
