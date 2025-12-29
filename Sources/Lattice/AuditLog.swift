import Foundation

// Assuming your model macro handles persistence, mapping, etc.
@Model @Codable
public class AuditLog: CustomStringConvertible {
    @LatticeEnum public enum Operation: String, Codable, Sendable, CustomStringConvertible {
        case insert = "INSERT", update = "UPDATE", delete = "DELETE"
        
        public var description: String { rawValue }
    }

    public var description: String {
        do {
            return try String(data: JSONEncoder().encode(self), encoding: .utf8)!
        } catch {
            return "AuditLog(tableName: \(tableName), operation: \(operation), rowId: \(rowId), changedFields: \(changedFields), timestamp: \(timestamp), isFromRemote: \(isFromRemote))"
        }
    }
    
    /// Name of the affected table, e.g., "Person"
    package var tableName: String
    /// Operation type: "INSERT", "UPDATE", "DELETE", etc.
    public var operation: Operation = .insert
    /// The id of the record that was affected in the target table
    package var rowId: Int64
    /// The global id of the record that was affected in the target table
    var globalRowId: UUID?
    /// JSON string containing the changed fields (if any)
    var changedFields: [String: AnyProperty]
    /// JSON containing the names of the changes properties
    var changedFieldsNames: [String?]?
    /// Timestamp for when the change occurred
    var timestamp: Date
    /// Whether or not this event was propagated locally
    var isFromRemote: Bool
    /// WHether not this event has been synchronized
    package var isSynchronized: Bool = false
}

extension AuditLog {
    /// Returns raw SQL plus a list of AnyProperty to bind in-order.
    func generateInstruction() -> (sql: String, params: [AnyProperty]) {
        switch operation {
        case .insert:
            let cols   = ["globalId"] + changedFieldsNames!.compactMap { $0 }
            let props  = cols.map { changedFields[$0] ?? .string(globalRowId!.uuidString.lowercased()) }
            let names  = cols.joined(separator: ", ")
            let marks  = Array(repeating: "?", count: cols.count).joined(separator: ", ")
            let sql    = """
            INSERT INTO \(tableName)(\(names))
                VALUES (\(marks))
                ON CONFLICT(globalId) DO UPDATE
                  SET \(changedFields.keys.map{ "\($0)=excluded.\($0)" }.joined(separator: ", "));
            """
            return (sql, props)
            
        case .update:
            let cols   = changedFieldsNames!.compactMap { $0 }
            let props  = cols.map { changedFields[$0]! }
            let sets   = cols.map { "\($0) = ?" }.joined(separator: ", ")
            let sql    = "UPDATE \(tableName) SET \(sets) WHERE globalId = ?;"
            return (sql, props + [AnyProperty.string(globalRowId!.uuidString.lowercased())])  // append rowId as a param
            
        case .delete:
            let sql    = "DELETE FROM \(tableName) WHERE globalId = ?;"
            return (sql, [AnyProperty.string(globalRowId!.uuidString.lowercased())])
        }
    }
}
