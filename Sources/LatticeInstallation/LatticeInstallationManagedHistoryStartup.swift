import Foundation
@_spi(ManagedOrdinary) import Lattice

/// The actual historical receiver retains its registered family. It supplies
/// no WSS, install, ACK, pruning or old/new lineage authority from path lookup.
/// Receive and open on the owning executor; this class is not Sendable.
public final class LatticeInstallationManagedHistoryStartup {
    private let startup: ManagedOrdinaryStartup
    private init(_ startup: ManagedOrdinaryStartup) { self.startup = startup }
    public var primaryURL: URL { URL(fileURLWithPath: startup.primaryPath) }
    public static func receiveEngramHistory() throws -> LatticeInstallationManagedHistoryStartup {
        .init(try ManagedOrdinaryStartup.receiveEngramHistory())
    }
    public static func receiveEngramPairedHistory() throws -> LatticeInstallationManagedHistoryStartup {
        .init(try ManagedOrdinaryStartup.receiveEngramPairedHistory())
    }
    public static func receiveEngramDaemonHistory() throws -> LatticeInstallationManagedHistoryStartup {
        .init(try ManagedOrdinaryStartup.receiveEngramDaemonHistory())
    }
    public func openRegistered(isolation: isolated (any Actor)? = #isolation,
        for schema: [any Lattice.Model.Type], configuration: Lattice.Configuration,
        registeredURL: URL, expectedSchemaVersion: Int32) throws -> Lattice {
        guard registeredURL.isFileURL else { throw ManagedOrdinaryStartupError.unregisteredPath }
        let issued = try startup.context(forRegisteredPath: registeredURL.path)
        return try Lattice(isolation: isolation, for: schema, configuration: configuration,
                           managedStartup: issued, expectedSchemaVersion: expectedSchemaVersion)
    }
}
