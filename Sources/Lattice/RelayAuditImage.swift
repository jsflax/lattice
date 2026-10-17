import Foundation

// No unavailable image may be fabricated as SQL NULL or replaced by a live read.
enum RelayAuditImageError: Error {
    case unavailable(String)
    case wrongType(String)
    case invalidValue(String)
}

extension AuditLog {
    static func _fromRelayQueryImage(_ source: any ObjectBackend) throws -> AuditLog {
        func value(_ name: String) throws -> ColumnValue {
            guard let result = source._queryRowValue(named: name) else {
                throw RelayAuditImageError.unavailable(name)
            }
            return result
        }
        func integer(_ name: String) throws -> Int64 {
            guard case .int64(let result) = try value(name) else {
                throw RelayAuditImageError.wrongType(name)
            }
            return result
        }
        func text(_ name: String) throws -> String {
            guard case .text(let result) = try value(name) else {
                throw RelayAuditImageError.wrongType(name)
            }
            return result
        }
        func optionalText(_ name: String) throws -> String? {
            switch try value(name) {
            case .null: return nil
            case .text(let result): return result
            default: throw RelayAuditImageError.wrongType(name)
            }
        }
        func uuid(_ name: String) throws -> UUID? {
            guard let string = try optionalText(name) else { return nil }
            guard let result = UUID(uuidString: string) else {
                throw RelayAuditImageError.invalidValue(name)
            }
            return result
        }
        let primaryKey = try integer("id")
        guard primaryKey > 0, source._managedPrimaryKey == primaryKey else {
            throw RelayAuditImageError.invalidValue("id")
        }
        let table = try text("tableName")
        guard let operation = Operation(rawValue: try text("operation")) else {
            throw RelayAuditImageError.invalidValue("operation")
        }
        let timestamp: Double
        switch try value("timestamp") {
        case .real(let number): timestamp = number
        case .int64(let number): timestamp = Double(number)
        default: throw RelayAuditImageError.wrongType("timestamp")
        }
        guard timestamp.isFinite else { throw RelayAuditImageError.invalidValue("timestamp") }
        let fields = try JSONDecoder().decode([String: AnyProperty].self,
                                             from: Data(try text("changedFields").utf8))
        let names = try optionalText("changedFieldsNames").map {
            try JSONDecoder().decode([String?].self, from: Data($0.utf8))
        }
        // Detached values own no database, keeper, or model registration.
        // The unchanged AuditLog Codable remains the wire authority.
        let result = AuditLog()
        result.primaryKey = primaryKey
        result.globalId = try uuid("globalId")
        result.tableName = table
        result.operation = operation
        result.rowId = try integer("rowId")
        result.globalRowId = try uuid("globalRowId")
        result.changedFields = fields
        result.changedFieldsNames = names
        result.timestamp = Date(timeIntervalSince1970: timestamp)
        result.isFromRemote = try integer("isFromRemote") != 0
        result.isSynchronized = try integer("isSynchronized") != 0
        return result
    }
}

extension Lattice {
    package func _relayAuditImagePage(after cursor: Int64, limit: Int64) throws -> [AuditLog] {
        let query = eventsAfter(id: cursor)
        guard backend._supportsQueryRowImages else {
            return query.snapshot(limit: limit) // Preserve unsupported-backend behavior.
        }
        var captured: Result<[AuditLog], any Swift.Error>?
        let ordinaryModels = query._snapshotCapturingRowImages(limit: limit) { rows in
            captured = Result { try rows.map { try AuditLog._fromRelayQueryImage($0) } }
        }
        defer { withExtendedLifetime(ordinaryModels) {} }
        guard let captured else {
            // Closed handles retain the original empty-snapshot behavior.
            if ordinaryModels.isEmpty { return [] }
            throw RelayAuditImageError.unavailable("page")
        }
        return try captured.get()
    }
}
