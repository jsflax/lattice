import Foundation
import Testing
import LatticeSwiftCppBridge
@_spi(Installation) @testable import Lattice

@Model private final class ManagedWSSUnenrolledValue {
    var value: Int = 83
}

// Real constructor/refusal boundaries. These cannot qualify positive managed
// enrollment, TLS, or joined resources; that requires the fixed paired child.
@Suite("Managed WSS owner admission", .serialized)
struct ManagedEngramWSSOwnerTests {
    @Test func preparedConfigurationCannotOpenOrReplaceAnUnenrolledApplication() throws {
        let original = Lattice.Configuration(storage: .memory())
        let application = try Lattice(ManagedWSSUnenrolledValue.self, configuration: original)
        defer { application.close() }
        try application.add(ManagedWSSUnenrolledValue())
        let session = try ManagedEngramDirectorySession(endpoint: URL(string: "https://127.0.0.1:1")!, authorizationToken: "fixture-token")
        defer { session.revoke() }
        let prepared = try session.configuredWSS(original)
        do {
            let unexpected = try Lattice(ManagedWSSUnenrolledValue.self, configuration: prepared)
            unexpected.close()
            Issue.record("Prepared credentials bypassed actual enrolled route admission")
        } catch {}
        #expect(original.wssEndpoint == nil)
        #expect(application.objects(ManagedWSSUnenrolledValue.self).first?.value == 83)
        #expect(!application.isSyncConnected)
    }

    @Test func defaultAndCopiedRouteCannotStartAChildWithRealCredentialObject() throws {
        let session = try ManagedEngramDirectorySession(endpoint: URL(string: "https://127.0.0.1:1")!, authorizationToken: "fixture-token")
        defer { session.revoke() }
        let route = lattice.swift_managed_product_route()
        let copy = route
        let first = route.start_wss(session.credentials, std.string("fixture-token"))
        let second = copy.start_wss(session.credentials, std.string("fixture-token"))
        let validFirst = first.valid(), validSecond = second.valid()
        #expect(!validFirst && !validSecond)
        first.stop(); second.stop()
        let firstResult = first.close(), secondResult = second.close()
        let firstComplete = firstResult.cleanupComplete(), secondComplete = secondResult.cleanupComplete()
        #expect(!firstComplete && !secondComplete)
        #expect(!first.settled() && !second.settled())
    }

    @Test func actualClosedOwnersDoNotIssueAReplacementOrTouchSiblingRows() async throws {
        let hub = try Lattice(ManagedWSSUnenrolledValue.self, configuration: .init(storage: .memory()))
        let spoke = try Lattice(ManagedWSSUnenrolledValue.self, configuration: .init(storage: .memory()))
        defer { spoke.close(); hub.close() }
        try spoke.add(ManagedWSSUnenrolledValue())
        let closed = hub.closeChecked()
        #expect(closed.cleanupComplete)
        let session = try ManagedEngramDirectorySession(endpoint: URL(string: "https://127.0.0.1:1")!, authorizationToken: "fixture-token")
        defer { session.revoke() }
        do {
            let route = try await session.authorize(hub: hub, spoke: spoke, direction: .personalToHub)
            route.revoke()
            Issue.record("Closed application issued a route")
        } catch ManagedEngramDirectorySession.Failure.refused {
        } catch { Issue.record("Unexpected refusal stage: \(error)") }
        #expect(spoke.objects(ManagedWSSUnenrolledValue.self).first?.value == 83)
        #expect(!spoke.isSyncConnected)
    }
}
