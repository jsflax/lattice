import Vapor
import Fluent

public final class User: Model, Content, Authenticatable, @unchecked Sendable {
    public static let schema = "users"

    @ID(key: .id)
    public var id: UUID?
    @OptionalField(key: "email")
    public var email: String?
    @OptionalField(key: "password_hash")
    public var passwordHash: String?
    @OptionalField(key: "full_name")
    public var fullName: String?
    @OptionalField(key: "profile_picture_url")
    public var profilePictureUrl: String?
    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update)
    public var updatedAt: Date?

    @Children(for: \.$user)
    public var oauthAccounts: [OAuthAccount]
    @Children(for: \.$user)
    public var tokens: [Token]

    public init() {}
    public init(id: UUID? = nil,
         email: String?,
         passwordHash: String?,
         fullName: String?,
         profilePictureUrl: String? = nil) {
        self.id = id
        self.email = email
        self.passwordHash = passwordHash
        self.fullName = fullName
        self.profilePictureUrl = profilePictureUrl
    }

    public struct Public: Content {
        public let id: UUID
        public let email: String?
        public let fullName: String?
        public let profilePictureUrl: String?
        public let providers: [String]
    }

    public func asPublic() throws -> Public {
        let provs = oauthAccounts.map { $0.provider } +
        (passwordHash != nil ? ["email"] : [])
        return Public(id: try requireID(),
                      email: email,
                      fullName: fullName,
                      profilePictureUrl: profilePictureUrl,
                      providers: provs)
    }
}

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

struct AddProfilePictureUrl: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(User.schema)
            .field("profile_picture_url", .string)
            .update()
    }

    func revert(on db: Database) async throws {
        try await db.schema(User.schema)
            .deleteField("profile_picture_url")
            .update()
    }
}

public typealias LatticeUser = User
