import Foundation
import Testing
import LatticeSwiftCppBridge
@_spi(Installation) @testable import Lattice

@Model private final class ManagedDirectoryUnenrolledProbe {
    var value: Int = 47
}

// These cases exercise the real early refusal path and preserve actual local
// rows. They are not positive authenticated membership/enrollment proof. The
// positive hosted case must run the real managed parent/child entry and HTTPS
// directory path; no fake profile, response callback or URLProtocol is used.
@Suite("Managed directory admission", .serialized)
struct ManagedEngramDirectoryAdmissionTests {
    private func owner() throws -> Lattice {
        let owner = try Lattice(ManagedDirectoryUnenrolledProbe.self,
                               configuration: .init(storage: .memory()))
        try owner.add(ManagedDirectoryUnenrolledProbe())
        return owner
    }
    private func session() throws -> ManagedEngramDirectorySession {
        // No service is supplied. Native admission must fail before transport
        // allocation; any accidental HTTP attempt produces the wrong error.
        try ManagedEngramDirectorySession(endpoint: URL(string: "https://127.0.0.1:1")!,
                                          authorizationToken: "fixture-not-an-authentication-grant")
    }
    private func refused(_ session: ManagedEngramDirectorySession, hub: Lattice, spoke: Lattice,
                         direction: ManagedEngramDirectorySession.Direction, group: UUID? = nil) async {
        do {
            let route = try await session.authorize(hub: hub, spoke: spoke, direction: direction, group: group)
            route.revoke()
            Issue.record("Unenrolled owners unexpectedly issued a product route")
        } catch ManagedEngramDirectorySession.Failure.refused {
            // Exact native/profile admission refusal, not a network failure.
        } catch {
            Issue.record("Unexpected refusal stage: \(error)")
        }
    }

    @Test func actualUnenrolledOwnersRefusePersonalDirectionsAndKeepRows() async throws {
        let hub = try owner(), spoke = try owner(), auth = try session()
        defer { auth.revoke(); spoke.close(); hub.close() }
        await refused(auth, hub: hub, spoke: spoke, direction: .hubToPersonal)
        await refused(auth, hub: hub, spoke: spoke, direction: .personalToHub)
        #expect(hub.objects(ManagedDirectoryUnenrolledProbe.self).first?.value == 47)
        #expect(spoke.objects(ManagedDirectoryUnenrolledProbe.self).first?.value == 47)
    }

    @Test func actualUnenrolledOwnersAndSelectedGroupCannotIssueMembership() async throws {
        let hub = try owner(), spoke = try owner(), auth = try session()
        defer { auth.revoke(); spoke.close(); hub.close() }
        let selected = UUID()
        await refused(auth, hub: hub, spoke: spoke, direction: .hubToGroup, group: selected)
        await refused(auth, hub: hub, spoke: spoke, direction: .groupToHub, group: selected)
        #expect(hub.objects(ManagedDirectoryUnenrolledProbe.self).first?.value == 47)
        #expect(spoke.objects(ManagedDirectoryUnenrolledProbe.self).first?.value == 47)
    }

    @Test func sameOwnerCannotSubstituteForRetainedDistinctPair() async throws {
        let hub = try owner(), auth = try session()
        defer { auth.revoke(); hub.close() }
        await refused(auth, hub: hub, spoke: hub, direction: .hubToPersonal)
        #expect(hub.objects(ManagedDirectoryUnenrolledProbe.self).first?.value == 47)
    }

    @Test func revokedSessionRefusesBeforePairOrTransportAndCannotRevive() async throws {
        let hub = try owner(), spoke = try owner(), auth = try session()
        defer { spoke.close(); hub.close() }
        auth.revoke(); auth.revoke()
        do {
            let route = try await auth.authorize(hub: hub, spoke: spoke, direction: .hubToPersonal)
            route.revoke(); Issue.record("Revoked credential session issued a route")
        } catch ManagedEngramDirectorySession.Failure.cancelled {
        } catch { Issue.record("Unexpected revoked-session result: \(error)") }
        #expect(hub.objects(ManagedDirectoryUnenrolledProbe.self).first?.value == 47)
        #expect(spoke.objects(ManagedDirectoryUnenrolledProbe.self).first?.value == 47)
    }

    @Test func endpointAndHeaderInputsRefuseBeforeAnyOwnerAdmission() {
        for endpoint in ["http://127.0.0.1", "https://user:password@localhost", "https://localhost?authority=other", "https://localhost/#other", "https://localhost:0"] {
            do {
                let auth = try ManagedEngramDirectorySession(endpoint: URL(string: endpoint)!, authorizationToken: "fixture")
                auth.revoke(); Issue.record("Invalid configured endpoint was accepted")
            } catch ManagedEngramDirectorySession.Failure.endpoint {
            } catch { Issue.record("Unexpected endpoint validation result: \(error)") }
        }
        for token in ["", "first\r\nAuthorization: second", String(repeating: "x", count: 16_385)] {
            do {
                let auth = try ManagedEngramDirectorySession(endpoint: URL(string: "https://localhost")!, authorizationToken: token)
                auth.revoke(); Issue.record("Invalid authorization header was accepted")
            } catch ManagedEngramDirectorySession.Failure.endpoint {
            } catch { Issue.record("Unexpected token validation result: \(error)") }
        }
    }

    @Test func defaultImportedValuesAndCopiedCredentialsDoNotManufactureReceipt() {
        let request = lattice.swift_managed_product_request()
        let route = lattice.swift_managed_product_route()
        let credential = lattice.swift_managed_product_credentials()
        #expect(!credential.valid())
        #expect(!request.valid())
        #expect(request.transportCookie() == 0)
        let published = request.publish()
        #expect(!published.current())
        #expect(!route.current())
        let principal = String(route.principal())
        #expect(principal.isEmpty)
        let copy = credential
        copy.revoke(); request.cancel()
        #expect(!credential.valid())
        #expect(!copy.valid())
    }
}
