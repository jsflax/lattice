import Foundation
import Vapor
import JWTKit

extension JWKS: @unchecked Sendable {}
actor JWKSCache {
    private var cache: JWKS?
    private var expiry: Date = .distantPast

    func getKeys(from url: URI,
                 client: Client) async throws -> JWKS
    {
        if let jwks = cache, expiry > Date() {
            return jwks
        }
        struct Response: Content, @unchecked Sendable {
            let keys: [JWK]
        }
        let res = try await client.get(url)
        let body = try res.content.decode(Response.self)
        let jwks = JWKS(keys: body.keys)
        // refresh every day
        cache  = jwks
        expiry = Date().addingTimeInterval(24*60*60)
        return jwks
    }
}

extension Application {
    private struct AppleKey {}
    private struct GoogleKey {}

    var appleAuth: JWKSCache {
        .init() // ideally single‑ton; you can store in app.storage
    }
    var googleAuth: JWKSCache {
        .init()
    }
}
