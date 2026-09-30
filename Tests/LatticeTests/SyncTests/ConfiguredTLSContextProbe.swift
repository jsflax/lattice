import Foundation
import NIOSSL
import Vapor

// Invoked only after the original bootstrap has already failed and its actual
// Vapor TLS-context catch was observed. This constructs a separate diagnostic
// context; it is not the accepted socket's context or evidence of a handshake.
struct ConfiguredTLSContextProbe {
    private let result: String
    private let failure: ConnectedFailureObservation.ErrorFact?
    private let detail: ConfiguredBootstrapErrorDetail?

    init(configuration: HTTPServer.Configuration) {
        guard var tls = configuration.tlsConfiguration else {
            result = "notConfigured"; failure = nil; detail = nil; return
        }
        // Match pinned Vapor HTTPServer.swift's child initializer exactly.
        // Preserve roots, verification, keys, ciphers and all other options.
        if configuration.supportVersions.contains(.two) { tls.applicationProtocols.append("h2") }
        if configuration.supportVersions.contains(.one) { tls.applicationProtocols.append("http/1.1") }
        do {
            let context = try NIOSSLContext(configuration: tls)
            withExtendedLifetime(context) {}
            result = "constructed"; failure = nil; detail = nil
        } catch {
            result = "threw"
            failure = .init(error); detail = .init(error)
        }
    }

    var json: [String: Any] {
        ["observation": "separatePostFailureConstruction", "result": result,
         "failure": failure.map { $0.json as Any } ?? NSNull(),
         "error": detail.map { $0.json as Any } ?? NSNull()]
    }
}
