import Foundation
@_spi(ManagedOrdinary) import Lattice

/// The native fixed launch receiver issues this retained owner. A path selects
/// its existing primary only; it cannot create or enroll an installation.
/// Receive and open on the owning executor before other native opens.
public final class LatticeInstallationNormalStartup {
    private let startup: ManagedOrdinaryStartup
    private init(_ startup: ManagedOrdinaryStartup) { self.startup = startup }
    public var primaryURL: URL { URL(fileURLWithPath: startup.primaryPath) }
    public static func receiveEngramPrimary() throws -> LatticeInstallationNormalStartup {
        .init(try ManagedOrdinaryStartup.receiveEngramPrimary())
    }
    public func open(isolation: isolated (any Actor)? = #isolation,
        for schema: [any Lattice.Model.Type], configuration: Lattice.Configuration,
        expectedSchemaVersion: Int32) throws -> Lattice {
        try Lattice(isolation: isolation, for: schema, configuration: configuration,
                    managedStartup: startup, expectedSchemaVersion: expectedSchemaVersion)
    }
}
