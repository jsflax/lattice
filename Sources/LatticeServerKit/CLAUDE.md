# Sources/LatticeServerKit - Server-Side Sync Infrastructure

## Overview
LatticeServerKit provides the server-side infrastructure for Lattice's sync capabilities. It handles authentication, change reception, conflict resolution, and broadcasting updates to connected clients.

## Architecture

```
Client 1                  Server (LatticeServerKit)              Client 2
   │                              │                                  │
   │ ─── Auth (JWT) ────────────→ │                                  │
   │ ←── Token ──────────────────  │                                  │
   │                              │                                  │
   │ ─── Upload Changes ────────→ │                                  │
   │     (AuditLog entries)       │                                  │
   │                              │ ─── Broadcast Changes ─────────→ │
   │                              │     (filtered by user/scope)     │
   │ ←── Acknowledge ───────────  │                                  │
   │                              │                                  │
   │                              │ ←─── Poll for Changes ──────────  │
   │                              │ ──── Send Changes ─────────────→ │
```

## File Structure

### Root Files
- **LatticeServerKit.swift** - Main server setup, WebSocket handlers, routing
- **User.swift** - User model for authentication
- **Token.swift** - JWT token model and verification
- **OAuthAccount.swift** - OAuth integration (Google, Apple, etc.)

### Controllers/
- **AuthController.swift** - Authentication endpoints
  - Login/signup
  - Token refresh
  - OAuth callbacks
  
- **Payloads.swift** - Request/response DTOs
  - Authentication payloads
  - Sync payloads
  - Error responses

### Services/
- **JWKSFetcher.swift** - Fetches JSON Web Key Sets for JWT verification
  - Validates tokens from OAuth providers
  - Caches keys for performance

## Key Concepts

### Authentication Flow

1. **Client Authenticates**:
   ```
   POST /auth/login
   { "email": "user@example.com", "password": "..." }
   
   Response: { "token": "eyJ...", "refreshToken": "..." }
   ```

2. **Client Connects to Sync**:
   ```
   WebSocket: ws://server/sync
   Headers: { "Authorization": "Bearer eyJ..." }
   ```

3. **Token Verified**:
   - Server validates JWT signature
   - Extracts user ID from claims
   - Associates WebSocket connection with user

### Sync Protocol

#### Upload Changes
Client sends AuditLog entries to server:
```json
{
  "type": "upload",
  "changes": [
    {
      "tableName": "Trip",
      "operation": "insert",
      "rowId": 123,
      "globalRowId": "uuid-...",
      "changedFields": "{\"name\":\"Costa Rica\",\"days\":10}",
      "timestamp": 1234567890.123
    }
  ]
}
```

Server processes:
1. Validates user owns the data (or has permission)
2. Applies changes to server database
3. Broadcasts to other connected clients
4. Acknowledges to sender

#### Download Changes
Client polls or receives pushed changes:
```json
{
  "type": "changes",
  "changes": [
    {
      "tableName": "Trip",
      "operation": "update",
      "globalRowId": "uuid-...",
      "changedFields": "{\"days\":12}",
      "timestamp": 1234567890.456
    }
  ]
}
```

Client applies changes locally.

### Conflict Resolution

**Strategy**: Last-write-wins (timestamp-based)

1. Server receives change with timestamp T1
2. Server checks existing record has timestamp T2
3. If T1 > T2: Apply change
4. If T1 < T2: Reject change, send current state to client
5. If T1 == T2: Compare globalRowId (deterministic tiebreaker)

**Future**: Could support:
- Custom conflict resolvers
- Operational transforms
- CRDTs for specific field types

### Data Isolation

Each user's data is isolated:
```swift
// Server filters changes by user
func getChanges(for user: User, since timestamp: Date) -> [AuditLogEntry] {
    // Only return changes user has access to
    return auditLog.filter { entry in
        hasAccess(user: user, entry: entry)
    }
}
```

**Permission Models**:
- **Private**: User can only access their own data
- **Shared**: Multiple users can access same data (collaboration)
- **Public**: Any authenticated user can read (but not write)

## Technology Stack

### Web Framework
Likely using Vapor or Hummingbird (Swift server framework)

