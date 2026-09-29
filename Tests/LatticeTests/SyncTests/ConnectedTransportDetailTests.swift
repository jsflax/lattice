import Foundation
import Testing
import NIOConcurrencyHelpers
import NIOSSL
@testable import Lattice

// Only copied NSError values. This helper neither creates a socket nor invokes
// a verifier; links are cleared explicitly in cycle tests.
private final class ConnectedDetailNSError: NSError, @unchecked Sendable {
    private struct State { var next: Any?; var reads = 0 }
    private let state = NIOLockedValueBox(State())
    init(domain: String = NSURLErrorDomain, code: Int = NSURLErrorSecureConnectionFailed) {
        super.init(domain: domain, code: code, userInfo: nil)
    }
    required init?(coder: NSCoder) { return nil }
    func link(_ value: Any?) { state.withLockedValue { $0.next = value } }
    var reads: Int { state.withLockedValue { $0.reads } }
    override var userInfo: [String: Any] {
        state.withLockedValue { value in
            value.reads += 1
            return value.next.map { [NSUnderlyingErrorKey: $0] } ?? [:]
        }
    }
}

struct ConnectedTransportDetailTests {
    private func copy(_ error: any Error) throws -> PlatformTransportFailureObservation {
        let result = NIOLockedValueBox<PlatformTransportFailureObservation?>(nil)
        PlatformTransportFailureObservation.report({ value in result.withLockedValue { $0 = value } }, phase: .completion, error: error)
        return try #require(result.withLockedValue { $0 })
    }
    private func record(_ observation: ConnectedFailureObservation) throws -> [String: Any] {
        let bytes = Data(try #require(observation.encoded()).utf8)
        #expect(bytes.count <= 4_064)
        #expect(bytes.count + "LATTICE_CONNECTED_FAILURE_V2 ".utf8.count + 1 <= 4_096)
        return try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    @Test func nilObserverDoesNotReadOrTraverseUserInfo() {
        let error = ConnectedDetailNSError()
        error.link(NSError(domain: NSOSStatusErrorDomain, code: -1))
        PlatformTransportFailureObservation.report(nil, phase: .completion, error: error)
        #expect(error.reads == 0)
    }

    @Test func originalFailureAndEmptyChainRemainDistinctFromTrustAuthority() throws {
        let value = try copy(NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed))
        #expect(value.error == .init(kind: .tls, domain: .url, code: NSURLErrorSecureConnectionFailed))
        #expect(value.underlyingErrors.isEmpty && !value.underlyingCycle && !value.underlyingTruncated)
        #expect(value.trustAccepted == nil && value.guardOutcome == nil)
    }

    @Test func underlyingFactsKeepOrderAndBoundedTypesWithoutPromotingHostname() throws {
        let leaf = NSError(domain: NSOSStatusErrorDomain, code: -67_602)
        let middle = NSError(domain: NSPOSIXErrorDomain, code: 54, userInfo: [NSUnderlyingErrorKey: leaf])
        let root = NSError(domain: NSURLErrorDomain, code: -1200, userInfo: [NSUnderlyingErrorKey: middle])
        let value = try copy(root)
        #expect(value.underlyingErrors == [.init(kind: .transport, domain: .posix, code: 54),
                                           .init(kind: .other, domain: .osStatus, code: -67_602)])
        #expect(value.trustAccepted == nil && !value.underlyingCycle && !value.underlyingTruncated)
    }

    @Test func fifthUnderlyingNodeIsNotCopied() throws {
        let nodes = (0..<7).map { ConnectedDetailNSError(domain: NSPOSIXErrorDomain, code: $0) }
        for index in 0..<6 { nodes[index].link(nodes[index + 1]) }
        let value = try copy(nodes[0])
        #expect(value.underlyingErrors.map(\.code) == [1, 2, 3, 4])
        #expect(value.underlyingTruncated && !value.underlyingCycle)
        #expect(nodes[5].reads == 0 && nodes[6].reads == 0)
        #expect(value.error.code == 0)
    }

    @Test func rootAndInnerCyclesStopBeforeRepeatingIdentity() throws {
        let root = ConnectedDetailNSError(), inner = ConnectedDetailNSError(domain: NSPOSIXErrorDomain, code: 5)
        defer { root.link(nil); inner.link(nil) }
        root.link(root)
        let selfCycle = try copy(root)
        #expect(selfCycle.underlyingErrors.isEmpty && selfCycle.underlyingCycle && !selfCycle.underlyingTruncated)
        root.link(inner); inner.link(root)
        let backEdge = try copy(root)
        #expect(backEdge.underlyingErrors.count == 1 && backEdge.underlyingCycle && !backEdge.underlyingTruncated)
        inner.link(inner)
        let innerCycle = try copy(root)
        #expect(innerCycle.underlyingErrors.count == 1 && innerCycle.underlyingCycle)
    }

    @Test func unknownUnderlyingValuesNeverExportPrivateText() throws {
        let secret = "must-not-export-private-url-key-token-or-type"
        let unknown = NSError(domain: secret, code: 17, userInfo: [NSLocalizedDescriptionKey: secret])
        let tooLarge = NSError(domain: NSOSStatusErrorDomain, code: Int.max, userInfo: [NSUnderlyingErrorKey: unknown])
        let root = ConnectedDetailNSError(); root.link(tooLarge)
        let observation = ConnectedFailureObservation(.stockTLSAcceptsMatchingHostedCertificate)
        let copied = try copy(root); observation.callback(copied)
        #expect(copied.underlyingErrors == [.init(kind: .other, domain: .osStatus, code: nil), .init(kind: .other, domain: .none, code: nil)])
        let encoded = try #require(observation.encoded())
        #expect(!encoded.contains(secret))
        root.link(secret)
        let unsupported = try copy(root)
        #expect(unsupported.underlyingErrors.isEmpty && unsupported.underlyingTruncated && !unsupported.underlyingCycle)
    }

    @Test func challengeGuardFactsNeverSynthesizeVerification() throws {
        let observation = ConnectedFailureObservation(.stockTLSRejectsReachableWrongHostCertificate)
        for outcome in PlatformTransportFailureObservation.GuardOutcome.allCases {
            let value = PlatformTransportFailureObservation.rejectedChallenge(outcome)
            #expect(value.error.kind == .none && value.trustAccepted == nil && value.underlyingErrors.isEmpty)
            observation.callback(value)
        }
        let value = try record(observation)
        #expect(value["version"] as? Int == 2)
        let callbacks = try #require(value["callbacks"] as? [[String: Any]])
        #expect(callbacks.count == 5)
        for item in callbacks {
            #expect(Set(item.keys) == ["phase", "error", "trustAccepted", "guardOutcome", "underlyingErrors", "underlyingTruncated", "underlyingCycle"])
            #expect(item["trustAccepted"] is NSNull)
            let error = try #require(item["error"] as? [String: Any])
            #expect(Set(error.keys) == ["kind", "domain", "code", "category"])
            #expect(error["code"] is NSNull && error["category"] is NSNull)
        }
    }

    @Test func actualPinnedNIOTypesYieldOnlyClosedCategories() {
        let values: [(any Error, PlatformTransportErrorFact.Category)] = [
            (NIOSSLError.failedToLoadCertificate, .failedToLoadCertificate),
            (NIOSSLError.handshakeFailed(.sslError([.eofDuringHandshake])), .handshakeFailed),
            (NIOSSLError.uncleanShutdown, .uncleanShutdown),
            (BoringSSLError.sslError([.eofDuringHandshake]), .sslError),
            (BoringSSLError.unknownError([]), .unknownError),
            (BoringSSLError.wantCertificateVerify, .wantCertificateVerify),
            (BoringSSLError.failedToSetALPN([]), .failedToSetALPN)]
        for (error, category) in values {
            let fact = ConnectedFailureObservation.ErrorFact(error)
            #expect(fact.kind == "tls" && fact.domain == "nioSSL" && fact.code == nil && fact.category == category)
            #if os(Linux)
            #expect(PlatformTransportErrorFact.copy(error).category == category)
            #endif
        }
    }

    @Test func aggregateNodeBudgetAndWorstCaseReceiptRemainWithinOriginalCaps() throws {
        let observation = ConnectedFailureObservation(.twoIndependentPublicReceiversRecoverOfflineEditsAcrossTwoChannels)
        // Deliberately combines maximal copied fields, even combinations the
        // real mapper never emits, to bound serializer overhead conservatively.
        let error = PlatformTransportErrorFact(kind: .protocolFailure, domain: .nioWebSocket, code: Int(Int32.min), category: .unableToValidateCertificate)
        observation.phase(.environmentReceiptFields)
        observation.failed(.init(error)); observation.cleanup(.retireAuthorization); observation.cleanupFailed(.init(error))
        observation.tlsFacts(opens: 1_000_000, errors: 1_000_000, systemTLS: false, identityFailure: false, listenerPublished: false)
        observation.topology(mounts: 2, bootstrapPeers: 2, receivers: 2)
        for _ in 0..<9 {
            observation.callback(.init(phase: .trustEvaluation, error: error, trustAccepted: false, guardOutcome: .staleTaskOrSession,
                underlyingErrors: Array(repeating: error, count: 4), underlyingTruncated: false, underlyingCycle: false))
        }
        let value = try record(observation), callbacks = try #require(value["callbacks"] as? [[String: Any]])
        #expect(value["completed"] as? Bool == false && value["callbackOverflow"] as? Bool == true)
        #expect(callbacks.count == 8)
        #expect(callbacks.reduce(0) { $0 + (($1["underlyingErrors"] as? [[String: Any]])?.count ?? 0) } == 8)
        #expect(callbacks.prefix(2).allSatisfy { $0["underlyingTruncated"] as? Bool == false })
        #expect(callbacks.dropFirst(2).allSatisfy { $0["underlyingTruncated"] as? Bool == true })
    }
}
