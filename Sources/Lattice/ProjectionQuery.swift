import Foundation
import Dispatch

/// Explicit bounds for one projected read. No workload-dependent defaults are
/// inferred. The timeout covers the entire operation, including queue wait.
public struct ProjectionReadLimits: Sendable, Equatable {
    public let maxRows: Int
    public let maxBytes: Int
    public let timeout: TimeInterval
    private let timeoutNanoseconds: UInt64

    public init(maxRows: Int, maxBytes: Int, timeout: TimeInterval) throws {
        guard maxRows > 0 else { throw ProjectionReadError.invalidRequest("maxRows must be positive") }
        guard maxBytes > 0 else { throw ProjectionReadError.invalidRequest("maxBytes must be positive") }
        guard timeout.isFinite, timeout > 0 else {
            throw ProjectionReadError.invalidRequest("timeout must be finite and positive")
        }
        let nanoseconds = (timeout * 1_000_000_000).rounded(.up)
        // Double(UInt64.max) rounds UP to 2^64; use a strict bound before
        // conversion, never a saturating cast that silently removes a limit.
        guard nanoseconds.isFinite, nanoseconds >= 1, nanoseconds < Double(UInt64.max) else {
            throw ProjectionReadError.invalidRequest("timeout exceeds monotonic clock representation")
        }
        self.maxRows = maxRows
        self.maxBytes = maxBytes
        self.timeout = timeout
        timeoutNanoseconds = UInt64(nanoseconds)
    }

    func deadline(startingAt uptimeNanoseconds: UInt64) throws -> UInt64 {
        let (deadline, overflow) = uptimeNanoseconds.addingReportingOverflow(timeoutNanoseconds)
        guard !overflow else { throw ProjectionReadError.invalidRequest("monotonic deadline overflow") }
        return deadline
    }
}

/// Failure is distinct from a successful empty result. Scalar conversion
/// failures retain their separate `ProjectionDecodingError` type.
public enum ProjectionReadError: Error, Sendable, Equatable {
    case invalidRequest(String)
    case unsupportedShape(String)
    case invalidField(String)
    case cancelled
    case deadlineExceeded
    case rowBudgetExceeded
    case byteBudgetExceeded
    case snapshotExpired
    case schemaChanged
    case resourceBusy
    case executorStopped
    case database(String)
}

/// Model schema names copied as values; this is not a cached inspection of an
/// on-disk database. The eventual execution lease must validate schema/topology.
struct ProjectionStoredSchema: Sendable, Equatable {
    let table: String
    let declaredColumns: Set<String>
    let scalarColumns: Set<String>
    let boundsColumns: Set<String>

    init<M: Model>(_ model: M.Type) throws {
        try Self.validateIdentifier(model.entityName)
        table = model.entityName
        var declared: Set<String> = ["id", "globalId"]
        var scalar: Set<String> = ["id", "globalId"]
        var bounds: Set<String> = []
        for (column, type) in model.properties {
            try Self.validateIdentifier(column)
            declared.insert(column)
            if type is any ProjectionScalar.Type { scalar.insert(column) }
            if type is any GeoboundsProperty.Type { bounds.insert(column) }
        }
        declaredColumns = declared
        scalarColumns = scalar
        boundsColumns = bounds
    }

    /// SQL identifier quoting belongs to the SQL builder. Schema-backed names
    /// may contain spaces/Unicode; embedded NUL cannot be represented faithfully.
    private static func validateIdentifier(_ name: String) throws {
        guard !name.isEmpty, !name.utf8.contains(0) else {
            throw ProjectionReadError.invalidField("empty or NUL-containing schema name")
        }
    }

    func requireScalar(_ column: String) throws {
        guard scalarColumns.contains(column) else { throw ProjectionReadError.invalidField(column) }
    }

    func column<M: Model, Value: ProjectionScalar>(for keyPath: KeyPath<M, Value>, on model: M.Type) throws -> String {
        guard model.entityName == table, let column = model._storedColumn(for: keyPath) else {
            throw ProjectionReadError.invalidField("key path is not a stored scalar field")
        }
        try requireScalar(column)
        return column
    }
}

struct ProjectionSort: Sendable, Equatable {
    enum Direction: Sendable, Equatable { case ascending, descending }
    let column: String
    let direction: Direction
}

