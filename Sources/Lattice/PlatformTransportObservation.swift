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
    let kind: Kind
    let domain: Domain
    let code: Int?

    static func copy(_ error: any Error) -> Self {
        #if os(Linux)
        if let value = error as? NIOSSLExtraError {
            return .init(kind: value == .failedToValidateHostname ? .identity : .tls, domain: .nioSSLExtra, code: nil)
        }
        if error is NIOSSLError { return .init(kind: .tls, domain: .nioSSL, code: nil) }
        if let value = error as? WebSocketClient.Error {
            switch value {
            case .invalidResponseStatus(let response):
                return .init(kind: .protocolFailure, domain: .nioWebSocket, code: Int(response.status.code))
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
}

internal struct PlatformTransportFailureObservation: Sendable, Equatable {
    enum Phase: String, Sendable { case trustEvaluation, completion, receive, send, connect }
    let phase: Phase
    let error: PlatformTransportErrorFact
    let trustAccepted: Bool?
}
