import Foundation
import Logging
import NIOConcurrencyHelpers

// Fixture-only passive observation of the pinned Vapor cfd8f434 HTTPServer.swift
// catch at line 543. This is not an accepted-socket, TLS-success or trust proof.
// No message, error, metadata, path, application or channel is retained here.
final class ConfiguredServerTLSObservation: Sendable {
    enum ApplicationRole: Sendable { case bootstrap, wrongHost }
    private struct State: Sendable {
        var bootstrapContextCatch = 0, wrongHostContextCatch = 0, overflow = false
    }
    private let state = NIOLockedValueBox(State())

    func wrapping(_ original: Logger, application: ApplicationRole) -> Logger {
        var wrapped = original
        wrapped.handler = ForwardingHandler(original: original.handler, observation: self, application: application)
        return wrapped
    }

    private func observe(_ event: LogEvent, application: ApplicationRole) {
        // SwiftLog 1.13.1 passes #fileID/#line and derives source from that file.
        // Match only this exact compiled source site and its static prefix. The
        // already-formed message is borrowed for this check, never copied into
        // state, described as an Error, parsed, truncated or serialized.
        guard event.level == .error, event.source == "Vapor",
              event.file == "Vapor/HTTPServer.swift", event.line == 543,
              event.message.description.utf8.starts(with: "Could not configure TLS: ".utf8) else { return }
        state.withLockedValue { value in
            switch application {
            case .bootstrap:
                if value.bootstrapContextCatch < 32 { value.bootstrapContextCatch += 1 }
                else { value.overflow = true }
            case .wrongHost:
                if value.wrongHostContextCatch < 32 { value.wrongHostContextCatch += 1 }
                else { value.overflow = true }
            }
        }
    }

    var json: [String: Any] {
        let value = state.withLockedValue { $0 }
        return ["bootstrapContextCatch": value.bootstrapContextCatch,
                "wrongHostContextCatch": value.wrongHostContextCatch, "overflow": value.overflow]
    }

    private struct ForwardingHandler: LogHandler {
        var original: any LogHandler
        let observation: ConfiguredServerTLSObservation
        let application: ApplicationRole
        var logLevel: Logger.Level {
            get { original.logLevel }
            set { original.logLevel = newValue }
        }
        var metadata: Logger.Metadata {
            get { original.metadata }
            set { original.metadata = newValue }
        }
        var metadataProvider: Logger.MetadataProvider? {
            get { original.metadataProvider }
            set { original.metadataProvider = newValue }
        }
        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { original[metadataKey: key] }
            set { original[metadataKey: key] = newValue }
        }
        func log(event: LogEvent) {
            // Preserve the entire original event, including associated Error
            // identity, source location and metadata. Do not re-log through a
            // Logger (which would re-evaluate filtering or metadata providers).
            original.log(event: event)
            observation.observe(event, application: application)
        }
    }
}
