import Foundation

// Optional ACK observation only. No native acceptance or publication authority.
// The caller supplies the same bytes to this scanner and its local shape view;
// neither the bytes nor that view survive in the returned observation.
struct RelayACKSyntax {
    static let byteLimit = 1_048_576
    static let eventLimit = 32_768
    static let scalarLimit = 65_536
    struct Field {
        var kind: Int64?
        var value: Int64?
    }
    struct Facts {
        var fields: [Data: Field] = [:]
        var version: Int64?
    }
    private enum Invalid: Error { case syntax }
    private enum Context {
        case root, audit, entry, fields, field(Data), identity, ignored
    }
    private let bytes: [UInt8]
    private var offset = 0, events = 0
    private var facts = Facts()

    init(_ data: Data) {
        // Check before copying the byte view, including on the pure test seam.
        bytes = !data.isEmpty && data.count <= Self.byteLimit ? Array(data) : []
    }
    mutating func scan() throws -> Facts {
        try check(!bytes.isEmpty && String(bytes: bytes, encoding: .utf8) != nil)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { offset = 3 }
        _ = try value(.root, depth: 0)
        whitespace(); try check(offset == bytes.count)
        return facts
    }
    private func check(_ condition: Bool) throws { if !condition { throw Invalid.syntax } }
    private mutating func event(_ depth: Int) throws {
        // Match native parser callbacks: starts, ends, keys and scalar values.
        try check(depth <= 16 && events < Self.eventLimit); events += 1
    }
    private mutating func whitespace() {
        while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
    }
    private mutating func consume(_ byte: UInt8) throws {
        try check(offset < bytes.count && bytes[offset] == byte); offset += 1
    }
    private func matches(_ key: Data, _ text: String) -> Bool { key.elementsEqual(text.utf8) }
    private func child(_ context: Context, _ key: Data) -> Context {
        switch context {
        case .root where matches(key, "auditLog"): return .audit
        case .entry where matches(key, "changedFields"): return .fields
        case .entry where matches(key, "originalIdentity"): return .identity
        case .fields: return .field(key)
        default: return .ignored
        }
    }
    private func observesInteger(_ context: Context, _ key: Data) -> Bool {
        switch context {
        case .field: return matches(key, "kind") || matches(key, "value")
        case .identity: return matches(key, "version")
        default: return false
        }
    }
    private mutating func value(_ context: Context, depth: Int, integer: Bool = false) throws -> Int64? {
        whitespace(); try event(depth); try check(offset < bytes.count)
        switch bytes[offset] {
        case 123:
            offset += 1; whitespace()
            if offset < bytes.count && bytes[offset] == 125 { offset += 1; try event(depth); return nil }
            var byteKeys = Set<Data>(), shapeKeys = Set<String>()
            while true {
                whitespace(); try event(depth + 1)
                let key = try string()
                // Data catches escaped duplicates by exact decoded bytes.
                // Also reject canonical Unicode aliases that Swift dictionary
                // equality would collapse in the subsequent Foundation view.
                let name = String(decoding: key, as: UTF8.self)
                try check(byteKeys.insert(key).inserted && shapeKeys.insert(name).inserted)
                if case .fields = context {
                    try check(facts.fields.count < 32); facts.fields[key] = Field()
                }
                whitespace(); try consume(58)
                let number = try value(child(context, key), depth: depth + 1,
                                       integer: observesInteger(context, key))
                switch context {
                case .field(let field):
                    if matches(key, "kind") { facts.fields[field]?.kind = number }
                    if matches(key, "value") { facts.fields[field]?.value = number }
                case .identity where matches(key, "version"): facts.version = number
                default: break
                }
                whitespace()
                if offset < bytes.count && bytes[offset] == 125 { offset += 1; try event(depth); return nil }
                try consume(44)
            }
        case 91:
            offset += 1; whitespace()
            if offset < bytes.count && bytes[offset] == 93 { offset += 1; try event(depth); return nil }
            var index = 0
            while true {
                let next: Context
                if case .audit = context, index == 0 { next = .entry } else { next = .ignored }
                _ = try value(next, depth: depth + 1); index += 1; whitespace()
                if offset < bytes.count && bytes[offset] == 93 { offset += 1; try event(depth); return nil }
                try consume(44)
            }
        case 34: _ = try string(); return nil
        case 116: try literal("true"); return nil
        case 102: try literal("false"); return nil
        case 110: try literal("null"); return nil
        default: return try number(observed: integer)
        }
    }
    private mutating func literal(_ text: String) throws { for byte in text.utf8 { try consume(byte) } }
    private mutating func number(observed: Bool) throws -> Int64? {
        let start = offset
        if bytes[offset] == 45 { offset += 1 }
        try check(offset < bytes.count)
        if bytes[offset] == 48 { offset += 1 }
        else {
            try check((49...57).contains(bytes[offset])); offset += 1
            while offset < bytes.count && (48...57).contains(bytes[offset]) { offset += 1 }
        }
        var integral = true
        if offset < bytes.count && bytes[offset] == 46 {
            integral = false; offset += 1; try digits()
        }
        if offset < bytes.count && (bytes[offset] == 101 || bytes[offset] == 69) {
            integral = false; offset += 1
            if offset < bytes.count && (bytes[offset] == 43 || bytes[offset] == 45) { offset += 1 }
            try digits()
        }
        // General legal numbers are skipped, never converted through Foundation.
        guard observed && integral && offset - start <= 20 else { return nil }
        let negative = bytes[start] == 45
        let limit = negative ? UInt64(Int64.max) + 1 : UInt64(Int64.max)
        var magnitude: UInt64 = 0
        for byte in bytes[(start + (negative ? 1 : 0))..<offset] {
            let digit = UInt64(byte - 48)
            guard magnitude <= (limit - digit) / 10 else { return nil }
            magnitude = magnitude * 10 + digit
        }
        if negative && magnitude == UInt64(Int64.max) + 1 { return Int64.min }
        return negative ? -Int64(magnitude) : Int64(magnitude)
    }
    private mutating func digits() throws {
        let start = offset
        while offset < bytes.count && (48...57).contains(bytes[offset]) { offset += 1 }
        try check(offset > start)
    }
    private mutating func hex4() throws -> UInt32 {
        var result: UInt32 = 0
        for _ in 0..<4 {
            try check(offset < bytes.count); let byte = bytes[offset]; offset += 1
            let digit: UInt32
            switch byte {
            case 48...57: digit = UInt32(byte - 48)
            case 65...70: digit = UInt32(byte - 55)
            case 97...102: digit = UInt32(byte - 87)
            default: throw Invalid.syntax
            }
            result = result * 16 + digit
        }
        return result
    }
    private mutating func string() throws -> Data {
        try consume(34); var result = Data()
        while offset < bytes.count {
            let byte = bytes[offset]; offset += 1
            if byte == 34 { return result }
            try check(byte >= 32)
            if byte != 92 {
                try check(result.count < Self.scalarLimit); result.append(byte)
            } else {
                try check(offset < bytes.count); let escaped = bytes[offset]; offset += 1
                let decoded: [UInt8]
                switch escaped {
                case 34, 47, 92: decoded = [escaped]
                case 98: decoded = [8]
                case 102: decoded = [12]
                case 110: decoded = [10]
                case 114: decoded = [13]
                case 116: decoded = [9]
                case 117:
                    var code = try hex4()
                    if (0xD800...0xDBFF).contains(code) {
                        try consume(92); try consume(117); let low = try hex4()
                        try check((0xDC00...0xDFFF).contains(low))
                        code = 0x10000 + (code - 0xD800) * 1024 + low - 0xDC00
                    } else { try check(!(0xDC00...0xDFFF).contains(code)) }
                    guard let scalar = UnicodeScalar(code) else { throw Invalid.syntax }
                    decoded = Array(String(scalar).utf8)
                default: throw Invalid.syntax
                }
                try check(decoded.count <= Self.scalarLimit - result.count); result.append(contentsOf: decoded)
            }
        }
        throw Invalid.syntax
    }
}
