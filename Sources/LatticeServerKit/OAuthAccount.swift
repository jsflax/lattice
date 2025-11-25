// Sources/App/Models/OAuthAccount.swift
import Vapor
import Fluent

final class OAuthAccount: Model, Content, @unchecked Sendable {
    static let schema = "oauth_accounts"

    @ID(key: .id)            var id: UUID?
    @Field(key: "provider")  var provider: String      // "apple", "google", …
    @Field(key: "provider_user_id") var providerUserID: String
    @OptionalField(key: "access_token")  var accessToken: String?
    @OptionalField(key: "refresh_token") var refreshToken: String?
    @Parent(key: "user_id")    var user: User
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
    init(provider: String,
         providerUserID: String,
         userID: UUID)
    {
        self.provider        = provider
        self.providerUserID  = providerUserID
        self.$user.id        = userID
    }
}

// Sources/App/Migrations/CreateOAuthAccount.swift
import Fluent

struct CreateOAuthAccount: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(OAuthAccount.schema)
          .id()
          .field("provider",          .string, .required)
          .field("provider_user_id", .string, .required)
          .field("access_token",     .string)
          .field("refresh_token",    .string)
          .field("user_id",          .uuid, .required, .references(User.schema, .id))
          .field("created_at", .datetime)
          .field("updated_at", .datetime)
          .unique(on: "provider", "provider_user_id")
          .create()
    }
    
    func revert(on db: Database) async throws {
        try await db.schema(OAuthAccount.schema).delete()
    }
}
