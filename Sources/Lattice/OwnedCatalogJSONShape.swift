import Foundation

/// Catalog metadata contains only strings, objects and arrays. Validate its
/// bounded syntax before Foundation decoding, which otherwise loses duplicate
/// object keys. Values are never JSON numbers, booleans or null.
enum OwnedCatalogJSONShape {
    static func validate(_ data: Data) throws {
        guard data.count <= 65_536, String(data: data, encoding: .utf8) != nil else {
            throw OwnedCatalogError.malformedFrame("Metadata exceeds 64 KiB or is not UTF-8")
        }
        var parser = Parser(bytes: Array(data))
        try parser.value(depth: 0)
        parser.whitespace()
        guard parser.index == parser.bytes.count else { throw parser.failure }
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var failure: OwnedCatalogError { .malformedFrame("Invalid, duplicate or excessive metadata syntax") }
        mutating func whitespace() {
            while index < bytes.count && [UInt8(9), 10, 13, 32].contains(bytes[index]) { index += 1 }
        }
        mutating func take(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }
        mutating func value(depth: Int) throws {
            guard depth <= 8 else { throw failure }
            whitespace()
            guard index < bytes.count else { throw failure }
            switch bytes[index] {
            case 123:
                index += 1
                whitespace()
                var keys = Set<String>()
                if take(125) { return }
                while true {
                    whitespace()
                    let key = try string()
                    guard keys.insert(key).inserted else { throw failure }
                    whitespace()
                    guard take(58) else { throw failure }
                    try value(depth: depth + 1)
                    whitespace()
                    if take(125) { return }
                    guard take(44) else { throw failure }
                }
            case 91:
                index += 1
                whitespace()
                if take(93) { return }
                while true {
                    try value(depth: depth + 1)
                    whitespace()
                    if take(93) { return }
                    guard take(44) else { throw failure }
                }
            case 34: _ = try string()
            default: throw failure
            }
        }
        mutating func string() throws -> String {
            let start = index
            guard take(34) else { throw failure }
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                guard byte >= 32 else { throw failure }
                if byte == 92 {
                    guard index < bytes.count else { throw failure }
                    let escaped = bytes[index]
                    index += 1
                    if escaped == 117 {
                        let unit = try unicodeUnit()
                        if (0xD800...0xDBFF).contains(unit) {
                            guard take(92), take(117), (0xDC00...0xDFFF).contains(try unicodeUnit()) else { throw failure }
                        } else if (0xDC00...0xDFFF).contains(unit) { throw failure }
                    } else if ![UInt8(34), 47, 92, 98, 102, 110, 114, 116].contains(escaped) { throw failure }
                }
            }
            throw failure
        }
        mutating func unicodeUnit() throws -> UInt16 {
            var result: UInt16 = 0
            for _ in 0..<4 {
                guard index < bytes.count else { throw failure }
                let byte = bytes[index]
                index += 1
                let nibble: UInt8
                switch byte {
                case 48...57: nibble = byte - 48
                case 65...70: nibble = byte - 55
                case 97...102: nibble = byte - 87
                default: throw failure
                }
                result = (result << 4) | UInt16(nibble)
            }
            return result
        }
    }
}
