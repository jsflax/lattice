import Foundation
import Testing
@testable import Lattice
@testable import LatticeServerKit
import NIOSSL
import WebSocketKit
import NIOHTTP1

@Suite("Bounded copied connected failure observations")
struct ConnectedFailureObservationTests {
    private func record(_ value: ConnectedFailureObservation) throws -> [String: Any] {
        let encoded = try #require(value.encoded())
        #expect(encoded.utf8.count + "LATTICE_CONNECTED_FAILURE_V1 ".utf8.count + 1 <= 4_096)
        return try #require(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
    }
    @Test func unknownErrorsCannotExportDynamicDomainsMessagesOrUserInfo() throws {
        let secret = "forbidden-private-token-and-path"
        let input = NSError(domain: secret, code: 42, userInfo: [NSLocalizedDescriptionKey: secret, "payload": secret])
        let copied = PlatformTransportErrorFact.copy(input)
        #expect(copied == .init(kind: .other, domain: .none, code: nil))
        let observation = ConnectedFailureObservation(.stockTLSAcceptsMatchingHostedCertificate)
        observation.failed(.init(input))
        let encoded = try #require(observation.encoded())
        #expect(!encoded.contains(secret))
        #expect(try record(observation)["completed"] as? Bool == false)
    }
    @Test func knownDomainsRetainOnlyBoundedNumericFactsWithoutPromotingIdentity() {
        #expect(PlatformTransportErrorFact.copy(NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed))
            == .init(kind: .tls, domain: .url, code: NSURLErrorSecureConnectionFailed))
        #expect(PlatformTransportErrorFact.copy(NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse))
            == .init(kind: .protocolFailure, domain: .url, code: NSURLErrorBadServerResponse))
        #expect(PlatformTransportErrorFact.copy(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
            == .init(kind: .cancelled, domain: .url, code: NSURLErrorCancelled))
        // An OSStatus scalar outside an actual current TLS challenge is never
        // accepted as hostname evidence, even if its number looks familiar.
        #expect(PlatformTransportErrorFact.copy(NSError(domain: NSOSStatusErrorDomain, code: -67_602))
            == .init(kind: .other, domain: .osStatus, code: -67_602))
        #expect(PlatformTransportErrorFact.copy(NSError(domain: NSPOSIXErrorDomain, code: Int.max)).code == nil)
        #expect(PlatformTransportErrorFact.copy(NSError(domain: NSCocoaErrorDomain, code: 260)).kind == .fileSystem)
    }
    @Test func earlyFailureHasExplicitNullKeysAndDistinctCleanupEvidence() throws {
        let observation = ConnectedFailureObservation(.twoIndependentPublicReceiversRecoverOfflineEditsAcrossTwoChannels)
        observation.phase(.environmentRoot)
        observation.failed(.init(ConnectedFailureObservation.FixtureError.environment))
        observation.cleanup(.shutdownApplication)
        observation.cleanupFailed(.init(NSError(domain: NSPOSIXErrorDomain, code: 5)))
        observation.cleanup(.completed) // A later cleanup attempt cannot erase the first failure phase.
        observation.phase(.completed)
        observation.failed(.init(ConnectedFailureObservation.FixtureError.receipt))
        let value = try record(observation)
        #expect(Set(value.keys) == ["version", "name", "completed", "phase", "failure", "cleanupPhase", "cleanupFailure", "callbacks", "callbackOverflow", "facts"])
        #expect(value["phase"] as? String == "environmentRoot")
        #expect(value["completed"] as? Bool == false)
        let failure = try #require(value["failure"] as? [String: Any])
        #expect(failure["kind"] as? String == "environment")
        #expect(failure["code"] is NSNull)
        #expect(value["cleanupPhase"] as? String == "shutdownApplication")
        #expect((value["cleanupFailure"] as? [String: Any])?["code"] as? Int == 5)
        let fresh = try record(ConnectedFailureObservation(.stockTLSRejectsReachableWrongHostCertificate))
        #expect(fresh["failure"] is NSNull && fresh["cleanupPhase"] is NSNull && fresh["cleanupFailure"] is NSNull)
    }
    @Test func callbackStorageIsBoundedAndDoesNotOverwritePrimaryFailure() throws {
        let observation = ConnectedFailureObservation(.stockTLSRejectsReachableWrongHostCertificate)
        observation.phase(.tlsWrongHostOracle)
        observation.failed(.init(ConnectedFailureObservation.FixtureError.metadata))
        for number in 0..<32 {
            observation.callback(.init(phase: .completion, error: .init(kind: .transport, domain: .url, code: number), trustAccepted: nil))
        }
        observation.tlsFacts(opens: 0, errors: 1, systemTLS: false, identityFailure: false, listenerPublished: true)
        let value = try record(observation)
        let events = try #require(value["callbacks"] as? [[String: Any]])
        #expect(events.count == 8 && value["callbackOverflow"] as? Bool == true)
        #expect(events.allSatisfy { $0["trustAccepted"] is NSNull })
        #expect((events.last?["error"] as? [String: Any])?["code"] as? Int == 7)
        #expect(value["phase"] as? String == "tlsWrongHostOracle")
        #expect((value["failure"] as? [String: Any])?["kind"] as? String == "metadata")
    }
    @Test func recoveryConfigurationCasesHaveOnlyFinitePassiveLabels() {
        let cases: [(SyncRecoveryConfigurationError, String)] = [(.invalidBounds, "invalidBounds"), (.ambiguousPolicy, "ambiguousPolicy"),
            (.invalidPeer, "invalidPeer"), (.staleAuthorization, "staleAuthorization"), (.administrationInProgress, "administrationInProgress")]
        for (error, name) in cases {
            let value = ConnectedFailureObservation.ErrorFact(error)
            #expect(value.kind == name && value.domain == "recoveryConfiguration" && value.code == nil)
        }
    }
    @Test func actualPinnedNIOErrorsDistinguishHostnameFromProtocolAndOtherTLS() {
        let identity = ConnectedFailureObservation.ErrorFact(NIOSSLExtraError.failedToValidateHostname)
        #expect(identity.kind == "identity" && identity.domain == "nioSSLExtra" && identity.code == nil)
        let tls = ConnectedFailureObservation.ErrorFact(NIOSSLError.failedToLoadCertificate)
        #expect(tls.kind == "tls" && tls.domain == "nioSSL" && tls.code == nil)
        let response = HTTPResponseHead(version: .http1_1, status: .badRequest)
        let protocolError = ConnectedFailureObservation.ErrorFact(WebSocketClient.Error.invalidResponseStatus(response))
        #expect(protocolError.kind == "protocolFailure" && protocolError.domain == "nioWebSocket" && protocolError.code == 400)
        #if os(Linux)
        #expect(PlatformTransportErrorFact.copy(NIOSSLExtraError.failedToValidateHostname)
            == .init(kind: .identity, domain: .nioSSLExtra, code: nil))
        #endif
    }
}
