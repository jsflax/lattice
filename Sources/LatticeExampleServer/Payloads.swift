import JWTKit
import Foundation
import Vapor

// Apple identity-token payload
struct ApplePayload: JWTPayload {
    struct EmailVerified: Codable, Sendable, Equatable {
      let value: String  // "true" or "false"
      var bool: Bool { value == "true" }
    }

    let iss: IssuerClaim
    let aud: [String]
    let exp: ExpirationClaim
    let iat: IssuedAtClaim
    let sub: SubjectClaim
    let email: String?
    let email_verified: EmailVerified?
    let nonce: String?
    let auth_time: Date?
    let name: PersonNameComponents?

    func verify(using algorithm: some JWTAlgorithm) async throws {
        try exp.verifyNotExpired()
        guard iss.value == "https://appleid.apple.com" else {
            throw JWTError.claimVerificationFailure(
               failedClaim: iss, reason: "Invalid issuer")
        }
        guard aud.contains(Environment.get("APPLE_SERVICE_ID")!) else {
            throw JWTError.claimVerificationFailure(
                failedClaim: nil, reason: "Invalid audience")
        }
    }
}

// Google ID‑token payload
struct GooglePayload: JWTPayload {
    let iss: IssuerClaim
    let azp: String?
    let aud: AudienceClaim
    let exp: ExpirationClaim
    let iat: IssuedAtClaim
    let sub: SubjectClaim
    let email: String
    let email_verified: Bool
    let name: String?
    let picture: String?

    func verify(using algorithm: some JWTAlgorithm) async throws {
        try exp.verifyNotExpired()
        guard iss.value == "https://accounts.google.com" ||
              iss.value == "accounts.google.com" else {
            throw JWTError.claimVerificationFailure(
               failedClaim: iss, reason: "Invalid issuer")
        }
        guard aud.value.contains(Environment.get("GOOGLE_CLIENT_ID")!) else {
            throw JWTError.claimVerificationFailure(
               failedClaim: aud, reason: "Invalid audience")
        }
    }
}
