import Foundation
import LatticeSwiftCppBridge
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Transport custody from the actual closed paired launch. This grants no
/// product route, upstream value, visibility removal, ACK or repair result.
@_spi(Installation)
public final class ManagedEngramPeerOwner: @unchecked Sendable {
    private let creator = getpid()
    internal let native: lattice.swift_managed_peer_owner
    public init(primary: Lattice) throws {
        guard let owner = primary.backend.asCxxLatticeRef else {
            throw ManagedEngramDirectorySession.Failure.refused
        }
        let actual = owner.startManagedEngramPeer()
        guard actual.valid() else { throw ManagedEngramDirectorySession.Failure.refused }
        native = actual
        guard !native.failed() else {
            native.stop()
            throw ManagedEngramDirectorySession.Failure.refused
        }
    }
    public var hasFailed: Bool { creator != getpid() || native.failed() }
    public func stop() { guard creator == getpid() else { return }; native.stop() }
    public struct CloseResult: Sendable {
        public let cleanupComplete: Bool
        public let failed: Bool
        public let cleanupFailed: Bool
        public let nativeCode: Int32
    }
    /// Off-reader/writer actual join, SQL reconciliation and one consuming
    /// descriptor settlement under the existing separate two-second budget.
    @discardableResult public func close() -> CloseResult {
        guard creator == getpid() else {
            return .init(cleanupComplete: false, failed: true, cleanupFailed: false, nativeCode: -1)
        }
        let actual = native.close()
        return .init(cleanupComplete: actual.cleanup_complete(), failed: actual.failed(),
                     cleanupFailed: actual.cleanup_failed(), nativeCode: actual.code())
    }
    deinit { stop() } // retirement stays with the real native registry
}
