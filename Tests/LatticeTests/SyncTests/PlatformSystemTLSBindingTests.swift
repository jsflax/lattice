import Foundation
import Testing
import Vapor
import CxxStdlib
import LatticeServerExportTestSupport
@testable import Lattice

#if os(Linux)
private typealias TLSBindingPlatformClient = NIOWebsocketClient
#else
private typealias TLSBindingPlatformClient = Lattice.WebsocketClient
#endif
private enum TLSBindingFixtureError: Error { case timeout, missingPort }
@Suite(.serialized) struct PlatformSystemTLSBindingTests {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TLSBindingFixtureError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @Test func actualPlainSocketOpenNeverMeansSystemTLS() async throws {
        var environment = try Environment.detect(); environment.arguments = ["vapor"]
        let app = try await Application.make(environment)
        app.http.server.configuration.hostname = "127.0.0.1"; app.http.server.configuration.port = 0
        app.webSocket("source-binding") { _, _ in }
        let client = TLSBindingPlatformClient()
        var driver = lattice.platform_tls_test_driver(try #require(client.createCxxClient()))
        do {
            try await app.startup()
            guard let port = app.http.server.shared.localAddress?.port else { throw TLSBindingFixtureError.missingPort }
            driver.connect(std.string("ws://127.0.0.1:\(port)/source-binding"))
            try await wait { driver.opens() == 1 }
            #expect(!driver.system_tls())
            driver.disconnect(); #expect(!driver.system_tls())
            driver.close(); #expect(!driver.system_tls())
            try await app.asyncShutdown()
        } catch { driver.close(); try? await app.asyncShutdown(); throw error }
    }
    // This is a real system-roots/hostname check on the actual platform adapter,
    // not a mocked trust success. Hosted qualification must explicitly supply
    // an authorized WSS echo endpoint; absence does not count as TLS acceptance.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LATTICE_SYSTEM_TLS_TEST_WSS"] != nil))
    func actualSystemVerifiedSocketIsFencedByDisconnectAndClose() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["LATTICE_SYSTEM_TLS_TEST_WSS"])
        #expect(url.hasPrefix("wss://"))
        let client = TLSBindingPlatformClient()
        var driver = lattice.platform_tls_test_driver(try #require(client.createCxxClient()))
        defer { driver.close() }
        driver.connect(std.string(url))
        try await wait { driver.opens() == 1 || driver.errors() > 0 }
        #expect(driver.errors() == 0)
        #expect(driver.system_tls())
        driver.disconnect(); #expect(!driver.system_tls())
        driver.connect(std.string(url))
        try await wait { driver.opens() == 2 || driver.errors() > 0 }
        #expect(driver.errors() == 0)
        #expect(driver.system_tls())
        driver.close(); #expect(!driver.system_tls())
    }
}
