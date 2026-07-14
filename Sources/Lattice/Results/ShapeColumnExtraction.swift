import Foundation

// MARK: - Referenced-column extraction (item A Commit 8, §2.3 v1.1)
//
// The changedFields skip may suppress a shape's cache invalidation ONLY when
// an UPDATE-only batch's changed fields are provably disjoint from every
// column the shape's membership/order depends on: the predicate columns
// (`whereSQL`), the sort columns (`orderBySQL`), group/distinct columns, and
// the implicit `id` tiebreaker (§2.4). Extraction is CONSERVATIVE by
// construction — the two failure directions are asymmetric:
//
//   * an EXTRA name in the referenced set costs one unnecessary rebuild
//     (correct, slower) — so ambiguous identifiers are always included;
//   * a MISSING name is a silently stale cache (a correctness bug) — so any
//     fragment the tokenizer cannot classify with confidence collapses the
//     whole shape to `.mustInvalidate` (v1 whole-table behavior).
//
// Concretely: quoted (`"c"`, `` `c` ``, `[c]`) and unquoted identifiers are
// collected; function names (`ident(`) are excluded but their arguments are
// walked normally ("functions over columns are fine — the columns count as
// referenced"); qualified names (`Table.col`) contribute BOTH parts (the
// qualifier is a table, not a column — extra-name safe); operator keywords
// that SQLite also permits as identifiers (LIKE/GLOB/REGEXP/MATCH/ESCAPE)
// are dual-booked as referenced names. Subquery/statement keywords
// (SELECT, EXISTS, FROM, …), string/identifier quoting the scanner cannot
// terminate, the bbox shape marker (\u{1F}, §4.5 carve-out), and any
// character outside the recognized SQL surface all yield `.mustInvalidate`.

/// What a query shape's membership/order depends on, for the Commit-8
/// disjointness test. Computed once per registered shape (never in the
/// invalidation hook frame — §2.3).
enum ShapeColumnDependency: Equatable, Sendable {
    /// Lowercased referenced-column names; always contains `"id"` (the
    /// implicit deterministic-order tiebreaker, §2.4). An UPDATE-only batch
    /// whose changed fields are disjoint from this set cannot change the
    /// shape's membership or order.
    case columns(Set<String>)
    /// Extraction could not classify the shape's SQL with confidence —
    /// every write to the table invalidates (v1 baseline).
    case mustInvalidate
}

enum ShapeColumnExtractor {

    /// The full dependency of one shape key: predicate ∪ sort ∪ group ∪
    /// distinct ∪ {id}. Any unparseable component ⇒ `.mustInvalidate`.
    static func dependency(of key: QueryShapeKey) -> ShapeColumnDependency {
        var referenced: Set<String> = ["id"]
        for fragment in [key.whereSQL, key.orderBySQL, key.groupBy, key.distinctBy] {
            guard let fragment else { continue }
            guard let columns = referencedColumns(in: fragment) else {
                return .mustInvalidate
            }
            referenced.formUnion(columns)
        }
        return .columns(referenced)
    }

    /// Statement-level / subquery keywords: their presence means the
    /// fragment references data this scanner cannot attribute to columns of
    /// the shape's own table — bail to must-invalidate.
    private static let abortKeywords: Set<String> = [
        "SELECT", "EXISTS", "FROM", "WHERE", "UNION", "INTERSECT", "EXCEPT",
        "JOIN", "WITH", "VALUES", "PRAGMA", "ATTACH", "DETACH", "INSERT",
        "UPDATE", "DELETE", "ORDER", "GROUP", "HAVING", "LIMIT", "OFFSET",
    ]

    /// Pure operator/expression keywords — never column references in the
    /// predicate grammar the query builders emit.
    private static let operatorKeywords: Set<String> = [
        "AND", "OR", "NOT", "IS", "IN", "NULL", "BETWEEN", "CASE", "WHEN",
        "THEN", "ELSE", "END", "CAST", "AS", "COLLATE", "ASC", "DESC",
        "TRUE", "FALSE", "CURRENT_TIME", "CURRENT_DATE", "CURRENT_TIMESTAMP",
        "DISTINCT", "BY",
    ]

    /// Keywords SQLite is lenient enough to also accept as bare identifiers
    /// in expression positions: skipped as operators AND booked as
    /// referenced names (extra-name safe; a genuine column of that name is
    /// never missed).
    private static let dualUseKeywords: Set<String> = [
        "LIKE", "GLOB", "REGEXP", "MATCH", "ESCAPE",
    ]

