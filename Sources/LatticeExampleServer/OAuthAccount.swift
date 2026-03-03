import Vapor
import Fluent

public final class OAuthAccount: Model, Content, @unchecked Sendable {
    public static let schema = "oauth_accounts"

    @ID(key: .id)            public var id: UUID?
    @Field(key: "provider")  public var provider: String      // "apple", "google", …
    @Field(key: "provider_user_id") public var providerUserID: String
    @OptionalField(key: "access_token")  public var accessToken: String?
    @OptionalField(key: "refresh_token") public var refreshToken: String?
    @Parent(key: "user_id")    public var user: User
    @Timestamp(key: "created_at", on: .create) public var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) public var updatedAt: Date?

    public init() {}
    public init(provider: String,
         providerUserID: String,
         userID: UUID)
    {
        self.provider        = provider
        self.providerUserID  = providerUserID
        self.$user.id        = userID
    }
}

import Fluent

public struct CreateOAuthAccount: AsyncMigration {
    public init() {}
    public func prepare(on db: Database) async throws {
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

    public func revert(on db: Database) async throws {
        try await db.schema(OAuthAccount.schema).delete()
    }
}