### Database
- SQLite or PostgreSQL for server-side storage
- Stores:
  - Users, tokens, OAuth accounts
  - Replicated Lattice data
  - AuditLog for sync

### WebSockets
- Real-time bidirectional communication
- Push notifications for changes
- Reduces polling overhead

### JWT (JSON Web Tokens)
- Stateless authentication
- No server-side session storage
- Claims include: user ID, permissions, expiry

## Common Operations

### Starting Server
```swift
let app = Application()
let serverKit = LatticeServerKit(app: app)
try serverKit.configure()
try app.run()
```

### Client Connection
```swift
// In client app (Sources/Lattice/Sync.swift)
let synchronizer = Synchronizer(
    modelTypes: [Trip.self],
    configuration: .init(
        fileURL: databaseURL,
        syncEndpoint: URL(string: "ws://server/sync")!
    )
)
```

### Broadcasting Change
```swift
// Server receives change
func handleUpload(changes: [AuditLogEntry], from user: User) {
    // Apply to server DB
    apply(changes)
    
    // Broadcast to other clients
    let connections = activeConnections.filter { $0.user != user }
    for conn in connections {
        conn.send(changes: changes)
    }
}
```

## Security Considerations

### Token Security
- Tokens should have short expiry (15 min)
- Refresh tokens for long-lived sessions
- Rotate secrets regularly
- Use HTTPS in production

### Data Access Control
- Always validate user has permission to access/modify data
- Filter queries by user ownership
- Audit access attempts
- Rate limit to prevent abuse

### SQL Injection
- Use parameterized queries
- Never concatenate user input into SQL
- Validate/sanitize all inputs

## Testing

### Unit Tests
```swift
@Test func testAuthController() async throws {
    let app = Application(.testing)
    defer { app.shutdown() }
    
    try configure(app)
    
    try app.test(.POST, "/auth/login", beforeRequest: { req in
        try req.content.encode(LoginPayload(email: "test@example.com", password: "password"))
    }, afterResponse: { res in
        XCTAssertEqual(res.status, .ok)
        let token = try res.content.decode(TokenResponse.self)
        XCTAssertNotNil(token.accessToken)
    })
}
```

### Integration Tests
- Test full sync cycle client → server → client
- Verify conflict resolution
- Test multi-user scenarios

## Deployment

### Production Setup
```bash
# Environment variables
export DATABASE_URL=postgres://...
export JWT_SECRET=<long-random-string>
export PORT=8080

# Run server
swift run LatticeServer
```

### Docker
```dockerfile
FROM swift:5.9
WORKDIR /app
COPY . .
RUN swift build -c release
EXPOSE 8080
CMD [".build/release/LatticeServer"]
```

### Scaling
- Horizontal scaling: Multiple server instances
- Load balancer for WebSocket connections
- Shared database (PostgreSQL cluster)
- Redis for pub/sub between instances

## Future Improvements

### Planned Features
1. **AuditLog Compaction** - Server-side compaction to reduce storage
2. **Change Batching** - Batch small changes for efficiency
3. **Partial Sync** - Only sync subsets of data (e.g., active projects)
4. **Offline Queue** - Better offline change queuing on client
5. **Collaboration** - Real-time collaboration features (presence, cursor tracking)

### Performance Optimizations
- Delta encoding (only send changed bytes)
- Compression (gzip changes before sending)
- WebSocket connection pooling
- Database query optimization

## Relationship to Core Lattice

LatticeServerKit is **independent** of core Lattice ORM:
- Can use Lattice for server-side models (optional)
- Primary role is coordinating client sync
- Could theoretically work with other ORMs/databases

However, it's **tightly coupled** to:
- AuditLog format from `Sources/Lattice/AuditLog.swift`
- Sync protocol from `Sources/Lattice/Sync.swift`
- Model serialization format

## Related Files

### In Core Lattice
- `Sources/Lattice/Sync.swift` - Client-side sync coordinator
- `Sources/Lattice/AuditLog.swift` - Change tracking
- `Sources/Lattice/Lattice.swift` - Database operations

### Server Config
- Likely has `Package.swift` dependencies:
  - Vapor or Hummingbird (web framework)
  - JWT library
  - PostgreSQL driver (or SQLite)
