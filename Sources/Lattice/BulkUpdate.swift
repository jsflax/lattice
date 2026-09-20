import Foundation

/// A validated batch mutation failed. The complete checked transaction rolls
/// back, including earlier chunks and writes in the enclosing closure.
public enum BulkUpdateError: Error, Sendable, Equatable {
    case invalidField(String)
    case invalidValue(String)
    case duplicateField(String)
    case invalidTarget(String)
    case requiresCheckedTransaction
    case unsupportedBackend
    case database(String)
}

/// Backend-neutral operations applied uniformly to selected managed rows.
/// The Core validates columns, physical ownership, existence and overflow.
public enum BulkMutationOperation: Sendable {
    case setDate(column: String, epochSeconds: Double)
    case incrementInt64(column: String, delta: Int64)
}

/// A typed field change for ``Lattice/bulkUpdate(_:changes:isolation:)``.
/// This initial surface supports timestamps and atomic integer counters.
/// Duplicate changes to one field are rejected instead of reordered.
public struct FieldUpdate<Element: Model>: Sendable {
    private enum Change: Sendable {
        case date(Double)
        case integer(Int64)
    }

    private let column: String?
    private let change: Change

    public static func set(_ field: KeyPath<Element, Date>, to value: Date) -> Self {
        .init(column: Element._storedColumn(for: field),
              change: .date(value.timeIntervalSince1970))
    }

    public static func increment(_ field: KeyPath<Element, Int>, by delta: Int = 1) -> Self {
        .init(column: Element._storedColumn(for: field), change: .integer(Int64(delta)))
    }

    public static func increment(_ field: KeyPath<Element, Int64>, by delta: Int64 = 1) -> Self {
        .init(column: Element._storedColumn(for: field), change: .integer(delta))
    }

    fileprivate func validated() throws -> (String, BulkMutationOperation) {
        guard let column, column != "id", column != "globalId",
              let property = Element.properties.first(where: { $0.0 == column })?.1 else {
            throw BulkUpdateError.invalidField(column ?? "key path is not a stored field")
        }
        switch change {
        case .date(let seconds):
            guard property is Date.Type else { throw BulkUpdateError.invalidField(column) }
            guard seconds.isFinite else { throw BulkUpdateError.invalidValue(column) }
            return (column, .setDate(column: column, epochSeconds: seconds))
        case .integer(let delta):
            guard property is Int.Type || property is Int64.Type else {
                throw BulkUpdateError.invalidField(column)
            }
            return (column, .incrementInt64(column: column, delta: delta))
        }
    }
}

extension Lattice {
    /// Apply timestamp sets and atomic integer increments to selected rows.
    /// Repeated references to the same physical row update it once. Inputs
    /// must belong to this handle; selecting replicas of the same global ID
    /// in different stores is ambiguous and fails before writing.
    ///
    /// Owns a checked transaction, or joins this handle's current synchronous
    /// `withTransaction` closure. Any failure is sticky in the outer closure,
    /// even if caught there. Legacy manually opened transactions are rejected.
    /// Explicitly materialized models keep their old values until refreshed;
    /// live properties read the committed updates normally.
    @discardableResult
    public func bulkUpdate<Element: Model>(
        _ targets: [Element],
        changes: [FieldUpdate<Element>],
        isolation: isolated (any Actor)? = #isolation
    ) throws -> Int {
        do {
            var columns = Set<String>()
            var operations: [BulkMutationOperation] = []
            operations.reserveCapacity(changes.count)
            for change in changes {
                let (column, operation) = try change.validated()
                guard columns.insert(column).inserted else {
                    throw BulkUpdateError.duplicateField(column)
                }
                operations.append(operation)
            }
            guard !targets.isEmpty, !operations.isEmpty else { return 0 }
            let rows = targets.map { $0._dynamicObject._ref }
            let ownsTransaction = Self._threadHoldsExplicitTransaction(identityHash: backend.identityHash)
            if TransactionFailureScope.isActive {
                guard ownsTransaction, TransactionFailureScope.isOwned(by: backend.identityHash) else {
                    throw BulkUpdateError.requiresCheckedTransaction
                }
                return try backend.applySelectedMutations(rows, operations: operations)
            }
            guard !ownsTransaction else { throw BulkUpdateError.requiresCheckedTransaction }
            return try withTransaction {
                try backend.applySelectedMutations(rows, operations: operations)
            }
        } catch {
            // Preserve failures occurring before or after a bridge call. A
            // later successful getter must not make a partial batch commit.
            TransactionFailureScope.record(String(describing: error))
            throw error
        }
    }
}
