import Foundation
import Logging
import NIOConcurrencyHelpers
import Testing

private final class ConfiguredTLSLogMarker: Error, Sendable {}
private struct ConfiguredTLSLogSink: LogHandler {
    let events: NIOLockedValueBox<[LogEvent]>
    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]
    var metadataProvider: Logger.MetadataProvider?
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
    func log(event: LogEvent) { events.withLockedValue { $0.append(event) } }
}

@Suite("Configured server TLS passive log observation", .timeLimit(.minutes(1)))
@MainActor
struct ConfiguredServerTLSObservationTests {
    private func event(level: Logger.Level = .error, source: String = "Vapor",
                       file: String = "Vapor/HTTPServer.swift", line: UInt = 543,
                       message: Logger.Message = "Could not configure TLS: private error") -> LogEvent {
        .init(level: level, message: message, metadata: nil, source: source,
              file: file, function: "start(application:server:responder:configuration:on:)", line: line)
    }

    @Test func identicalEventAndAssociatedErrorReachOriginalHandler() throws {
        let sink = NIOLockedValueBox<[LogEvent]>([])
        let original = Logger(label: "fixture-original") { _ in ConfiguredTLSLogSink(events: sink) }
        let observer = ConfiguredServerTLSObservation()
        let wrapped = observer.wrapping(original, application: .bootstrap)
        let marker = ConfiguredTLSLogMarker()
        var input = event()
        input.error = marker
        input.metadata = ["private": .dictionary(["nested": "metadata"])]
        wrapped.handler.log(event: input)
        let calls = sink.withLockedValue { $0 }
        #expect(calls.count == 1)
        let actual = try #require(calls.first)
        #expect(actual.level == input.level && actual.message == input.message)
        #expect(actual.source == input.source && actual.file == input.file)
        #expect(actual.function == input.function && actual.line == input.line)
        #expect(actual.metadata == input.metadata)
        #expect((actual.error as? ConfiguredTLSLogMarker) === marker)
        #expect(observer.json["bootstrapContextCatch"] as? Int == 1)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: observer.json), as: UTF8.self)
        #expect(!json.contains("private") && !json.contains("metadata") && !json.contains("Vapor"))
        #expect(Set(observer.json.keys) == ["bootstrapContextCatch", "wrongHostContextCatch", "overflow"])
    }

    @Test func onlyExactPinnedCatchCountsAndEveryOtherEventStillForwards() {
        let sink = NIOLockedValueBox<[LogEvent]>([])
        let logger = Logger(label: "fixture") { _ in ConfiguredTLSLogSink(events: sink) }
        let observer = ConfiguredServerTLSObservation()
        let wrapped = observer.wrapping(logger, application: .bootstrap)
        let inputs = [event(level: .warning), event(source: "Application"), event(file: "Other/HTTPServer.swift"),
                      event(line: 542), event(line: 544), event(message: "Could not configure TLS"),
                      event(message: "prefix Could not configure TLS: private"), event()]
        for input in inputs { wrapped.handler.log(event: input) }
        #expect(sink.withLockedValue { $0.count } == inputs.count)
        #expect(observer.json["bootstrapContextCatch"] as? Int == 1)
        #expect(observer.json["wrongHostContextCatch"] as? Int == 0)
        #expect(observer.json["overflow"] as? Bool == false)
    }

    @Test func countsAreSeparateBoundedAndOverflowNeverSuppressesOriginalLogging() {
        let sink = NIOLockedValueBox<[LogEvent]>([])
        let original = Logger(label: "fixture") { _ in ConfiguredTLSLogSink(events: sink) }
        let observer = ConfiguredServerTLSObservation()
        let bootstrap = observer.wrapping(original, application: .bootstrap)
        let wrongHost = observer.wrapping(original, application: .wrongHost)
        for _ in 0..<33 { bootstrap.handler.log(event: event()) }
        wrongHost.handler.log(event: event())
        #expect(observer.json["bootstrapContextCatch"] as? Int == 32)
        #expect(observer.json["wrongHostContextCatch"] as? Int == 1)
        #expect(observer.json["overflow"] as? Bool == true)
        #expect(sink.withLockedValue { $0.count } == 34)
    }

