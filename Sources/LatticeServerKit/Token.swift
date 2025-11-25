import Vapor
import Fluent

final class Token: Model, Content, ModelTokenAuthenticatable, @unchecked Sendable {
    static var userKey: KeyPath<Token, Parent<User>> {
        \Token.$user
    }
    
    typealias User = LatticeUser
    static var valueKey: KeyPath<Token, Field<String>> {
        \Token.$value
    }
    
    /// A token is valid iff it hasn't expired yet.
    var isValid: Bool {
        guard let expires = expiresAt else {
            return true    // no expiry set → always valid
        }
        return expires > Date()
    }
    
    static let schema = "tokens"
    
    @ID(key: .id)            var id: UUID?
    @Field(key: "value")     var value: String      // opaque random string
    @Parent(key: "user_id")  var user: User
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "expires_at", on: .none)  var expiresAt: Date?

    init() {
        value = ""
    }
    
    convenience init(value: String,
                     userID: UUID,
                     expiresAt: Date? = nil)
    {
        self.init()
        self.value        = value
        self.$user.id     = userID
        self.expiresAt    = expiresAt
    }

    // helper factory
    static func generate(for user: User,
                         expiresIn: TimeInterval = 60*60*24*30,
                         on db: Database) async throws -> Token
    {
        let raw = [UInt8].random(count: 32).base64
        let expiry = Date().addingTimeInterval(expiresIn)
        let token = Token(value: raw, userID: try user.requireID(), expiresAt: expiry)
        try await token.save(on: db)
        return token
    }
}

// Sources/App/Migrations/CreateToken.swift
import Fluent

struct CreateToken: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(Token.schema)
          .id()
          .field("value",     .string, .required)
          .field("user_id",   .uuid, .required, .references(User.schema, .id))
          .field("created_at", .datetime)
          .field("expires_at", .datetime)
          .unique(on: "value")
          .create()
    }
    
    func revert(on db: Database) async throws {
        try await db.schema(Token.schema).delete()
    }
}
