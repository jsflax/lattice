import Foundation

// MARK: - DynamicQuery: JSON predicate -> validated SQL WHERE
//
// Translates a structured JSON predicate (the shape an MCP client sends) into a
// SQL WHERE fragment for `DynamicResults.where(_:)`. This is the security gate:
//
//   * Only same-named primitive columns without geo-bounds are admitted from
//     the reconstructed schema, plus id and globalId. Relationships and geo
//     properties use separate storage and cannot be compared as row columns.
//     Admitted identifiers are quoted so SQL keywords keep their column meaning.
//   * Operators are whitelisted — unknown operators throw.
//   * Operands must be JSON scalars; string literals use single-quote doubling.
//   * Empty $or matches no rows; empty $and matches all rows.
//
// Grammar (per field): { "<col>": <bareValue> } means equality, or
//   { "<col>": { "$op": operand } }. Logical: { "$and": [..] }, { "$or": [..] },
//   { "$not": {..} }. Multiple top-level keys are ANDed.
// Operators: $eq $ne $gt $gte $lt $lte $contains $hasPrefix $hasSuffix $in $between.

public enum DynamicQueryError: Error, CustomStringConvertible, Equatable {
    case unknownProperty(String)
    case unsupportedOperator(String)
    case malformed(String)

    public var description: String {
        switch self {
        case .unknownProperty(let p): return "unknown_property: '\(p)' is not a filterable scalar column of the model"
        case .unsupportedOperator(let o): return "unsupported_operator: '\(o)'"
        case .malformed(let m): return "invalid_predicate: \(m)"
        }
    }
}

public enum DynamicQuery {
    /// Comparison operators accepted inside a field predicate.
    public static let operators: Set<String> =
        ["$eq", "$ne", "$gt", "$gte", "$lt", "$lte",
         "$contains", "$hasPrefix", "$hasSuffix", "$in", "$between"]

    /// Translate a JSON `where` object into a validated SQL WHERE fragment.
    /// Filterable fields are primitive, non-geo row columns, plus `id` and `globalId`.
    /// Operands are String, number, Bool or NSNull; $in and $between take arrays
    /// of those scalars. Convert Swift-native values such as UUID to JSON first
    /// (for example, `uuid.uuidString`). Empty $or is false; empty $and is true.
    /// Throws `DynamicQueryError` on other columns, operators or malformed input.
    public static func whereSQL(_ predicate: [String: Any], schema: [PropertyInfo]) throws -> String {
        let allowed = Set(schema.filter { $0.kind == .primitive && !$0.isGeoBounds }.map { $0.name })
            .union(["id", "globalId"])
        var clauses: [String] = []
        for (key, value) in predicate {
            switch key {
            case "$and": clauses.append(try combine(value, separator: " AND ", schema: schema))
            case "$or":  clauses.append(try combine(value, separator: " OR ", schema: schema))
            case "$not":
                guard let obj = value as? [String: Any] else {
                    throw DynamicQueryError.malformed("$not expects an object")
                }
                clauses.append("NOT (\(try whereSQL(obj, schema: schema)))")
            default:
                guard allowed.contains(key) else { throw DynamicQueryError.unknownProperty(key) }
                let identifier = "\"" + key.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                clauses.append(try fieldClause(column: identifier, value: value))
            }
        }
        if clauses.isEmpty { return "1=1" }
        return clauses.map { "(\($0))" }.joined(separator: " AND ")
    }

    private static func combine(_ value: Any, separator: String, schema: [PropertyInfo]) throws -> String {
        guard let arr = value as? [Any] else {
            throw DynamicQueryError.malformed("logical operator expects an array of predicates")
        }
        let parts = try arr.map { element -> String in
            guard let obj = element as? [String: Any] else {
                throw DynamicQueryError.malformed("each predicate must be an object")
            }
            return "(\(try whereSQL(obj, schema: schema)))"
        }
        return parts.isEmpty ? (separator == " OR " ? "0=1" : "1=1") : parts.joined(separator: separator)
    }

    private static func fieldClause(column: String, value: Any) throws -> String {
        // { col: { $op: operand } } — one or more operators (ANDed).
        if let opObject = value as? [String: Any] {
            guard !opObject.isEmpty else {
                throw DynamicQueryError.malformed("field \(column): operator object cannot be empty")
            }
            let parts = try opObject.map { try opClause(column: column, op: $0.key, operand: $0.value) }
            return parts.joined(separator: " AND ")
        }
        // Bare value → equality (or IS NULL for null).
        try requireScalar(value, column: column, operation: "$eq")
        return eqClause(column: column, operand: value)
    }

    private static func opClause(column c: String, op: String, operand: Any) throws -> String {
        guard operators.contains(op) else { throw DynamicQueryError.unsupportedOperator(op) }
        if op != "$in" && op != "$between" {
            try requireScalar(operand, column: c, operation: op)
        }
        switch op {
        case "$eq":  return eqClause(column: c, operand: operand)
        case "$ne":  return (operand is NSNull) ? "\(c) IS NOT NULL" : "\(c) != \(lit(operand))"
        case "$gt":  return "\(c) > \(lit(operand))"
        case "$gte": return "\(c) >= \(lit(operand))"
        case "$lt":  return "\(c) < \(lit(operand))"
        case "$lte": return "\(c) <= \(lit(operand))"
        // Substring matches via instr/substr — avoids LIKE wildcard escaping.
        case "$contains":  return "instr(\(c), \(lit(operand))) > 0"
        case "$hasPrefix": return "substr(\(c), 1, length(\(lit(operand)))) = \(lit(operand))"
        case "$hasSuffix": return "substr(\(c), -length(\(lit(operand)))) = \(lit(operand))"
        case "$in":
            guard let arr = operand as? [Any] else { throw DynamicQueryError.malformed("field \(c): $in expects an array") }
            try arr.forEach { try requireScalar($0, column: c, operation: op) }
            let vals = arr.map { lit($0) }.joined(separator: ", ")
            return "\(c) IN (\(vals))"
        case "$between":
            guard let arr = operand as? [Any], arr.count == 2 else {
                throw DynamicQueryError.malformed("field \(c): $between expects [low, high]")
            }
            try arr.forEach { try requireScalar($0, column: c, operation: op) }
            return "\(c) BETWEEN \(lit(arr[0])) AND \(lit(arr[1]))"
        default:
            throw DynamicQueryError.unsupportedOperator(op)
        }
    }

    private static func eqClause(column c: String, operand: Any) -> String {
        (operand is NSNull) ? "\(c) IS NULL" : "\(c) = \(lit(operand))"
    }

    private static func requireScalar(_ value: Any, column: String, operation: String) throws {
        guard value is NSNull || value is String || value is NSNumber else {
            throw DynamicQueryError.malformed("field \(column): \(operation) operands must be scalar JSON values")
        }
    }

    /// Render a JSON scalar as an escaped SQL literal.
    private static func lit(_ v: Any) -> String {
        switch v {
        case is NSNull:        return "NULL"
        case let b as Bool:    return b ? "1" : "0"
        case let i as Int:     return String(i)
        case let i as Int64:   return String(i)
        case let d as Double:  return String(d)
        case let s as String:  return "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
        case let n as NSNumber: return n.stringValue
        default:
            preconditionFailure("SQL literals require a validated JSON scalar")
        }
    }
}
