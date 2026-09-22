import Foundation
import Testing
import Vapor
import NIOSSL
import CxxStdlib
import LatticeServerExportTestSupport
@testable import Lattice

#if os(Linux)
private typealias HostedTLSClient = NIOWebsocketClient
#else
private typealias HostedTLSClient = Lattice.WebsocketClient
#endif
private enum HostedTLSError: Error { case configuration, timeout, missingPort, unexpectedObservation }
private struct HostedTLSConfiguration: Decodable {
    let nonce: String
    let trustedCertificate: String
    let trustedKey: String
    let unknownCertificate: String
    let unknownKey: String
    let trustedCertificateSHA256: String
    let unknownCertificateSHA256: String
}
private final class HostedTLSServer: @unchecked Sendable {
    let app: Application
    private let counts = UnfairLock(initialState: (opens: 0, redirects: 0))
    var opens: Int { counts.withLockUnchecked { $0.opens } }
    var redirects: Int { counts.withLockUnchecked { $0.redirects } }
    var port: Int {
        get throws {
            guard let port = app.http.server.shared.localAddress?.port else { throw HostedTLSError.missingPort }
            return port
        }
    }
    init(certificate: String?, key: String?) async throws {
        var serverTLS: TLSConfiguration?
        if let certificate, let key {
            let chain = try NIOSSLCertificate.fromPEMFile(certificate).map { NIOSSLCertificateSource.certificate($0) }
            let privateKey = try NIOSSLPrivateKey(file: key, format: .pem)
            var tls = TLSConfiguration.makeServerConfiguration(certificateChain: chain, privateKey: .privateKey(privateKey))
            tls.applicationProtocols = ["http/1.1"]
            serverTLS = tls
        }
        var environment = try Environment.detect(); environment.arguments = ["vapor"]
        app = try await Application.make(environment)
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0
        app.http.server.configuration.supportVersions = [.one]
        app.http.server.configuration.tlsConfiguration = serverTLS
        app.webSocket("tls") { [weak self] _, _ in self?.counts.withLockUnchecked { $0.opens += 1 } }
        app.get("redirect") { [weak self] _ -> Response in
            guard let self else { throw HostedTLSError.configuration }
            self.counts.withLockUnchecked { $0.redirects += 1 }
            return Response(status: .found, headers: ["location": "wss://localhost:\(try self.port)/tls"])
        }
        do { try await app.startup() }
        catch { try? await app.asyncShutdown(); throw error }
    }
    func stop() async throws { try await app.asyncShutdown() }
}

@Suite(.serialized) struct HostedSystemTLSQualificationTests {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw HostedTLSError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func require(_ value: Bool) throws { guard value else { throw HostedTLSError.unexpectedObservation } }
    private func receipt(_ caseID: String, _ phase: String, _ nonce: String, _ fields: [String: Any] = [:]) throws {
        var record = fields
        record["case"] = caseID; record["phase"] = phase; record["nonce"] = nonce
        #if os(Linux)
        record["adapter"] = "stock-NIO-system-roots"
        #else
        record["adapter"] = "stock-URLSession-system-trust"
        #endif
        let bytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        guard bytes.count <= 16384, let text = String(data: bytes, encoding: .utf8) else { throw HostedTLSError.configuration }
        print("LATTICE_HOSTED_TLS_CASE " + text)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LATTICE_SYSTEM_TLS_QUALIFICATION"] == "1"))
    func hostedSystemTrustMatrix() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["GITHUB_ACTIONS"] == "true", env["RUNNER_ENVIRONMENT"] == "github-hosted",
              let path = env["LATTICE_SYSTEM_TLS_CONFIG"], let nonce = env["LATTICE_SYSTEM_TLS_NONCE"] else { throw HostedTLSError.configuration }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue >= 0, size.intValue <= 16384 else { throw HostedTLSError.configuration }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 16385) ?? Data()
        guard data.count <= 16384 else { throw HostedTLSError.configuration }
        let config = try JSONDecoder().decode(HostedTLSConfiguration.self, from: data)
        try require(config.nonce == nonce)
        let cases = ["plain_ws_untrusted", "trusted_wss_open_close", "trusted_wss_reconnect",
                     "hostname_mismatch", "independent_unknown_ca", "redirect_disqualified"]
        for caseID in cases {
            try receipt(caseID, "started", nonce)
            let plain = caseID == "plain_ws_untrusted", unknown = caseID == "independent_unknown_ca"
            let server = try await HostedTLSServer(certificate: plain ? nil : (unknown ? config.unknownCertificate : config.trustedCertificate),
                                                   key: plain ? nil : (unknown ? config.unknownKey : config.trustedKey))
            let client = HostedTLSClient()
            guard let transport = client.createCxxClient() else {
                try await server.stop(); throw HostedTLSError.configuration
            }
            var driver = lattice.platform_tls_test_driver(transport)
            do {
                let port = try server.port
                let host = caseID == "hostname_mismatch" || plain ? "127.0.0.1" : "localhost"
                let route = caseID == "redirect_disqualified" ? "redirect" : "tls"
                let url = "\(plain ? "ws" : "wss")://\(host):\(port)/\(route)"
                driver.connect(std.string(url))
                if caseID == "hostname_mismatch" || unknown {
                    try await wait { driver.errors() > 0 }
                    try require(driver.opens() == 0 && !driver.system_tls() && server.opens == 0)
                } else if caseID == "redirect_disqualified" {
                    try await wait { server.redirects == 1 && (driver.errors() > 0 || driver.opens() > 0) }
                    try require(!driver.system_tls())
                } else {
                    try await wait { driver.opens() == 1 && server.opens == 1 || driver.errors() > 0 }
                    try require(driver.opens() == 1 && driver.errors() == 0 && server.opens == 1)
                    try require(driver.system_tls() == !plain)
                    if caseID == "trusted_wss_reconnect" {
                        driver.disconnect(); try require(!driver.system_tls())
                        driver.connect(std.string(url))
                        try await wait { driver.opens() == 2 && server.opens == 2 || driver.errors() > 0 }
                        try require(driver.opens() == 2 && driver.errors() == 0 && server.opens == 2 && driver.system_tls())
                    }
                }
                let opens = driver.opens(), errors = driver.errors(), serverOpens = server.opens, redirects = server.redirects
                let proofBeforeClose = driver.system_tls()
                driver.disconnect(); try require(!driver.system_tls())
                driver.close(); try require(!driver.system_tls())
                try await server.stop()
                try require(!driver.system_tls() && driver.opens() == opens)
                try receipt(caseID, "completed", nonce, ["url": url, "port": port, "opens": opens, "errors": errors,
                    "serverOpens": serverOpens, "redirects": redirects, "proofBeforeClose": proofBeforeClose,
                    "proofAfterClose": driver.system_tls(), "serverShutdown": true,
                    "certificateSHA256": plain ? "none" : (unknown ? config.unknownCertificateSHA256 : config.trustedCertificateSHA256)])
            } catch {
                driver.close(); try? await server.stop(); throw error
            }
        }
    }
}
