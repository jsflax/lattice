import Foundation
import Vapor
import Fluent
import JWT
import JWTKit

struct AuthController {
    // MARK: – Email / Password
    
    struct CreateUserRequest: Content {
        let email: String
        let password: String
        let fullName: String?
    }
    
    struct LoginRequest: Content {
        let email: String
        let password: String
    }
    
    struct LoginResponse: Content {
        let token: String
        let user: User.Public
    }
    
    func register(req: Request) async throws -> User.Public {
        let data = try req.content.decode(CreateUserRequest.self)
        let hash = try Bcrypt.hash(data.password)
        let user = User(email: data.email,
                        passwordHash: hash,
                        fullName: data.fullName)
        try await user.save(on: req.db)
        return try await attachProviders(to: user, req: req)
    }
    
    func login(req: Request) async throws -> LoginResponse {
        let data = try req.content.decode(LoginRequest.self)
        let email = data.email
        guard let user = try await User.query(on: req.db)
            .filter(\User.$email == email)
            .with(\.$oauthAccounts) // preload to build `providers`
            .first() else {
            throw Abort(.unauthorized)
        }
        guard let hash = user.passwordHash,
              try Bcrypt.verify(data.password, created: hash) else {
            throw Abort(.unauthorized)
        }
        let token = try await Token.generate(for: user, on: req.db)
        let pub   = try await attachProviders(to: user, req: req)
        return LoginResponse(token: token.value, user: pub)
    }
    
    // MARK: – Apple OAuth
    
    struct AppleAuthRequest: Content {
        let identityToken: String
        let authorizationCode: String?
    }
    
    func appleLogin(req: Request) async throws -> LoginResponse {
        let data = try req.content.decode(AppleAuthRequest.self)
        
        // 1) fetch & cache JWKS
        let appleJWKSURL = URI(string: "https://appleid.apple.com/auth/keys")
        let jwks = try await req.application.appleAuth.getKeys(from: appleJWKSURL, client: req.client)
        let payload = try await req.jwt.apple.verify(data.identityToken)
        
        // 3) upsert user
        let providerID = payload.subject.value
        let email      = payload.email
        //        let name       = payload.name?.formatted()
        
        // find existing OAuthAccount -> join to user
        let acct = try await OAuthAccount.query(on: req.db)
            .filter(\.$provider == "apple")
            .filter(\.$providerUserID == providerID)
            .with(\.$user)
            .first()
        
        let user: User
        if let existing = acct {
            user = existing.user
        } else {
            user = User(email: email, passwordHash: nil, fullName: nil)
            try await user.save(on: req.db)
            let oa = OAuthAccount(provider: "apple",
                                  providerUserID: providerID,
                                  userID: try user.requireID())
            try await oa.save(on: req.db)
        }
        
        // 4) issue your own token
        let token = try await Token.generate(for: user, on: req.db)
        let pub   = try await attachProviders(to: user, req: req)
        return LoginResponse(token: token.value, user: pub)
    }
    
    // MARK: – Google OAuth
    
    struct GoogleAuthRequest: Content {
        let idToken: String
    }
    
    func googleLogin(req: Request) async throws -> LoginResponse {
        let data = try req.content.decode(GoogleAuthRequest.self)

        // 1) fetch Google's JWKS
        let googleJWKSURL = URI(string: "https://www.googleapis.com/oauth2/v3/certs")
        let jwks = try await req.application.googleAuth.getKeys(from: googleJWKSURL,
                                                                client: req.application.client)

        // 2) verify
        let payload = try await req.jwt.google.verify(data.idToken)

        
        // 3) same upsert flow
        let providerID = payload.subject.value
        let email      = payload.email
        let name       = payload.name
        
        let acct = try await OAuthAccount.query(on: req.db)
            .filter(\.$provider == "google")
            .filter(\.$providerUserID == providerID)
            .with(\.$user)
            .first()
        
        let user: User
        if let existing = acct {
            user = existing.user
        } else {
            user = User(email: email, passwordHash: nil, fullName: name)
            try await user.save(on: req.db)
            let oa = OAuthAccount(provider: "google",
                                  providerUserID: providerID,
                                  userID: try user.requireID())
            try await oa.save(on: req.db)
        }
        
        // 4) issue token
        let token = try await Token.generate(for: user, on: req.db)
        let pub   = try await attachProviders(to: user, req: req)
        return LoginResponse(token: token.value, user: pub)
    }
    
    // MARK: – Helpers
    
    func attachProviders(to user: User, req: Request) async throws -> User.Public {
        let id = try user.requireID()
        let reloaded = try await User.query(on: req.db)
            .filter(\User.$id == id)
            .with(\.$oauthAccounts)
            .first()!
        return try reloaded.asPublic()
    }
}
