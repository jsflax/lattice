import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOSSL
import WebSocketKit
@testable import Lattice
@testable import LatticeServerKit

// Copied diagnostic values only. The dedicated wrapper reads these fixed-schema
// lines from the closed private log, including failures before a safe file root
// exists. No description, dynamic type name or error userInfo is serialized.
final class ConnectedFailureObservation: @unchecked Sendable {
    enum Case: String { case stockTLSAcceptsMatchingHostedCertificate, stockTLSRejectsReachableWrongHostCertificate, twoIndependentPublicReceiversRecoverOfflineEditsAcrossTwoChannels }
    enum Phase: String {
        case started, environmentMarkers, environmentRoot, environmentPrivateFiles, environmentReceiptPath
        case environmentReceiptRead, environmentReceiptDecode, environmentReceiptFields
        case applicationEnvironment, applicationCreate, applicationTLS, tlsDriver, serverStartup, serverAddress
        case tlsConnect, tlsTerminal, tlsWrongHostOracle, tlsMatchingOracle, tlsClose, applicationShutdown, successReceipt
        case directoryCreate, sourceDirectoryCreate, sourceSeed, registrations, relayConfigure
        case bootstrapConnect, bootstrapCatchup, bootstrapContext, bootstrapRetire, receiverCreate, receiverOpen
        case initialRecovery, receiverRetire, offlineEdit, recoveryReopen, heldCanonicalRead, heldBarrierOracle
        case combinedRecovery, postRecoveryWrite, cleanup, completed
    }
    enum CleanupPhase: String { case releaseHeldSend, closeReceivers, closeBootstrap, retireAuthorization, shutdownApplication, waitRetirement, removeHooks, completed }
    enum FixtureError: String { case environment, deadline, metadata, receipt, unexpectedOriginal }
    struct ErrorFact: Sendable, Equatable {
        let kind, domain: String
        let code: Int?
        let category: PlatformTransportErrorFact.Category?
        init(_ fact: PlatformTransportErrorFact) { kind = fact.kind.rawValue; domain = fact.domain.rawValue; code = fact.code; category = fact.category }
        init(_ fixture: FixtureError) { kind = fixture.rawValue; domain = "fixture"; code = nil; category = nil }
        init(_ error: any Error) {
            if let value = error as? SyncRecoveryConfigurationError {
                switch value {
                case .invalidBounds: kind = "invalidBounds"
                case .ambiguousPolicy: kind = "ambiguousPolicy"
                case .invalidPeer: kind = "invalidPeer"
                case .staleAuthorization: kind = "staleAuthorization"
                case .administrationInProgress: kind = "administrationInProgress"
                }
                domain = "recoveryConfiguration"; code = nil; category = nil
            } else {
                // A's bootstrap uses WebSocketKit on both platforms. This
                // test-only target already imports Vapor/NIO; keep those extra
                // dependencies out of the ordinary Darwin Lattice target.
                var fact = PlatformTransportErrorFact.copy(error)
                if let value = error as? NIOSSLExtraError {
                    fact = .init(kind: value == .failedToValidateHostname ? .identity : .tls, domain: .nioSSLExtra, code: nil)
                } else if let category = connectedNIOCategory(error) {
                    fact = .init(kind: .tls, domain: .nioSSL, code: nil, category: category)
                } else if let value = error as? WebSocketClient.Error {
                    switch value {
                    case .invalidResponseStatus(let response): fact = .init(kind: .protocolFailure, domain: .nioWebSocket, code: Int32(exactly: response.status.code).map(Int.init))
                    case .invalidURL, .alreadyShutdown: fact = .init(kind: .protocolFailure, domain: .nioWebSocket, code: nil)
                    }
                } else if error is ChannelError {
                    fact = .init(kind: .transport, domain: .nioChannel, code: nil)
                }
                kind = fact.kind.rawValue; domain = fact.domain.rawValue; code = fact.code; category = fact.category
            }
        }
        var json: [String: Any] { ["kind": kind, "domain": domain, "code": code.map { $0 as Any } ?? NSNull(),
                                  "category": category.map { $0.rawValue as Any } ?? NSNull()] }
    }
    private enum Scalar: Sendable { case integer(Int), boolean(Bool)
        var json: Any { switch self { case .integer(let v): return v; case .boolean(let v): return v } }
    }
    private struct State {
        var completed = false
        var phase = Phase.started
        var failure: ErrorFact?
        var cleanupPhase: CleanupPhase?
        var cleanupFailure: ErrorFact?
        var callbacks: [PlatformTransportFailureObservation] = []
        var underlyingCount = 0
        var callbackOverflow = false
        var facts: [String: Scalar] = [:]
    }
    private let name: Case
    private let state = NIOLockedValueBox(State())
    init(_ name: Case) { self.name = name }
    func phase(_ value: Phase) { state.withLockedValue { if $0.failure == nil { $0.phase = value } } }
    func failed(_ value: ErrorFact) { state.withLockedValue { if $0.failure == nil { $0.failure = value } } }
    func cleanup(_ value: CleanupPhase) { state.withLockedValue { if $0.cleanupFailure == nil { $0.cleanupPhase = value } } }
    func cleanupFailed(_ value: ErrorFact) { state.withLockedValue { if $0.cleanupFailure == nil { $0.cleanupFailure = value } } }
    func completed() { state.withLockedValue { $0.completed = true; $0.phase = .completed } }
    func callback(_ value: PlatformTransportFailureObservation) {
        state.withLockedValue { valueState in
            guard valueState.callbacks.count < 8 else { valueState.callbackOverflow = true; return }
            let count = min(8 - valueState.underlyingCount, value.underlyingErrors.count)
            valueState.callbacks.append(.init(phase: value.phase, error: value.error, trustAccepted: value.trustAccepted,
                guardOutcome: value.guardOutcome, underlyingErrors: Array(value.underlyingErrors.prefix(count)),
                underlyingTruncated: value.underlyingTruncated || count < value.underlyingErrors.count,
                underlyingCycle: value.underlyingCycle))
            valueState.underlyingCount += count
        }
    }
    func tlsFacts(opens: Int, errors: Int, systemTLS: Bool, identityFailure: Bool, listenerPublished: Bool) {
        state.withLockedValue {
            $0.facts["opens"] = .integer(max(0, min(opens, 1_000_000)))
            $0.facts["errors"] = .integer(max(0, min(errors, 1_000_000)))
            $0.facts["systemTLS"] = .boolean(systemTLS)
            $0.facts["identityFailure"] = .boolean(identityFailure)
            $0.facts["listenerPublished"] = .boolean(listenerPublished)
        }
    }
    func topology(mounts: Int, bootstrapPeers: Int, receivers: Int) {
        state.withLockedValue {
            $0.facts["mounts"] = .integer(max(0, min(mounts, 2)))
            $0.facts["bootstrapPeers"] = .integer(max(0, min(bootstrapPeers, 2)))
            $0.facts["receivers"] = .integer(max(0, min(receivers, 2)))
        }
    }
    func encoded() -> String? {
        let value = state.withLockedValue { $0 }
        let callbacks: [[String: Any]] = value.callbacks.map {
            ["phase": $0.phase.rawValue, "error": ErrorFact($0.error).json,
             "trustAccepted": $0.trustAccepted.map { $0 as Any } ?? NSNull(),
             "guardOutcome": $0.guardOutcome.map { $0.rawValue as Any } ?? NSNull(),
             "underlyingErrors": $0.underlyingErrors.map { ErrorFact($0).json },
             "underlyingTruncated": $0.underlyingTruncated, "underlyingCycle": $0.underlyingCycle]
        }
        let json: [String: Any] = ["version": 2, "name": name.rawValue, "completed": value.completed,
            "phase": value.phase.rawValue, "failure": value.failure.map { $0.json as Any } ?? NSNull(),
            "cleanupPhase": value.cleanupPhase.map { $0.rawValue as Any } ?? NSNull(),
            "cleanupFailure": value.cleanupFailure.map { $0.json as Any } ?? NSNull(),
            "callbacks": callbacks, "callbackOverflow": value.callbackOverflow, "facts": value.facts.mapValues(\.json)]
        guard let bytes = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), bytes.count <= 4_064 else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
    func emit() {
        // The constant fallback cannot turn an encoding failure into completion.
        let fallback = "{\"version\":2,\"name\":\"\(name.rawValue)\",\"completed\":false,\"phase\":\"started\",\"failure\":{\"kind\":\"other\",\"domain\":\"none\",\"code\":null,\"category\":null},\"cleanupPhase\":null,\"cleanupFailure\":null,\"callbacks\":[],\"callbackOverflow\":false,\"facts\":{}}"
        print("LATTICE_CONNECTED_FAILURE_V2 " + (encoded() ?? fallback))
    }
}