    /// Conservatively tokenize one SQL fragment (a WHERE predicate, an
    /// ORDER BY list, or a bare column name) and collect every identifier
    /// that could be a column reference, lowercased. `nil` = the fragment
    /// contains something this scanner does not understand with confidence
    /// (subquery, unterminated literal, the bbox marker, foreign syntax) —
    /// the caller must fall back to must-invalidate.
    static func referencedColumns(in fragment: String) -> Set<String>? {
        var columns: Set<String> = []
        let scalars = Array(fragment.unicodeScalars)
        var i = 0
        let n = scalars.count

        func isIdentifierStart(_ c: Unicode.Scalar) -> Bool {
            (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c == "_"
        }
        func isIdentifierBody(_ c: Unicode.Scalar) -> Bool {
            isIdentifierStart(c) || (c >= "0" && c <= "9") || c == "$"
        }
        func isDigit(_ c: Unicode.Scalar) -> Bool { c >= "0" && c <= "9" }
        /// Next non-whitespace scalar at/after `index`, or nil.
        func nextMeaningful(after index: Int) -> Unicode.Scalar? {
            var j = index
            while j < n {
                let c = scalars[j]
                if c == " " || c == "\t" || c == "\n" || c == "\r" { j += 1; continue }
                return c
            }
            return nil
        }
        /// Scan a quoted region starting at `i` (opening delimiter), with
        /// `close` as the terminator, doubling as the escape (`''`, `""`).
        /// Returns the contents, advancing `i` past the closer; nil =
        /// unterminated.
        func scanQuoted(close: Unicode.Scalar, allowsDoubling: Bool) -> String? {
            var j = i + 1
            var content = String.UnicodeScalarView()
            while j < n {
                let c = scalars[j]
                if c == close {
                    if allowsDoubling, j + 1 < n, scalars[j + 1] == close {
                        content.append(c)
                        j += 2
                        continue
                    }
                    i = j + 1
                    return String(content)
                }
                content.append(c)
                j += 1
            }
            return nil
        }

        while i < n {
            let c = scalars[i]
            switch c {
            case " ", "\t", "\n", "\r":
                i += 1
            case "'":
                // String literal — contents are values, not columns.
                guard scanQuoted(close: "'", allowsDoubling: true) != nil else { return nil }
            case "\"":
                // Standard-SQL quoted identifier.
                guard let name = scanQuoted(close: "\"", allowsDoubling: true) else { return nil }
                columns.insert(name.lowercased())
            case "`":
                guard let name = scanQuoted(close: "`", allowsDoubling: true) else { return nil }
                columns.insert(name.lowercased())
            case "[":
                // Bracket-quoted identifier (no doubling escape in SQLite).
                guard let name = scanQuoted(close: "]", allowsDoubling: false) else { return nil }
                columns.insert(name.lowercased())
            case "?":
                // Positional parameter (optionally numbered).
                i += 1
                while i < n, isDigit(scalars[i]) { i += 1 }
            case ":", "@", "$":
                // Named parameter — the following identifier is a binding
                // name, not a column. A bare sigil is foreign syntax.
                i += 1
                guard i < n, isIdentifierStart(scalars[i]) else { return nil }
                while i < n, isIdentifierBody(scalars[i]) { i += 1 }
            case "=", "<", ">", "!", "+", "-", "*", "/", "%", "(", ")", ",",
                 "|", "&", "~", ".":
                // Operators / punctuation. `.` also covers qualified names —
                // both sides are collected as identifiers (extra-name safe).
                i += 1
            default:
                if isDigit(c) {
                    // Numeric literal (integer, real, exponent, hex). Consume
                    // the alphanumeric run — malformed SQL would not have
                    // survived the backend anyway; nothing here is emitted.
                    i += 1
                    while i < n, isIdentifierBody(scalars[i]) || scalars[i] == "." { i += 1 }
                } else if isIdentifierStart(c) {
                    var j = i
                    var name = String.UnicodeScalarView()
                    while j < n, isIdentifierBody(scalars[j]) {
                        name.append(scalars[j])
                        j += 1
                    }
                    i = j
                    let word = String(name)
                    let upper = word.uppercased()
                    if abortKeywords.contains(upper) { return nil }
                    if dualUseKeywords.contains(upper) {
                        columns.insert(word.lowercased())
                    } else if !operatorKeywords.contains(upper) {
                        // A column reference is never immediately followed
                        // by `(` — that form is a function call; its NAME is
                        // excluded, its arguments are walked normally.
                        if nextMeaningful(after: i) != "(" {
                            columns.insert(word.lowercased())
                        }
                    }
                } else {
                    // Anything else — including the \u{1F} bbox shape marker
                    // (§4.5 carve-out) — is outside the understood surface.
                    return nil
                }
            }
        }
        return columns
    }
}
