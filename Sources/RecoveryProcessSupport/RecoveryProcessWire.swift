import Foundation

/// Closed test protocol; canonical bytes are also the saved-configuration identity.
/// This parser/commitment never grants source or receiver authority.
public enum RecoveryProcessCodec {
    public static let maximumMessage = 65_536
    public static func text(_ text: String, cap: Int) -> Bool {
        !text.isEmpty && text.utf8.count <= cap && !text.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
    public static func uuid(_ text: String) -> Bool { UUID(uuidString: text)?.uuidString.lowercased() == text }
    public static func digest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard !data.isEmpty, data.count <= maximumMessage else { throw RecoveryProcessFailure.bounds }
        return data
    }
    public static func decode<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
        guard !data.isEmpty, data.count <= maximumMessage else { throw RecoveryProcessFailure.bounds }
        var scanner = Syntax(bytes: Array(data)); try scanner.validate()
        do {
            let result = try JSONDecoder().decode(type, from: data)
            // Reject unknown fields, omitted required members, noncanonical
            // UUID/base64 spellings and integer coercions as well as syntax.
            guard try encode(result) == data else { throw RecoveryProcessFailure.syntax }
            return result
        } catch { throw RecoveryProcessFailure.syntax }
    }
    public static func frame(_ payload: Data) throws -> Data {
        guard !payload.isEmpty, payload.count <= maximumMessage else { throw RecoveryProcessFailure.bounds }
        let count = UInt32(payload.count)
        return Data([UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)]) + payload
    }
    private struct Syntax {
        let bytes: [UInt8]
        var index = 0, nodes = 0
        mutating func validate() throws {
            try value(0); guard index == bytes.count else { throw RecoveryProcessFailure.syntax }
        }
        mutating func take(_ byte: UInt8) throws {
            guard index < bytes.count, bytes[index] == byte else { throw RecoveryProcessFailure.syntax }; index += 1
        }
        mutating func value(_ depth: Int) throws {
            nodes += 1
            guard depth <= 16, nodes <= 4096, index < bytes.count else { throw RecoveryProcessFailure.bounds }
            switch bytes[index] {
            case 123:
                index += 1; var keys = Set<String>()
                if index < bytes.count, bytes[index] == 125 { index += 1; return }
                while true {
                    let key = try string()
                    guard keys.count < 32, keys.insert(key).inserted else { throw RecoveryProcessFailure.syntax }
                    try take(58); try value(depth + 1)
                    guard index < bytes.count else { throw RecoveryProcessFailure.syntax }
                    if bytes[index] == 125 { index += 1; return }; try take(44)
                }
            case 91:
                index += 1; var count = 0
                if index < bytes.count, bytes[index] == 93 { index += 1; return }
                while true {
                    guard count < 256 else { throw RecoveryProcessFailure.bounds }; count += 1
                    try value(depth + 1); guard index < bytes.count else { throw RecoveryProcessFailure.syntax }
                    if bytes[index] == 93 { index += 1; return }; try take(44)
                }
            case 34: _ = try string()
            case 116: try literal("true")
            case 102: try literal("false")
            case 110: try literal("null")
            case 45, 48...57:
                let start = index
                if bytes[index] == 45 { index += 1 }
                guard index < bytes.count else { throw RecoveryProcessFailure.syntax }
                if bytes[index] == 48 { index += 1 }
                else {
                    guard (49...57).contains(bytes[index]) else { throw RecoveryProcessFailure.syntax }
                    repeat { index += 1 } while index < bytes.count && (48...57).contains(bytes[index])
                }
                guard index - start <= 20,
                      Int64(String(decoding: bytes[start..<index], as: UTF8.self)) != nil else { throw RecoveryProcessFailure.syntax }
                // No reals, exponents, plus signs or ignored numeric suffixes.
            default: throw RecoveryProcessFailure.syntax
            }
        }
        mutating func literal(_ text: String) throws { for byte in text.utf8 { try take(byte) } }
        mutating func string() throws -> String {
            let start = index; try take(34)
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 {
                    do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                    catch { throw RecoveryProcessFailure.syntax }
                }
                guard byte >= 32 else { throw RecoveryProcessFailure.syntax }
                if byte == 92 {
                    guard index < bytes.count else { throw RecoveryProcessFailure.syntax }
                    let escaped = bytes[index]; index += 1
                    if escaped == 117 {
                        for _ in 0..<4 {
                            guard index < bytes.count, (48...57).contains(bytes[index]) || (65...70).contains(bytes[index]) || (97...102).contains(bytes[index])
                            else { throw RecoveryProcessFailure.syntax }; index += 1
                        }
                    } else if ![34, 92, 47, 98, 102, 110, 114, 116].contains(escaped) { throw RecoveryProcessFailure.syntax }
                }
            }
            throw RecoveryProcessFailure.syntax
        }
    }
}

