import Foundation

/// Routes tool calls to a `LatticeDataProvider` chosen per call by a `db` path,
/// so a single registered `lattice-mcp` can serve ANY `.lattice` file (the
/// idempotent, file-agnostic install). Providers are opened lazily and cached by
/// resolved path; concurrent opens of the same file are de-duplicated via an
/// in-flight `Task`. An optional launch default (`--db`) is used when a call
/// omits `db`.
public actor LatticeProviderPool {
    private let defaultDB: URL?
    private let defaultLimit: Int
    private let maxLimit: Int
    private let maxDepthCap: Int
    /// Keyed by standardized absolute path. Holds the in-flight/finished open
    /// task so racing calls for the same DB share one provider.
    private var providers: [String: Task<LatticeDataProvider, Error>] = [:]

    public init(defaultDB: URL? = nil,
                defaultLimit: Int = 100,
                maxLimit: Int = 10_000,
                maxDepthCap: Int = 5) {
        self.defaultDB = defaultDB
        self.defaultLimit = defaultLimit
        self.maxLimit = maxLimit
        self.maxDepthCap = maxDepthCap
    }

    /// Resolve the target DB (explicit `db` argument, else the launch default),
    /// open/reuse its provider, and dispatch the tool call.
    public func handle(tool: String, argumentsJSON: String) async -> ProviderResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let url: URL?
        if let s = args["db"] as? String, !s.isEmpty {
            url = URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        } else {
            url = defaultDB
        }
        guard let url else {
            return .error("no_database",
                          "No database specified. Pass a 'db' path argument, or start lattice-mcp with --db <path>.")
        }
        do {
            let provider = try await providerFor(url)
            return await provider.handle(tool: tool, argumentsJSON: argumentsJSON)
        } catch {
            return .error("open_failed", "Failed to open '\(url.path)': \(error)")
        }
    }

    private func providerFor(_ url: URL) async throws -> LatticeDataProvider {
        let key = url.standardizedFileURL.path
        if let existing = providers[key] {
            return try await existing.value
        }
        guard FileManager.default.fileExists(atPath: key) else {
            throw ProviderError("No such database file: \(key)")
        }
        // Reject empty / non-SQLite files up front. The dynamic open of a 0-byte
        // or garbage file can wedge (the call never returns); validating the
        // SQLite magic header gives a clean error instead. A valid-but-locked DB
        // still has the header and proceeds (busy-timeout handles contention).
        guard Self.isSQLiteFile(at: key) else {
            throw ProviderError("Not a Lattice/SQLite database (bad or empty file): \(key)")
        }
        // Assigned synchronously (before any await) so a concurrent call for the
        // same key awaits this same task instead of opening a second time.
        let task = Task { [defaultLimit, maxLimit, maxDepthCap] in
            try await LatticeDataProvider(fileURL: url,
                                          defaultLimit: defaultLimit,
                                          maxLimit: maxLimit,
                                          maxDepthCap: maxDepthCap)
        }
        providers[key] = task
        do {
            return try await task.value
        } catch {
            providers[key] = nil   // failed open: allow a later retry
            throw error
        }
    }

    /// True if the file begins with the SQLite file header ("SQLite format 3\0").
    private static func isSQLiteFile(at path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        let magic = Array("SQLite format 3\u{0}".utf8)  // 16 bytes
        guard let head = try? fh.read(upToCount: magic.count), head.count == magic.count else {
            return false
        }
        return Array(head) == magic
    }

    private struct ProviderError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }
}
