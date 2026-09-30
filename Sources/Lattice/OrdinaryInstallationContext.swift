import Foundation
import LatticeSwiftCppBridge

/// Installation SPI: only the actual owned launch receiver can create this
/// immutable capability. It is not Codable and has no path/Boolean factory.
@_spi(Installation)
public final class OrdinaryInstallationContext: @unchecked Sendable {
    internal let native: lattice.swift_ordinary_open_context
    public let primaryURL: URL

    private init(_ native: lattice.swift_ordinary_open_context) {
        self.native = native
        primaryURL = URL(fileURLWithPath: String(native.primary_path()))
    }

    public enum Failure: Error { case managedStartupRefused }

    /// Must precede ordinary startup, logging, watchdogs, native opens and cache
    /// lookups. A failed receiver is fatal for this managed invocation.
    public static func receiveEngramPrimary() throws -> OrdinaryInstallationContext {
        let native = lattice.swift_ordinary_open_context.receive_engram_primary()
        guard native.valid() else { throw Failure.managedStartupRefused }
        return OrdinaryInstallationContext(native)
    }
}
