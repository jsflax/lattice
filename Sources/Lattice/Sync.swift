import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os)
import os
#endif
import LatticeSwiftCppBridge

// ============================================================================
// C++ to Swift Type Conversions via JSON
// ============================================================================

extension AuditLog {
    /// JSON representation that matches C++ audit_log_entry::to_json() format
    private struct CxxAuditLogJSON: Codable {
        let id: Int64
        let globalId: String
        let tableName: String
        let operation: String
        let rowId: Int64
        let globalRowId: String
        let changedFields: [String: AnyProperty]
        let changedFieldsNames: [String]
        let timestamp: String
        let isFromRemote: Bool
        let isSynchronized: Bool
    }

    /// Create a Swift AuditLog from C++ audit_log_entry JSON
    /// Uses JSON serialization to bridge the complex C++ types
    static func fromCxxJSON(_ jsonString: String) throws -> AuditLog {
        guard let data = jsonString.data(using: .utf8) else {
            throw NSError(domain: "AuditLog", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON string"])
        }

        let decoder = JSONDecoder()
        let json = try decoder.decode(CxxAuditLogJSON.self, from: data)

        let auditLog = AuditLog()

        auditLog.tableName = json.tableName

        // Parse operation
        switch json.operation {
        case "INSERT": auditLog.operation = .insert
        case "UPDATE": auditLog.operation = .update
        case "DELETE": auditLog.operation = .delete
        default: auditLog.operation = .insert
        }

        auditLog.rowId = json.rowId
        auditLog.globalRowId = UUID(uuidString: json.globalRowId)
        auditLog.changedFields = json.changedFields
        auditLog.changedFieldsNames = json.changedFieldsNames

        // Parse timestamp
        if let ts = Double(json.timestamp) {
            auditLog.timestamp = Date(timeIntervalSince1970: ts)
        } else if let date = ISO8601DateFormatter().date(from: json.timestamp) {
            auditLog.timestamp = date
        } else {
            auditLog.timestamp = Date()
        }

        auditLog.isFromRemote = json.isFromRemote
        auditLog.isSynchronized = json.isSynchronized
        auditLog.__globalId = UUID(uuidString: json.globalId)  // setter: __globalId is the stored property

        return auditLog
    }

    /// Create a Swift AuditLog from a C++ audit_log_entry
    /// Uses to_json() on the C++ side and JSON decoding on Swift side
    convenience init(from cxx: lattice.audit_log_entry) {
        let jsonString = String(cxx.to_json())

        do {
            let parsed = try AuditLog.fromCxxJSON(jsonString)
            self.init()
            self.tableName = parsed.tableName
            self.operation = parsed.operation
            self.rowId = parsed.rowId
            self.globalRowId = parsed.globalRowId
            self.changedFields = parsed.changedFields
            self.changedFieldsNames = parsed.changedFieldsNames
            self.timestamp = parsed.timestamp
            self.isFromRemote = parsed.isFromRemote
            self.isSynchronized = parsed.isSynchronized
            self.__globalId = parsed.globalId  // setter: __globalId is the stored property
        } catch {
            // Fallback to empty audit log on parse failure
            self.init()
            self.tableName = ""
            self.rowId = 0
            self.changedFields = [:]
            self.timestamp = Date()
            self.isFromRemote = false
        }
    }

    /// Convert Swift AuditLog to JSON bytes for C++ consumption
    func toCxxJSONBytes() throws -> Data {
        return try JSONEncoder().encode(self)
    }
}

// ============================================================================
// ServerSentEvent
// ============================================================================

public enum ServerSentEvent: Codable {
    // Concrete [AuditLog] rather than `any Sequence<AuditLog>`: the latter is a
    // parameterized existential (iOS-16 runtime floor), and the payload is always
    // materialized to an array on decode/encode anyway. Callers passing a lazy
    // sequence (e.g. a Results Slice) wrap it with `Array(...)`.
    case auditLog([AuditLog])
    case ack([UUID])

    private enum CodingKeys: String, CodingKey {
        case kind, auditLog, ack
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)

        switch kind {
        case "auditLog":
            let logs = try container.decode([AuditLog].self, forKey: .auditLog)
            self = .auditLog(logs)
        case "ack":
            let ids = try container.decode([UUID].self, forKey: .ack)
            self = .ack(ids)
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown kind: \(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .auditLog(let logs):
            try container.encode("auditLog", forKey: .kind)
            try container.encode(logs, forKey: .auditLog)
        case .ack(let ids):
            try container.encode("ack", forKey: .kind)
            try container.encode(ids, forKey: .ack)
        }
    }
}

extension Array {
    /// Returns this array split into subarrays of at most `size` elements.
    public func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        var chunks: [[Element]] = []
        var idx = 0
        while idx < count {
            let end = Swift.min(idx + size, count)
            chunks.append(Array(self[idx..<end]))
            idx += size
        }
        return chunks
    }
}

struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    
    init(_ value: T) {
        self.value = value
    }
}

extension Lattice {
    public func receive(_ data: Data) throws -> [UUID] {
        let result = backend.receiveSyncData(data).compactMap {
            UUID(uuidString: $0)
        }
        if let lastError = backend.lastReceiveError() {
            throw LatticeError.syncReceiveFailed(lastError)
        }
        return result
    }
    
    /// Get audit log events after a checkpoint as a lazy query.
    /// Use `snapshot(limit:offset:)` to paginate without loading all entries into memory.
    public func eventsAfter(globalId: UUID?) -> TableResults<AuditLog> {
        var results = objects(AuditLog.self)
            .sortedBy(\.primaryKey, order: .forward)
        if let globalId {
            let checkpointId = objects(AuditLog.self)
                .where { $0.globalId == globalId }
                .snapshot(limit: 1)
                .first?
                .primaryKey
            if let checkpointId {
                results = results.where { $0.primaryKey > checkpointId }
            }
        }
        return results
    }
}
