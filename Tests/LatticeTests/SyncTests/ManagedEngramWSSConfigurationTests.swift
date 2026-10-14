import Foundation
import Testing
@_spi(Installation) @testable import Lattice

// Configuration/custody cases only. Positive live receipt coverage belongs to
// the actual managed child + authenticated peer fixture, never a fake profile.
@Suite("Managed Engram WSS configuration", .serialized)
struct ManagedEngramWSSConfigurationTests {
    @Test func fixedPersonalAndGroupEndpointsPreserveOriginalOwnerConfiguration() throws {
        let session = try ManagedEngramDirectorySession(endpoint: URL(string: "https://example.invalid/base/")!, authorizationToken: "actual-fixture-token")
        defer { session.revoke() }
        let original = Lattice.Configuration(storage: .memory())
        let personal = try session.configuredWSS(original)
        let groupID = UUID(uuidString: "aabbccdd-1122-3344-5566-aabbccddeeff")!
        let group = try session.configuredWSS(original, group: groupID)
        #expect(original.wssEndpoint == nil)
        #expect(original.authorizationToken == nil)
        #expect(original.managedEngramDirectorySession == nil)
        #expect(personal.storage == original.storage)
        #expect(personal.wssEndpoint?.absoluteString == "wss://example.invalid/base/sync")
        #expect(group.wssEndpoint?.absoluteString == "wss://example.invalid/base/sync/group/AABBCCDD-1122-3344-5566-AABBCCDDEEFF")
        #expect(personal.authorizationToken == "actual-fixture-token")
        #expect(group.authorizationToken == personal.authorizationToken)
        #expect(personal.managedEngramDirectorySession === session)
        #expect(group.managedEngramDirectorySession === session)
    }

    @Test func equalCredentialTextDoesNotMergeTwoActualSessionCacheIdentities() throws {
        let a = try ManagedEngramDirectorySession(endpoint: URL(string: "https://example.invalid")!, authorizationToken: "same-token")
        let b = try ManagedEngramDirectorySession(endpoint: URL(string: "https://example.invalid")!, authorizationToken: "same-token")
        defer { a.revoke(); b.revoke() }
        let original = Lattice.Configuration(storage: .memory())
        let first = try a.configuredWSS(original), second = try b.configuredWSS(original)
        let copy = first
        #expect(first == copy)
        #expect(first != second)
        #expect(Set([first, copy, second]).count == 2)
    }

    @Test func revocationInvalidatesRetainedConfigurationCredentialWithoutMutatingOriginal() throws {
        let session = try ManagedEngramDirectorySession(endpoint: URL(string: "https://example.invalid")!, authorizationToken: "fixture-token")
        let original = Lattice.Configuration(storage: .memory())
        let retained = try session.configuredWSS(original)
        #expect(session.credentials.valid())
        session.revoke()
        let nativeValid = retained.managedEngramDirectorySession?.credentials.valid()
        #expect(nativeValid == false)
        do { _ = try session.configuredWSS(original); Issue.record("Revoked session prepared a new WSS configuration") }
        catch ManagedEngramDirectorySession.Failure.refused {}
        catch { Issue.record("Unexpected revocation stage: \(error)") }
        #expect(original.wssEndpoint == nil)
    }
}
