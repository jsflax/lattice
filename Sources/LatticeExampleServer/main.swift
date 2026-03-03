import Foundation
import Vapor
import Lattice
import LatticeServerKit
import Fluent
import FluentSQLiteDriver
import JWT

// A minimal example server demonstrating LatticeServerKit's sync relay
// with a self-contained auth stack (User, Token, OAuthAccount, AuthController).
// This serves as both documentation and an integration test.

var env = try Environment.detect()
try LoggingSystem.bootstrap(from: &env)
let app = try await Application.make(env)

// Database
let dbPath = Environment.get("DATABASE_PATH") ?? "lattice-example.sqlite"
app.databases.use(.sqlite(.file(dbPath)), as: .sqlite)

// Migrations
app.migrations.add(CreateUser())
app.migrations.add(CreateOAuthAccount())
app.migrations.add(CreateToken())
app.migrations.add(AddProfilePictureUrl())

try await app.autoMigrate()

// Session middleware
app.middleware.use(app.sessions.middleware)
app.middleware.use(Token.authenticator())

// Auth routes
let auth = AuthController()
app.post("register", use: auth.register)
app.post("login",    use: auth.login)
app.post("auth", "apple",  use: auth.appleLogin)
app.post("auth", "google", use: auth.googleLogin)

// Protected routes
let protected = app.grouped(Token.authenticator(), User.guardMiddleware())
protected.get("profile") { req in
    let user = try req.auth.require(User.self)
    return try await auth.attachProviders(to: user, req: req)
}
protected.get("me") { req in
    let user = try req.auth.require(User.self)
    return try await auth.attachProviders(to: user, req: req)
}

// Sync relay (the only thing from LatticeServerKit)
// Replace with your actual Lattice model types:
// let storagePath = Environment.get("STORAGE_PATH") ?? "lattice-example"
// Lattice.configureSyncRelay(
//     on: protected,
//     for: [YourModel.self],
//     storagePath: storagePath,
//     userIdExtractor: { req in try req.auth.require(User.self).id! }
// )

// Health
app.get("health") { _ in ["status": "ok"] }

try await app.execute()
try await app.asyncShutdown()
