import Foundation

/// One registration serves explicit files; embedding hosts supply an immutable read policy and a
/// default file. No synchronization, migrations, eager directory scans, or persistent registry.
public actor LatticeProviderPool {
    private let defaultDB: URL?
    private let defaultLimit: Int
    private let maxLimit: Int
    private let maxDepthCap: Int
    private let readPolicy: LatticeReadPolicy?
    private let sourceID: String?
    private var authorizedIdentity: String?
    private struct Entry {
        let signature: String
        let diagnostics: LatticeDiagnostics
        var provider: Task<LatticeDataProvider, Error>?
        var lastUse: Date
        var active: Int = 0
    }
    private var entries: [String: Entry] = [:]
    public init(defaultDB: URL? = nil, defaultLimit: Int = 25, maxLimit: Int = 500,
                maxDepthCap: Int = 3, readPolicy: LatticeReadPolicy? = nil, sourceID: String? = nil) {
        self.defaultDB = defaultDB; self.defaultLimit = defaultLimit; self.maxLimit = maxLimit
        self.maxDepthCap = maxDepthCap; self.readPolicy = readPolicy; self.sourceID = sourceID
    }

    public func handle(tool: String, argumentsJSON: String) async -> ProviderResult {
        guard argumentsJSON.utf8.count <= 65_536,
              let data = argumentsJSON.data(using: .utf8),
              let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .error("invalid_arguments", "Arguments must be a JSON object of at most 64 KiB.")
        }
        guard LatticeToolCatalog.toolNames.contains(tool) else { return .error("unknown_tool", "Unknown Lattice tool.") }
        if let db = args["db"], !(db is String) { return .error("invalid_arguments", "db must be a path string.") }
        let url: URL?
        if let db = args["db"] as? String {
            guard !db.isEmpty else { return .error("invalid_arguments", "db cannot be empty.") }
            guard readPolicy == nil || defaultDB?.standardizedFileURL.resolvingSymlinksInPath().path == URL(fileURLWithPath: db).standardizedFileURL.resolvingSymlinksInPath().path else {
                return .error("source_unavailable", "The requested source is not authorized.")
            }
            url = URL(fileURLWithPath: (db as NSString).expandingTildeInPath)
        } else { url = defaultDB }
        guard let url else {
            if tool == "lattice_status" {
                guard args.isEmpty else { return .error("invalid_arguments", "Status accepts only db.") }
                let payload: [String: Any] = ["version": LatticeToolCatalog.version, "readOnly": true,
                    "tools": LatticeToolCatalog.toolNames, "knownSources": Array(entries.keys.sorted().prefix(8)),
                    "knownSourcesTruncated": entries.count > 8,
                    "limits": ["defaultRows": 25, "maxRows": 500, "defaultDepth": 0, "maxDepth": 3, "maxOutputBytes": 32_768]]
                return encode(payload)
            }
            return .error("no_database", "Pass db, or launch lattice-mcp with --db.")
        }
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        let key = file.path
        do {
            let signature = try LatticeFilePreflight.signature(file)
            if readPolicy != nil {
                let identity = LatticeFilePreflight.identity(signature)
                guard authorizedIdentity == nil || authorizedIdentity == identity else {
                    return .error("source_unavailable", "The authorized store was replaced. Reopen the room to establish a new reader.")
                }
                authorizedIdentity = identity
            }
            // A changed inode or schema cookie means the cached reader describes a different store.
            if entries[key]?.signature != signature {
                entries[key] = Entry(signature: signature,
                    diagnostics: LatticeDiagnostics(fileURL: file, readPolicy: readPolicy), lastUse: Date())
            }
            entries[key]!.active += 1; entries[key]!.lastUse = Date()
            defer {
                if entries[key]?.signature == signature {
                    entries[key]!.active -= 1; entries[key]!.lastUse = Date()
                }
                evictIdle()
            }
            let result: ProviderResult
            if tool == "lattice_status" || tool == "lattice_changes" {
                result = await entries[key]!.diagnostics.handle(tool: tool, argumentsJSON: argumentsJSON)
            } else {
                if entries[key]!.provider == nil {
                    let limit = defaultLimit, maximum = maxLimit, depth = maxDepthCap, policy = readPolicy
                    entries[key]!.provider = Task {
                        try await LatticeDataProvider(fileURL: file, defaultLimit: limit, maxLimit: maximum,
                                                      maxDepthCap: depth, readPolicy: policy)
                    }
                }
                let task = entries[key]!.provider!
                do { result = await (try await task.value).handle(tool: tool, argumentsJSON: argumentsJSON) }
                catch {
                    if entries[key]?.signature == signature { entries[key]!.provider = nil }
                    throw error
                }
            }
            guard try LatticeFilePreflight.signature(file) == signature else {
                entries[key] = nil
                return .error("source_changed", "The store or schema changed during the read. Retry with a fresh reader.")
            }
            return redact(withSource(result, path: key, transactional: tool == "lattice_status" || tool == "lattice_changes"), path: key)
        } catch {
            return redact(.error("open_failed", "Could not inspect source: \(error)"), path: key)
        }
    }
    private func evictIdle() {
        let now = Date()
        for key in entries.keys where entries[key]!.active == 0 && now.timeIntervalSince(entries[key]!.lastUse) > 60 { entries[key] = nil }
        let idle = entries.filter { $0.value.active == 0 }.sorted { $0.value.lastUse < $1.value.lastUse }
        for entry in idle.prefix(max(0, entries.count - 8)) { entries[entry.key] = nil }
    }
    private func encode(_ payload: [String: Any]) -> ProviderResult {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return .error("encoding_failed", "Cannot encode status.") }
        guard data.count <= 32_768 else { return .error("result_too_large", "Select a source for its status.") }
        return .init(json: String(decoding: data, as: UTF8.self), isError: false)
    }
    private func withSource(_ result: ProviderResult, path: String, transactional: Bool) -> ProviderResult {
        guard !result.isError, let data = result.json.data(using: .utf8),
              var payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return result }
        payload["source"] = ["id": sourceID ?? path, "kind": "file", "observedAt": ISO8601DateFormatter().string(from: Date()),
                             "readerVersion": LatticeToolCatalog.version, "consistency": transactional ? "read_transaction" : "live_read"]
        guard let encoded = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), encoded.count <= 32_768 else {
            return .error("result_too_large", "Reduce the requested page size or selected fields.")
        }
        return .init(json: String(decoding: encoded, as: UTF8.self), isError: false)
    }
    private func redact(_ result: ProviderResult, path: String) -> ProviderResult {
        guard let sourceID, let data = result.json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return result }
        func replace(_ value: Any) -> Any {
            if let value = value as? String { return value.replacingOccurrences(of: path, with: sourceID).replacingOccurrences(of: defaultDB?.path ?? path, with: sourceID) }
            if let value = value as? [Any] { return value.map(replace) }
            if let value = value as? [String: Any] { return value.mapValues(replace) }
            return value
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: replace(object), options: [.sortedKeys]) else { return .error("encoding_failed", "Cannot encode result.") }
        return .init(json: String(decoding: encoded, as: UTF8.self), isError: result.isError)
    }
}
