import Foundation
import NIOConcurrencyHelpers
import NIOHTTP1
import NIOSSL

// Configured qualification only. Never retain a request, socket, peer, error,
// certificate, bearer, URL or error description. No observation grants success.
final class ConfiguredBootstrapObservation: Sendable {
    enum Event { case clientAttempt, clientUpgrade, channelEntered, channelAccepted, authorizationEntered, authorizationAccepted }
    private struct Counts: Sendable {
        var clientAttempt = 0, clientUpgrade = 0, channelEntered = 0, channelAccepted = 0
        var authorizationEntered = 0, authorizationAccepted = 0
        var json: [String: Int] {
            ["clientAttempt": clientAttempt, "clientUpgrade": clientUpgrade, "channelEntered": channelEntered,
             "channelAccepted": channelAccepted, "authorizationEntered": authorizationEntered,
             "authorizationAccepted": authorizationAccepted]
        }
    }
    private struct State: Sendable {
        var index: Int?, rows = [Counts(), Counts()], setupEntered = 0, setupFinished = 0, overflow = false
    }
    private let state = NIOLockedValueBox(State())
    func begin(_ index: Int) {
        state.withLockedValue { s in
            guard (0..<2).contains(index) else { s.overflow = true; return }
            s.index = index
        }
        record(.clientAttempt, index: index)
    }
    func record(_ event: Event, index: Int) {
        state.withLockedValue { s in
            guard (0..<2).contains(index) else { s.overflow = true; return }
            func increment(_ value: inout Int) {
                if value < 32 { value += 1 } else { s.overflow = true }
            }
            // Copy one fixed row to avoid overlapping access to the locked state.
            var row = s.rows[index]
            switch event {
            case .clientAttempt: increment(&row.clientAttempt)
            case .clientUpgrade: increment(&row.clientUpgrade)
            case .channelEntered: increment(&row.channelEntered)
            case .channelAccepted: increment(&row.channelAccepted)
            case .authorizationEntered: increment(&row.authorizationEntered)
            case .authorizationAccepted: increment(&row.authorizationAccepted)
            }
            s.rows[index] = row
        }
    }
    func setup(entered: Bool) {
        state.withLockedValue { s in
            if entered {
                if s.setupEntered < 32 { s.setupEntered += 1 } else { s.overflow = true }
            } else {
                if s.setupFinished < 32 { s.setupFinished += 1 } else { s.overflow = true }
            }
        }
    }
    var json: [String: Any] {
        let value = state.withLockedValue { $0 }
        return ["currentIndex": value.index.map { $0 as Any } ?? NSNull(), "channels": value.rows.map(\.json),
                "sourceSetupEntered": value.setupEntered, "sourceSetupFinished": value.setupFinished, "overflow": value.overflow]
    }
}

// Public pinned NIO case/equality observations only. Unknown types remain
// unclassified. The associated BoringSSL stack is not reflected or described.
struct ConfiguredBootstrapErrorDetail {
    enum Family: String { case unclassified, nioHTTPUpgrade, nioTLS }
    enum Upgrade: String {
        case responseProtocolNotFound, invalidHTTPOrdering, upgraderDeniedUpgrade
        case writingToHandlerDuringUpgrade, writingToHandlerAfterUpgradeCompleted, writingToHandlerAfterUpgradeFailed
        case receivedResponseBeforeRequestSent, receivedResponseAfterUpgradeCompleted, unclassified
    }
    enum Wrapper: String { case direct, handshakeFailed, shutdownFailed }
    enum TLS: String {
        case noError, zeroReturn, wantRead, wantWrite, wantConnect, wantAccept, wantX509Lookup
        case wantCertificateVerify, syscallError, sslError, unknownError, invalidSNIName, failedToSetALPN
    }
    let family: Family
    let upgrade: Upgrade?
    let wrapper: Wrapper?
    let tls: TLS?
    let stackCount: Int
    let stackTruncated, eofDuringHandshake, eofDuringAdditionalValidation: Bool

    init(_ error: any Error) {
        if let value = error as? NIOHTTPClientUpgradeError {
            family = .nioHTTPUpgrade; wrapper = nil; tls = nil
            switch value {
            case .responseProtocolNotFound: upgrade = .responseProtocolNotFound
            case .invalidHTTPOrdering: upgrade = .invalidHTTPOrdering
            case .upgraderDeniedUpgrade: upgrade = .upgraderDeniedUpgrade
            case .writingToHandlerDuringUpgrade: upgrade = .writingToHandlerDuringUpgrade
            case .writingToHandlerAfterUpgradeCompleted: upgrade = .writingToHandlerAfterUpgradeCompleted
            case .writingToHandlerAfterUpgradeFailed: upgrade = .writingToHandlerAfterUpgradeFailed
            case .receivedResponseBeforeRequestSent: upgrade = .receivedResponseBeforeRequestSent
            case .receivedResponseAfterUpgradeCompleted: upgrade = .receivedResponseAfterUpgradeCompleted
            default: upgrade = .unclassified
            }
            stackCount = 0; stackTruncated = false; eofDuringHandshake = false; eofDuringAdditionalValidation = false
            return
        }
        var associated: BoringSSLError?, observedWrapper: Wrapper?
        if let value = error as? NIOSSLError {
            switch value {
            case .handshakeFailed(let underlying): associated = underlying; observedWrapper = .handshakeFailed
            case .shutdownFailed(let underlying): associated = underlying; observedWrapper = .shutdownFailed
            default: break
            }
        } else if let value = error as? BoringSSLError { associated = value; observedWrapper = .direct }
        guard let associated else {
            family = .unclassified; upgrade = nil; wrapper = nil; tls = nil
            stackCount = 0; stackTruncated = false; eofDuringHandshake = false; eofDuringAdditionalValidation = false
            return
        }
        family = .nioTLS; upgrade = nil; wrapper = observedWrapper
        let stack: NIOBoringSSLErrorStack
        switch associated {
        case .noError: tls = .noError; stack = []
        case .zeroReturn: tls = .zeroReturn; stack = []
        case .wantRead: tls = .wantRead; stack = []
        case .wantWrite: tls = .wantWrite; stack = []
        case .wantConnect: tls = .wantConnect; stack = []
        case .wantAccept: tls = .wantAccept; stack = []
        case .wantX509Lookup: tls = .wantX509Lookup; stack = []
        case .wantCertificateVerify: tls = .wantCertificateVerify; stack = []
        case .syscallError: tls = .syscallError; stack = []
        case .sslError(let value): tls = .sslError; stack = value
        case .unknownError(let value): tls = .unknownError; stack = value
        case .invalidSNIName(let value): tls = .invalidSNIName; stack = value
        case .failedToSetALPN(let value): tls = .failedToSetALPN; stack = value
        }
        let prefix = stack.prefix(8)
        stackCount = prefix.count; stackTruncated = stack.count > 8
        eofDuringHandshake = prefix.contains(.eofDuringHandshake)
        eofDuringAdditionalValidation = prefix.contains(.eofDuringAdditionalCertficiateChainValidation)
    }
    var json: [String: Any] {
        ["family": family.rawValue, "upgrade": upgrade.map { $0.rawValue as Any } ?? NSNull(),
         "wrapper": wrapper.map { $0.rawValue as Any } ?? NSNull(), "tls": tls.map { $0.rawValue as Any } ?? NSNull(),
         "stackCount": stackCount, "stackTruncated": stackTruncated,
         "eofDuringHandshake": eofDuringHandshake, "eofDuringAdditionalValidation": eofDuringAdditionalValidation]
    }
}