/// At most one incoming frame at a time. No unbounded concatenated-frame inbox.
public struct RecoveryProcessFramer: Sendable {
    private var bytes = Data()
    public init() {}
    public var count: Int { bytes.count }
    public mutating func append(_ data: Data) throws {
        guard data.count <= RecoveryProcessCodec.maximumMessage + 4 - bytes.count else { throw RecoveryProcessFailure.bounds }
        bytes.append(data)
        if bytes.count >= 4 {
            let size = bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard size > 0, size <= RecoveryProcessCodec.maximumMessage, bytes.count <= size + 4 else { throw RecoveryProcessFailure.bounds }
        }
    }
    public mutating func take() -> Data? {
        guard bytes.count >= 4 else { return nil }
        let size = bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard bytes.count == size + 4 else { return nil }
        let result = Data(bytes.dropFirst(4)); bytes.removeAll(keepingCapacity: false); return result
    }
}

/// Incremental SHA-256 with a 512 MiB input ceiling. Test-only source/config
/// binding; distinct from all native authorization and page commitments.
public struct RecoveryProcessSHA256: Sendable {
    private var state: [UInt32] = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]
    private var pending: [UInt8] = []
    private var count: UInt64 = 0
    public init() {}
    public mutating func update(_ data: Data) throws {
        guard UInt64(data.count) <= 536_870_912 - count else { throw RecoveryProcessFailure.bounds }
        count += UInt64(data.count)
        for byte in data {
            pending.append(byte)
            if pending.count == 64 { compress(pending); pending.removeAll(keepingCapacity: true) }
        }
    }
    public func finish() -> String {
        var copy = self; let bits = count * 8
        copy.pending.append(0x80)
        while copy.pending.count % 64 != 56 { copy.pending.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { copy.pending.append(UInt8((bits >> UInt64(shift)) & 255)) }
        let final = copy.pending
        for offset in stride(from: 0, to: final.count, by: 64) { copy.compress(Array(final[offset..<offset + 64])) }
        return copy.state.map { String(format: "%08x", $0) }.joined()
    }
    public static func hash(_ data: Data) throws -> String { var hash = Self(); try hash.update(data); return hash.finish() }
    private mutating func compress(_ block: [UInt8]) {
        let k: [UInt32] = [0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
            0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
            0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
            0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
            0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
            0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
            0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
            0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]
        func r(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 { for byte in block[(i * 4)..<(i * 4 + 4)] { w[i] = (w[i] << 8) | UInt32(byte) } }
        for i in 16..<64 {
            let a = w[i - 15], b = w[i - 2]
            w[i] = w[i - 16] &+ (r(a,7) ^ r(a,18) ^ (a >> 3)) &+ w[i - 7] &+ (r(b,17) ^ r(b,19) ^ (b >> 10))
        }
        var a=state[0], b=state[1], c=state[2], d=state[3], e=state[4], f=state[5], g=state[6], h=state[7]
        for i in 0..<64 {
            let t1 = h &+ (r(e,6) ^ r(e,11) ^ r(e,25)) &+ ((e & f) ^ (~e & g)) &+ k[i] &+ w[i]
            let t2 = (r(a,2) ^ r(a,13) ^ r(a,22)) &+ ((a & b) ^ (a & c) ^ (b & c))
            h=g; g=f; f=e; e=d &+ t1; d=c; c=b; b=a; a=t1 &+ t2
        }
        for (i, value) in [a,b,c,d,e,f,g,h].enumerated() { state[i] = state[i] &+ value }
    }
}
