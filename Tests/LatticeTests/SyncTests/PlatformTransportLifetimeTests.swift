import Foundation
import Testing
import Vapor
import CxxStdlib
import NIOConcurrencyHelpers
import LatticeServerExportTestSupport
@testable import Lattice

#if os(Linux)
private typealias ActualPlatformClient = NIOWebsocketClient
#else
private typealias ActualPlatformClient = Lattice.WebsocketClient
#endif

private enum PlatformFixtureError: Error { case timeout, missingPort }

// The driver owns the actual SDK factory's native pointer. No test callbacks
// replace URLSession/NIO, and no recovery/session authority is fabricated.
private final class PlatformFixtureDriver: @unchecked Sendable {
    var native: lattice.platform_transport_test_driver
    weak var client: ActualPlatformClient?
    init() throws {
        let client = ActualPlatformClient()
        self.client = client
        let pointer = try #require(client.createCxxClient())
        native = lattice.platform_transport_test_driver(pointer)
    }
    func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw PlatformFixtureError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func close() { native.close() }
    deinit { native.close() }
}

@Suite(.serialized)
struct PlatformTransportLifetimeTests {
    @Test func nativeDestructionReleasesActualPlatformOwnerWithoutDialing() async throws {
        let driver = try PlatformFixtureDriver()
        #expect(driver.client != nil)
        driver.close()
        try await driver.wait { driver.client == nil }
        #expect(driver.native.opens() == 0)
        #expect(driver.native.messages() == 0)
        #expect(driver.native.errors() == 0)
    }

    @Test func actualSocketSurvivesExplicitDisconnectAndReconnect() async throws {
        var environment = try Environment.detect()
        environment.arguments = ["vapor"]
        let app = try await Application.make(environment)
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0
        app.webSocket("platform-echo") { _, socket in
            socket.onText { socket, text in socket.send(text) }
        }
        var retainedDriver: PlatformFixtureDriver?
        do {
            let driver = try PlatformFixtureDriver()
            retainedDriver = driver
            try await app.startup()
            guard let port = app.http.server.shared.localAddress?.port else { throw PlatformFixtureError.missingPort }
            let url = std.string("ws://127.0.0.1:\(port)/platform-echo")
            driver.native.connect(url)
            try await driver.wait { driver.native.opens() == 1 }
            driver.native.send_text(std.string("first-attempt"))
            try await driver.wait { driver.native.messages() == 1 }
            #expect(String(driver.native.last_text()) == "first-attempt")
            driver.native.disconnect()
            driver.native.connect(url)
            try await driver.wait { driver.native.opens() == 2 }
            driver.native.send_text(std.string("replacement-attempt"))
            try await driver.wait { driver.native.messages() == 2 }
            #expect(String(driver.native.last_text()) == "replacement-attempt")
            // Exercise one more actual generation; cancellation of old tasks
            // must not close/error or deliver into this current connection.
            driver.native.disconnect()
            driver.native.connect(url)
            try await driver.wait { driver.native.opens() == 3 }
            driver.native.send_text(std.string("third-attempt"))
            try await driver.wait { driver.native.messages() == 3 }
            #expect(String(driver.native.last_text()) == "third-attempt")
            #expect(driver.native.errors() == 0)
            #expect(driver.native.closes() == 0)
            #expect(driver.native.oversized() == 0)
            driver.close()
            try await driver.wait { driver.client == nil }
            try await app.asyncShutdown()
        } catch {
            retainedDriver?.close()
            try? await app.asyncShutdown()
            throw error
        }
    }
    @Test func actualConfiguredSocketCloseReportsUnacknowledgedWorkAndStillTearsDown() async throws {
        var environment = try Environment.detect()
        environment.arguments = ["vapor"]
        let app = try await Application.make(environment)
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0
        let frames = NIOLockedValueBox(0)
        let closes = NIOLockedValueBox(0)
        app.webSocket("close-without-ack") { _, socket in
            // Deliberately receive without ACKing. A local close must not
            // convert this real physical send into delivered/settled success.
            socket.onBinary { _, bytes in
                if bytes.readableBytes > 0 { frames.withLockedValue { $0 += 1 } }
            }
            socket.onText { _, text in
                if !text.isEmpty { frames.withLockedValue { $0 += 1 } }
            }
            socket.onClose.whenComplete { _ in closes.withLockedValue { $0 += 1 } }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var retained: Lattice?
        do {
            try await app.startup()
            let port = try #require(app.http.server.shared.localAddress?.port)
            let client = try Lattice(Person.self, configuration: .init(fileURL: directory.appendingPathComponent("close.sqlite"),
                authorizationToken: "close-fixture", wssEndpoint: URL(string: "ws://127.0.0.1:\(port)/close-without-ack")))
            retained = client
            let row = Person(); row.name = "unacknowledged"; row.age = 1
            try client.add(row)
            let sentDeadline = ContinuousClock.now.advanced(by: .seconds(10))
            while frames.withLockedValue({ $0 }) == 0 {
                guard ContinuousClock.now < sentDeadline else { throw PlatformFixtureError.timeout }
                try await Task.sleep(for: .milliseconds(10))
            }
            let result = client.closeChecked()
            #expect(result.sync == .deadlinePending)
            #expect(result.cleanupComplete)
            #expect(!result.failed)
            #expect(client.objects(Person.self).count == 0)
            client.close()
            #expect(client.lastCloseResult == result)
            let closeDeadline = ContinuousClock.now.advanced(by: .seconds(10))
            while closes.withLockedValue({ $0 }) == 0 {
                guard ContinuousClock.now < closeDeadline else { throw PlatformFixtureError.timeout }
                try await Task.sleep(for: .milliseconds(10))
            }
            retained = nil
            let reopened = try Lattice(Person.self, configuration: .init(fileURL: directory.appendingPathComponent("close.sqlite")))
            #expect(reopened.objects(Person.self).count == 1)
            reopened.close()
            try await app.asyncShutdown()
        } catch {
            retained?.close()
            try? await app.asyncShutdown()
            throw error
        }
    }

}
