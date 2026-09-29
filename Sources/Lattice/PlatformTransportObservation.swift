import Foundation
#if os(Linux)
import NIOCore
import NIOSSL
import WebSocketKit
#endif

/// Passive copied facts only. No NSError/userInfo, dynamic type, URL or message
/// is retained. Nil observers keep all ordinary transport behavior unchanged.
internal struct PlatformTransportErrorFact: Sendable, Equatable {
    enum Kind: String, Sendable { case none, identity, tls, transport, protocolFailure, cancelled, fileSystem, other }
    enum Domain: String, Sendable { case none, url, osStatus, posix, cocoa, nioSSL, nioSSLExtra, nioWebSocket, nioChannel }
    enum Category: String, Sendable {
        case writeDuringTLSShutdown, unableToAllocate, noSuchFilesystemObject, failedToLoadCertificate, failedToLoadPrivateKey
        case handshakeFailed, shutdownFailed, cannotMatchULabel, noCertificateToValidate, unableToValidateCertificate
        case cannotFindPeerIP, readInInvalidTLSState, uncleanShutdown
        case noError, zeroReturn, wantRead, wantWrite, wantConnect, wantAccept, wantX509Lookup, wantCertificateVerify
        case syscallError, sslError, unknownError, invalidSNIName, failedToSetALPN
    }
    let kind: Kind
    let domain: Domain
    let code: Int?
    let category: Category?

    init(kind: Kind, domain: Domain, code: Int?, category: Category? = nil) {
        self.kind = kind; self.domain = domain; self.code = code; self.category = category
    }

    static func copy(_ error: any Error) -> Self {
        #if os(Linux)
        if let value = error as? NIOSSLExtraError {
            return .init(kind: value == .failedToValidateHostname ? .identity : .tls, domain: .nioSSLExtra, code: nil)
        }
        if let category = nioCategory(error) { return .init(kind: .tls, domain: .nioSSL, code: nil, category: category) }
        if let value = error as? WebSocketClient.Error {
            switch value {
            case .invalidResponseStatus(let response):
                return .init(kind: .protocolFailure, domain: .nioWebSocket, code: Int32(exactly: response.status.code).map(Int.init))
            case .invalidURL, .alreadyShutdown:
                return .init(kind: .protocolFailure, domain: .nioWebSocket, code: nil)
            }
        }
        if error is ChannelError { return .init(kind: .transport, domain: .nioChannel, code: nil) }
        #endif
        let value = error as NSError
        let code = Int32(exactly: value.code).map(Int.init)
        switch value.domain {
        case NSURLErrorDomain:
            let kind: Kind
            switch value.code {
            case NSURLErrorCancelled: kind = .cancelled
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
                 NSURLErrorClientCertificateRequired: kind = .tls
            case NSURLErrorBadURL, NSURLErrorUnsupportedURL, NSURLErrorBadServerResponse: kind = .protocolFailure
            default: kind = .transport
            }
            return .init(kind: kind, domain: .url, code: code)
        case NSOSStatusErrorDomain: return .init(kind: .other, domain: .osStatus, code: code)
        case NSPOSIXErrorDomain: return .init(kind: .transport, domain: .posix, code: code)
        case NSCocoaErrorDomain: return .init(kind: .fileSystem, domain: .cocoa, code: code)
        default: return .init(kind: .other, domain: .none, code: nil)
        }
    }

    #if os(Linux)
    private static func nioCategory(_ error: any Error) -> Category? {
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
    #endif
}

internal struct PlatformTransportFailureObservation: Sendable, Equatable {
    enum Phase: String, Sendable { case trustEvaluation, completion, receive, send, connect }
    enum GuardOutcome: String, Sendable, CaseIterable {
        case missingAttempt, staleTaskOrSession, nonServerTrust, missingServerTrust, currentServerTrust
    }
    let phase: Phase
    let error: PlatformTransportErrorFact
    let trustAccepted: Bool?
    let guardOutcome: GuardOutcome?
    let underlyingErrors: [PlatformTransportErrorFact]
    let underlyingTruncated: Bool
    let underlyingCycle: Bool

    init(phase: Phase, error: PlatformTransportErrorFact, trustAccepted: Bool?, guardOutcome: GuardOutcome? = nil,
         underlyingErrors: [PlatformTransportErrorFact] = [], underlyingTruncated: Bool = false, underlyingCycle: Bool = false) {
        self.phase = phase; self.error = error; self.trustAccepted = trustAccepted; self.guardOutcome = guardOutcome
        self.underlyingErrors = Array(underlyingErrors.prefix(4))
        self.underlyingTruncated = underlyingTruncated || underlyingErrors.count > 4
        self.underlyingCycle = underlyingCycle
    }

    static func rejectedChallenge(_ outcome: GuardOutcome) -> Self {
        .init(phase: .trustEvaluation, error: .init(kind: .none, domain: .none, code: nil),
              trustAccepted: nil, guardOutcome: outcome)
    }

    static func report(_ observer: (@Sendable (Self) -> Void)?, phase: Phase, error: any Error) {
        guard let observer else { return }
        let root = error as NSError
        var current = root, seen = Set<ObjectIdentifier>([ObjectIdentifier(root)])
        var values: [PlatformTransportErrorFact] = [], truncated = false, cycle = false
        while let raw = current.userInfo[NSUnderlyingErrorKey] {
            guard let next = raw as? NSError else { truncated = true; break }
            guard !seen.contains(ObjectIdentifier(next)) else { cycle = true; break }
            guard values.count < 4 else { truncated = true; break }
            seen.insert(ObjectIdentifier(next))
            values.append(.copy(next)); current = next
        }
        observer(.init(phase: phase, error: .copy(error), trustAccepted: nil,
                       underlyingErrors: values, underlyingTruncated: truncated, underlyingCycle: cycle))
    }
}
