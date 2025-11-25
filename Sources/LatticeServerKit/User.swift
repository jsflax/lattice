import Vapor
import Fluent

final class User: Model, Content, Authenticatable, @unchecked Sendable {
    static let schema = "users"
    
    @ID(key: .id)
    var id: UUID?
    @OptionalField(key: "email")
    var email: String?
    @OptionalField(key: "password_hash")
    var passwordHash: String?
    @OptionalField(key: "full_name")
    var fullName: String?
    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?
    
    @Children(for: \.$user)
    var oauthAccounts: [OAuthAccount]
    @Children(for: \.$user)
    var tokens: [Token]
    
    init() {}
    init(id: UUID? = nil,
         email: String?,
         passwordHash: String?,
         fullName: String?) {
        self.id = id
        self.email = email
        self.passwordHash = passwordHash
        self.fullName = fullName
    }
    
    struct Public: Content {
        let id: UUID
        let email: String?
        let fullName: String?
        let providers: [String]
    }
    
    func asPublic() throws -> Public {
        let provs = oauthAccounts.map { $0.provider } +
        (passwordHash != nil ? ["email"] : [])
        return Public(id: try requireID(),
                      email: email,
                      fullName: fullName,
                      providers: provs)
    }
}

// Sources/App/Migrations/CreateUser.swift
import Fluent

struct CreateUser: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(User.schema)
            .id()
            .field("email",        .string)
            .field("password_hash",.string)
            .field("full_name",    .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "email")
            .create()
    }
    
    func revert(on db: Database) async throws {
        try await db.schema(User.schema).delete()
    }
}

typealias LatticeUser = User