    @Test func originalFilteringMetadataProviderAndLoggerValueSemanticsRemain() throws {
        let sink = NIOLockedValueBox<[LogEvent]>([])
        let providerCalls = NIOLockedValueBox(0)
        let provider = Logger.MetadataProvider {
            providerCalls.withLockedValue { $0 += 1 }
            return ["provider": "preserved"]
        }
        var original = Logger(label: "fixture") { _ in
            ConfiguredTLSLogSink(events: sink, metadataProvider: provider)
        }
        original[metadataKey: "original"] = "unchanged"
        let observer = ConfiguredServerTLSObservation()
        var wrapped = observer.wrapping(original, application: .bootstrap)
        wrapped.logLevel = .critical
        wrapped[metadataKey: "original"] = "wrapped"
        #expect(original.logLevel == .trace)
        #expect(original[metadataKey: "original"] == "unchanged")
        #expect(wrapped.label == original.label)
        #expect(wrapped.metadataProvider?.get()["provider"] == "preserved")
        #expect(providerCalls.withLockedValue { $0 } == 1)
        wrapped.error("Could not configure TLS: filtered", source: "Vapor", file: "Vapor/HTTPServer.swift", line: 543)
        #expect(sink.withLockedValue { $0.isEmpty })
        #expect(observer.json["bootstrapContextCatch"] as? Int == 0)
        wrapped.logLevel = .trace
        wrapped.error("Could not configure TLS: forwarded", source: "Vapor", file: "Vapor/HTTPServer.swift", line: 543)
        #expect(sink.withLockedValue { $0.count } == 1)
        #expect(observer.json["bootstrapContextCatch"] as? Int == 1)
        // The wrapper does not evaluate the provider when observing or forwarding.
        #expect(providerCalls.withLockedValue { $0 } == 1)
    }

    @Test func serverObservationStillFitsUnchangedReceiptLimit() throws {
        // An upper bound, deliberately including mutually incompatible maximum
        // fields: longest allowlisted strings, negative Int32, false (five bytes),
        // all six leaves and every larger-case scalar key at its maximum. Actual
        // valid receipts are no longer than this compact ASCII representation.
        let base: [String: Any] = ["family": "nioHTTPUpgrade", "upgrade": "writingToHandlerAfterUpgradeCompleted",
            "wrapper": "handshakeFailed", "tls": "wantCertificateVerify", "stackCount": 8,
            "stackTruncated": false, "eofDuringHandshake": false, "eofDuringAdditionalValidation": false]
        let fact: [String: Any] = ["kind": "administrationInProgress", "domain": "recoveryConfiguration",
            "code": -2_147_483_648, "category": "unableToValidateCertificate"]
        let leaf: [String: Any] = ["fact": fact, "detail": base, "errno": -2_147_483_648, "nestedConnection": false]
        var detail = base
        detail["errno"] = -2_147_483_648
        detail["connection"] = ["dnsA": leaf, "dnsAAAA": leaf, "failures": Array(repeating: leaf, count: 4),
                                "failureCount": 4, "failuresTruncated": false] as [String: Any]
        let row = Dictionary(uniqueKeysWithValues: ["clientAttempt", "clientUpgrade", "channelEntered", "channelAccepted",
                                                   "authorizationEntered", "authorizationAccepted"].map { ($0, 32) })
        let observed: [String: Any] = ["currentIndex": NSNull(), "channels": [row, row], "sourceSetupEntered": 32,
                                      "sourceSetupFinished": 32, "overflow": false]
        let facts = Dictionary(uniqueKeysWithValues: ["freshAuthorizedConnections", "retiredConnectionsDrained",
            "lateConnectedReplays", "committedOriginals", "peerVisibleRows", "actualCollectedAttempts",
            "actualChildClosesAndSchedulerJoins"].map { ($0, 1024) })
        let receipt: [String: Any] = ["version": 5, "name": "publicConfiguredWrongHostFailureRetiresStockAttempt",
            "passed": false, "phase": "bootstrapRetirement", "scalarFacts": facts, "failure": fact,
            "diagnostic": ["bootstrap": observed, "error": detail,
                "serverTLS": ["bootstrapContextCatch": 32, "wrongHostContextCatch": 32, "overflow": false]]]
        let bytes = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        #expect(bytes.count == 3913)
        #expect(bytes.count <= 4096)
    }
}
