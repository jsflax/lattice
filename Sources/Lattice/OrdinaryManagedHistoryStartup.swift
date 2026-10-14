import Foundation
import LatticeSwiftCppBridge

/// Strong inherited-launch custody. It is intentionally separate from the
/// ordinary per-store open view, which carries no source/profile authority.
@_spi(Installation)
public final class OrdinaryManagedHistoryStartup: @unchecked Sendable {
    private let native: lattice.swift_managed_history_startup
    public let primaryURL: URL
    public let registeredURLs: [URL]

    private init(_ native: lattice.swift_managed_history_startup) throws {
        guard native.valid() else { throw OrdinaryInstallationContext.Failure.managedStartupRefused }
        let primary = String(native.primary_path())
        let paths = native.registered_paths().map { String($0) }
        guard !primary.isEmpty, !paths.isEmpty, paths.count <= 256,
              paths.first == primary, Set(paths).count == paths.count else {
            throw OrdinaryInstallationContext.Failure.managedStartupRefused
        }
        self.native = native
        primaryURL = URL(fileURLWithPath: primary)
        registeredURLs = paths.map { URL(fileURLWithPath: $0) }
    }

    public static func receiveEngramHistory() throws -> OrdinaryManagedHistoryStartup {
        try OrdinaryManagedHistoryStartup(lattice.swift_managed_history_startup.receive_engram_history())
    }

    public static func receiveEngramPairedHistory() throws -> OrdinaryManagedHistoryStartup {
        try OrdinaryManagedHistoryStartup(lattice.swift_managed_history_startup.receive_engram_paired_history())
    }

    /// Fixed memory-sync receiver. The installed image, actual parent and both
    /// phase-2 children must match the same closed native cohort.
    public static func receiveEngramDaemonHistory() throws -> OrdinaryManagedHistoryStartup {
        try OrdinaryManagedHistoryStartup(lattice.swift_managed_history_startup.receive_engram_daemon_history())
    }

    public func configuration(_ original: Lattice.Configuration) throws -> Lattice.Configuration {
        guard case let .file(url) = original.storage,
              registeredURLs.contains(where: { $0.path == url.path }),
              original.wssEndpoint == nil, (original.ipcTargets?.isEmpty ?? true) else {
            throw OrdinaryInstallationContext.Failure.managedStartupRefused
        }
        let issued = native.context_for_path(std.string(url.path))
        var result = original
        result.ordinaryInstallationContext = try OrdinaryInstallationContext.checkedManagedView(issued)
        // A pre-enrollment constructor must not prune originals or start peers.
        result.auditRetention = nil
        return result
    }

    /// Actual declared store must already have opened through this launch's
    /// exact view. Core performs schema/physical/source enrollment atomically;
    /// a successful Boolean is only the return status, never an input grant.
    /// Receiver upgrade captures real local observations under this actual
    /// inherited restart before any authenticated receiver connection starts.
    public func preserveReceiver(_ store: Lattice) throws -> OrdinaryReceiverPreservation {
        guard let owner = store.backend.asCxxLatticeRef else {
            throw OrdinaryInstallationContext.Failure.managedStartupRefused
        }
        let cap = owner.preserveManagedReceiver(startup: native)
        guard cap.valid() else { throw OrdinaryInstallationContext.Failure.managedStartupRefused }
        return OrdinaryReceiverPreservation(cap)
    }

    public func enroll(_ store: Lattice) throws {
        guard let owner = store.backend.asCxxLatticeRef,
              owner.enroll_managed_history(native) else {
            throw OrdinaryInstallationContext.Failure.managedStartupRefused
        }
    }
}

/// Actual native local archive/managed restart custody. Coordinates and rows
/// are deliberately absent from this API; a copied store path grants nothing.
@_spi(Installation)
@_spi(ManagedOrdinary)
public final class OrdinaryReceiverPreservation: @unchecked Sendable {
    internal let native: lattice.swift_owned_receiver_preservation
    internal init(_ native: lattice.swift_owned_receiver_preservation) { self.native = native }
}