/// An immutable capture of a TableResults query; capturing does not execute it.
/// Every field is Sendable, including the existing backend protocol reference.
/// Unknown predicate dependencies remain unknown, not silently "validated" SQL.
struct ProjectionQueryDescriptor: Sendable {
    let backend: any LatticeBackend
    let schema: ProjectionStoredSchema
    let whereSQL: String?
    let bindings: [ColumnValue]
    /// Known schema-backed dependencies, or nil when the conservative scanner
    /// cannot classify the expression. This is metadata, not SQL authorization.
    let predicateColumns: Set<String>?
    let sort: ProjectionSort?
    let orderBySQL: String
    let bounds: BoundsConstraintParam?
    let groupBy: String?
    let distinctBy: String?
    let fetchLimit: Int?
    let hasAttachedStores: Bool

    init(backend: any LatticeBackend, schema: ProjectionStoredSchema,
         whereSQL: String?, parameters: [QueryParameter], sort: ProjectionSort?,
         orderBySQL: String, bounds: BoundsConstraintParam?, groupBy: String?,
         distinctBy: String?, fetchLimit: Int?, hasAttachedStores: Bool) throws {
        if let sort { try schema.requireScalar(sort.column) }
        if let groupBy { try schema.requireScalar(groupBy) }
        if let distinctBy { try schema.requireScalar(distinctBy) }
        if let fetchLimit, fetchLimit < 0 {
            throw ProjectionReadError.invalidRequest("fetchLimit must not be negative")
        }
        if let bounds {
            guard schema.boundsColumns.contains(bounds.column) else {
                throw ProjectionReadError.invalidField(bounds.column)
            }
            guard bounds.minLat.isFinite, bounds.maxLat.isFinite,
                  bounds.minLon.isFinite, bounds.maxLon.isFinite,
                  bounds.minLat <= bounds.maxLat, bounds.minLon <= bounds.maxLon else {
                throw ProjectionReadError.invalidRequest("bounds must be finite and ordered")
            }
        }
        self.backend = backend
        self.schema = schema
        self.whereSQL = whereSQL
        self.bindings = parameters.map { parameter in
            switch parameter {
            case .null: return .null
            case .integer(let value): return .int64(value)
            case .real(let value): return .real(value)
            case .text(let value): return .text(value)
            case .blob(let value): return .blob(value)
            }
        }
        self.predicateColumns = Self.dependencies(whereSQL, schema: schema)
        self.sort = sort
        self.orderBySQL = orderBySQL
        self.bounds = bounds
        self.groupBy = groupBy
        self.distinctBy = distinctBy
        self.fetchLimit = fetchLimit
        self.hasAttachedStores = hasAttachedStores
    }

    private static func dependencies(_ sql: String?, schema: ProjectionStoredSchema) -> Set<String>? {
        guard let sql else { return [] }
        guard let scanned = ShapeColumnExtractor.referencedColumns(in: sql) else { return nil }
        let known = Set(schema.declaredColumns.map { $0.lowercased() })
        // The scanner deliberately over-counts qualifiers/operator identifiers.
        // An unknown result must not become false proof that SQL is valid.
        let columns = scanned.subtracting([schema.table.lowercased()])
        return columns.isSubset(of: known) ? columns : nil
    }
}

/// Internal request values for the forthcoming executor, not a public raw-SQL
/// interface. Selected columns retain caller order (and intentional duplicates).
struct ProjectionReadRequest: Sendable {
    let descriptor: ProjectionQueryDescriptor
    let selectedColumns: [String]
    let limits: ProjectionReadLimits
    let operationID: UUID
    let effectiveLimit: Int?
    /// One absolute monotonic deadline shared by submission and every batch.
    let deadlineNanoseconds: UInt64

    init(descriptor: ProjectionQueryDescriptor, selectedColumns: [String],
         limits: ProjectionReadLimits, limit: Int? = nil, operationID: UUID = UUID()) throws {
        let started = DispatchTime.now().uptimeNanoseconds
        guard !selectedColumns.isEmpty else {
            throw ProjectionReadError.invalidRequest("select at least one scalar field")
        }
        if let limit, limit < 0 { throw ProjectionReadError.invalidRequest("limit must not be negative") }
        for column in selectedColumns { try descriptor.schema.requireScalar(column) }
        self.descriptor = descriptor
        self.selectedColumns = selectedColumns
        self.limits = limits
        self.operationID = operationID
        switch (descriptor.fetchLimit, limit) {
        case (.some(let cap), .some(let explicit)): effectiveLimit = min(cap, explicit)
        case (.some(let cap), .none): effectiveLimit = cap
        case (.none, .some(let explicit)): effectiveLimit = explicit
        case (.none, .none): effectiveLimit = nil
        }
        // maxRows is an error-producing budget, never an implicit LIMIT.
        deadlineNanoseconds = try limits.deadline(startingAt: started)
    }
}
