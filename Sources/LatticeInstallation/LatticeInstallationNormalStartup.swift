import Foundation
@_spi(Installation) import Lattice

/// The supported initial normal role is one newly registered primary MCP
/// store. Optional synced/group stores require a later approved all-store
/// profile; discovery never expands this context's authority.
public final class LatticeInstallationNormalStartup: @unchecked Sendable {
    private let context: OrdinaryInstallationContext
    public var primaryURL: URL { context.primaryURL }

    private init(_ context: OrdinaryInstallationContext) { self.context = context }

    public static func receiveEngramPrimary() throws -> LatticeInstallationNormalStartup {
        LatticeInstallationNormalStartup(try OrdinaryInstallationContext.receiveEngramPrimary())
    }

    public func configuration(_ original: Lattice.Configuration) throws -> Lattice.Configuration {
        guard case let .file(url) = original.storage, url.path == primaryURL.path else {
            throw OrdinaryInstallationContext.Failure.managedStartupRefused
        }
        var result = original
        result.ordinaryInstallationContext = context
        return result
    }
}