// The bootstrap is NIO on Darwin too. Classify only public pinned enum cases,
// never error-stack descriptions or an arbitrary Swift type name.
private func connectedNIOCategory(_ error: any Error) -> PlatformTransportErrorFact.Category? {
    if let value = error as? NIOSSLError {
        switch value {
        case .writeDuringTLSShutdown: return .writeDuringTLSShutdown
        case .unableToAllocateBoringSSLObject: return .unableToAllocate
        case .noSuchFilesystemObject: return .noSuchFilesystemObject
        case .failedToLoadCertificate: return .failedToLoadCertificate
        case .failedToLoadPrivateKey: return .failedToLoadPrivateKey
        case .handshakeFailed: return .handshakeFailed
        case .shutdownFailed: return .shutdownFailed
        case .cannotMatchULabel: return .cannotMatchULabel
        case .noCertificateToValidate: return .noCertificateToValidate
        case .unableToValidateCertificate: return .unableToValidateCertificate
        case .cannotFindPeerIP: return .cannotFindPeerIP
        case .readInInvalidTLSState: return .readInInvalidTLSState
        case .uncleanShutdown: return .uncleanShutdown
        }
    }
    if let value = error as? BoringSSLError {
        switch value {
        case .noError: return .noError
        case .zeroReturn: return .zeroReturn
        case .wantRead: return .wantRead
        case .wantWrite: return .wantWrite
        case .wantConnect: return .wantConnect
        case .wantAccept: return .wantAccept
        case .wantX509Lookup: return .wantX509Lookup
        case .wantCertificateVerify: return .wantCertificateVerify
        case .syscallError: return .syscallError
        case .sslError: return .sslError
        case .unknownError: return .unknownError
        case .invalidSNIName: return .invalidSNIName
        case .failedToSetALPN: return .failedToSetALPN
        }
    }
    return nil
}
