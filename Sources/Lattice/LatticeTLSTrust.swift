import Foundation

public enum LatticeTLSPin {
    public static func isValid(_ fingerprint: String) -> Bool {
        fingerprint.utf8.count == 64 && fingerprint.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    public enum ConfigurationError: Error, LocalizedError {
        case invalidPin, unsupportedPlatform
        public var errorDescription: String? {
            switch self {
            case .invalidPin: "A certificate pin must be a lowercase SHA-256 fingerprint on a secure WebSocket endpoint."
            case .unsupportedPlatform: "This platform's sync transport does not support pinned local certificates."
            }
        }
    }
}

#if canImport(Security)
import Security
import CryptoKit

/// Shared HTTP/WebSocket trust evaluator. A QR pin is an explicit anchor for one
/// leaf certificate; hostname, validity dates and TLS policy still apply.
public enum LatticeTLSTrust {
    public static func credential(for challenge: URLAuthenticationChallenge, certificateSHA256: String) -> URLCredential? {
        guard LatticeTLSPin.isValid(certificateSHA256),
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return nil }
        return credential(for: trust, host: challenge.protectionSpace.host,
                          certificateSHA256: certificateSHA256)
    }

    internal static func credential(for trust: SecTrust, host: String,
                                    certificateSHA256: String) -> URLCredential? {
        guard LatticeTLSPin.isValid(certificateSHA256),
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        let bytes = SecCertificateCopyData(leaf) as Data
        let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard actual == certificateSHA256,
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [leaf] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else { return nil }
        return URLCredential(trust: trust)
    }
}
#endif
