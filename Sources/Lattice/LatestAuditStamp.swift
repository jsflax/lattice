import Foundation

extension Lattice {
    /// The global audit ID of the latest surviving entry for one exact row owner. This is local
    /// version evidence, not authorization. A missing entry returns nil; malformed metadata,
    /// unsupported backends, query failure and an intervening audit change throw.
    ///
    /// Uses scalar grouped queries on the existing owned read/transaction route. Only a bounded
    /// table-name key, a UUID key and counts cross the backend; no audit payload is hydrated.
    /// Callers composing this with other reads must also retain their original auditReadFence.
    public func latestAuditStamp(tableName: String, globalRowID: UUID) throws -> UUID? {
        try _latestAuditStamp(tableName: tableName, globalRowID: globalRowID)
    }

    // Internal deterministic inter-query checkpoint for the real-store race fixture. The public
    // route supplies no callback, and the final fence applies equally to both routes.
    func _latestAuditStamp(tableName: String, globalRowID: UUID,
                          betweenQueries: (() throws -> Void)? = nil) throws -> UUID? {
        guard !tableName.isEmpty, tableName.utf8.count <= 128, !tableName.utf8.contains(0),
              let reader = backend as? any GroupedCountBackend else {
            throw Lattice.Error.databaseError("Invalid or unsupported latest audit stamp request")
        }
        let fence = try auditReadFence()
        let owner: [QueryParameter] = [.text(tableName), .text(globalRowID.uuidString.lowercased())]
        let selection = """
            tableName = ? AND globalRowId = ? AND id =
              (SELECT max(id) FROM main.AuditLog WHERE tableName = ? AND globalRowId = ?)
            """
        let params = owner + owner
        // Selecting the known exact table name first distinguishes absence from an invalid UUID.
        // It also refuses a malformed/nonunique latest ID before the UUID grouping can allocate
        // more than one result. Every parameter is bound, including tableName (never SQL syntax).
        let selected = try reader.groupedCounts(table: "AuditLog", groupBy: "tableName",
            where: selection, distinctBy: nil, params: params)
        guard selected.isEmpty || selected == [GroupedCount(key: tableName, count: 1)] else {
            throw Lattice.Error.databaseError("Ambiguous latest audit stamp")
        }
        try betweenQueries?()
        let valid = """
            typeof(id) = 'integer' AND id > 0 AND typeof(globalId) = 'text'
            AND length(CAST(globalId AS BLOB)) = 36 AND length(globalId) = 36
            AND substr(globalId,9,1) = '-' AND substr(globalId,14,1) = '-'
            AND substr(globalId,19,1) = '-' AND substr(globalId,24,1) = '-'
            AND length(replace(globalId,'-','')) = 32
            AND lower(replace(globalId,'-','')) NOT GLOB '*[^0-9a-f]*'
            """
        // All selected variable columns are bounded in the statement that returns them. Extra
        // physical columns are harmless here: groupedCounts explicitly selects key and count,
        // never SELECT *. The count guard remains in this statement, not only the earlier read.
        let stamps = try reader.groupedCounts(table: "AuditLog", groupBy: "globalId",
            where: "(\(selection)) AND (\(valid)) AND (SELECT count(*) FROM main.AuditLog WHERE \(selection)) <= 1",
            distinctBy: nil, params: params + params)
        guard try auditReadFence() == fence else {
            throw Lattice.Error.databaseError("Audit history changed during latest stamp capture")
        }
        if selected.isEmpty {
            guard stamps.isEmpty else { throw Lattice.Error.databaseError("Audit owner appeared during stamp capture") }
            return nil
        }
        guard stamps.count == 1, stamps[0].count == 1, let stamp = UUID(uuidString: stamps[0].key) else {
            throw Lattice.Error.databaseError("Invalid latest audit stamp metadata")
        }
        return stamp
    }
}
