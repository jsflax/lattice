import Foundation

// MARK: - JV: the corpus value domain
//
// The conformance corpus is authored in the JSON subset of YAML, so the
// runner's whole value domain is JSON: null / bool / int / double / string /
// array / object. `JV` is the canonical in-memory form — Foundation's
// JSONSerialization output is normalized into it once at load, and every
// value read back from Lattice is canonicalized into it for comparison
// (bytes become {"$hex": "..."} objects, exactly as the corpus spells them).

enum JV: Hashable, CustomStringConvertible, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JV])
    case object([String: JV])

    init(json: Any) throws {
        switch json {
        case is NSNull:
            self = .null
        case let n as NSNumber:
            // Bool-vs-number discrimination differs per platform:
            // CFBoolean type-id on Darwin; corelibs-foundation encodes JSON
            // booleans as NSNumber with objCType "c" on Linux.
            #if canImport(Darwin)
            let isBool = CFGetTypeID(n) == CFBooleanGetTypeID()
            #else
            let isBool = String(cString: n.objCType) == "c"
            #endif
            if isBool {
                self = .bool(n.boolValue)
            } else {
                switch String(cString: n.objCType) {
                case "f", "d": self = .double(n.doubleValue)
                default: self = .int(n.int64Value)
                }
            }
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            self = .array(try a.map { try JV(json: $0) })
        case let o as [String: Any]:
            self = .object(try o.mapValues { try JV(json: $0) })
        default:
            throw ConformanceError.corpus("unsupported JSON value: \(json)")
        }
    }

    var description: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return "\(b)"
        case .int(let i): return "\(i)"
        case .double(let d): return "\(d)"
        case .string(let s): return "\"\(s)\""
        case .array(let a): return "[\(a.map(\.description).joined(separator: ", "))]"
        case .object(let o):
            let body = o.keys.sorted().map { "\"\($0)\": \(o[$0]!.description)" }
            return "{\(body.joined(separator: ", "))}"
        }
    }

    // MARK: typed accessors (throwing — an unexpected shape is a corpus bug)

    var isNull: Bool { self == .null }

    func requireInt() throws -> Int64 {
        guard case .int(let i) = self else { throw ConformanceError.corpus("expected int, got \(self)") }
        return i
    }

    func requireDouble() throws -> Double {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: throw ConformanceError.corpus("expected double, got \(self)")
        }
    }

    func requireBool() throws -> Bool {
        guard case .bool(let b) = self else { throw ConformanceError.corpus("expected bool, got \(self)") }
        return b
    }

    func requireString() throws -> String {
        guard case .string(let s) = self else { throw ConformanceError.corpus("expected string, got \(self)") }
        return s
    }

    func requireArray() throws -> [JV] {
        guard case .array(let a) = self else { throw ConformanceError.corpus("expected array, got \(self)") }
        return a
    }

    func requireObject() throws -> [String: JV] {
        guard case .object(let o) = self else { throw ConformanceError.corpus("expected object, got \(self)") }
        return o
    }

    subscript(_ key: String) -> JV? {
        guard case .object(let o) = self else { return nil }
        return o[key]
    }

    /// `{"$hex": "cafef00d"}` → Data
    func requireBytes() throws -> Data {
        guard let hex = self["$hex"] else { throw ConformanceError.corpus("expected {\"$hex\"}, got \(self)") }
        let s = try hex.requireString()
        guard s.count % 2 == 0 else { throw ConformanceError.corpus("odd-length hex: \(s)") }
        var data = Data(capacity: s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let byte = UInt8(s[idx..<next], radix: 16) else {
                throw ConformanceError.corpus("bad hex: \(s)")
            }
            data.append(byte)
            idx = next
        }
        return data
    }

    static func bytes(_ data: Data) -> JV {
        .object(["$hex": .string(data.map { String(format: "%02x", $0) }.joined())])
    }

    /// Multiset equality for `"unordered": true` row assertions.
    static func multisetEqual(_ a: [JV], _ b: [JV]) -> Bool {
        guard a.count == b.count else { return false }
        var counts: [JV: Int] = [:]
        for x in a { counts[x, default: 0] += 1 }
        for y in b {
            guard let c = counts[y], c > 0 else { return false }
            counts[y] = c - 1
        }
        return true
    }
}

// MARK: - Errors

enum ConformanceError: Error, CustomStringConvertible {
    /// The corpus itself is malformed / uses vocabulary this runner does not
    /// know. Always a hard failure — never a skip (spec: unknown vocabulary
    /// must not silently under-test).
    case corpus(String)
    /// A scenario assertion failed.
    case failed(String)

    var description: String {
        switch self {
        case .corpus(let m): return "corpus error: \(m)"
        case .failed(let m): return "FAILED: \(m)"
        }
    }
}

/// Thrown by the `abort` op inside a `transaction` block; the transaction
/// catches it after the SDK rolls back.
struct ConformanceAbort: Error {}
