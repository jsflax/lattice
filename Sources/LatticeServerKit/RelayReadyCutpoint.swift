import Foundation
import CoreFoundation
import Vapor
import Lattice

/// Test observation only: these hashes compare copied fields, never authorize a
/// lease, verify a native digest, or prove that the receiver consumed a frame.
struct RelayReadyCanonicalFrame: Sendable {
    enum Kind: String, Sendable { case request, manifest, contentPage = "content_page", receiptPage = "receipt_page", end }
    let kind: Kind
    let canonicalVersion: Int
    let receiverIncarnation, channelIncarnation, channel, attemptID, sequence: String
    let routeGeneration: String
    let requestDigest, manifestDigest, pageIndex, itemCount, payloadBytes, nativePageDigest: String?
    let normalizedFrameSHA256: String
}

struct RelayReadyCutpoint: Sendable {
    enum Kind: Sendable, Equatable { case positivePrepareLease, manifest, contentPage, receiptPage, end }
    let kind: Kind
    let frame: RelayReadyCanonicalFrame
    let requestDigest: String
    /// Exact encoded nested Q, before route normalization; absent for reads.
    let requestFrameSHA256: String?

    /// Called only after actual native processing for an installed observer.
    /// The pure copying seam also permits malformed-input tests without a native
    /// result constructor. No copied fact is fed back to native or sendReady.
    static func copy(input: Data, output: Data, status: Int32, requestID: String,
                     peer: SyncRecoveryPeerIdentity, channel: String) -> Self? {
        guard status == 1, input.count <= ReadyCutpointJSON.byteLimit,
              output.count <= ReadyCutpointJSON.byteLimit else { return nil }
        do {
            let request = try ReadyCutpointJSON.object(input)
            try ReadyCutpointJSON.control(request, requestID: requestID)
            let operation = try ReadyCutpointJSON.string(request["operation"])
            let route = try ReadyCutpointJSON.decimal(request["routeGeneration"], positive: true)
            let frame: RelayReadyCanonicalFrame
            let digest: String
            let requestHash: String?
            let kind: Kind
            switch operation {
            case "prepare":
                try ReadyCutpointJSON.keys(request, ["kind", "version", "operation", "requestID", "routeGeneration", "request", "durationMilliseconds"])
                let duration = try ReadyCutpointJSON.integer(request["durationMilliseconds"], positive: true)
                let nested = try ReadyCutpointJSON.string(request["request"], cap: ReadyCutpointJSON.byteLimit)
                let nestedData = Data(nested.utf8)
                frame = try ReadyCutpointJSON.frame(nestedData)
                guard frame.kind == .request, let boundDigest = frame.requestDigest else { return nil }
                let response = try ReadyCutpointJSON.object(output)
                try ReadyCutpointJSON.keys(response, ["kind", "version", "operation", "requestID", "routeGeneration", "expiration", "preparation", "publication", "captureError", "requiresFullRequest", "leaseAvailable", "leaseID", "requestDigest", "attemptID", "sequence", "frames", "wireBytes", "durationMilliseconds"])
                try ReadyCutpointJSON.control(response, requestID: requestID)
                guard try ReadyCutpointJSON.string(response["operation"]) == "prepare",
                      try ReadyCutpointJSON.decimal(response["routeGeneration"], positive: true) == route,
                      try ReadyCutpointJSON.settlement(response["publication"]) == "committed",
                      try ReadyCutpointJSON.boolean(response["leaseAvailable"]) else { return nil }
                _ = try ReadyCutpointJSON.settlement(response["expiration"])
                _ = try ReadyCutpointJSON.settlement(response["preparation"])
                _ = try ReadyCutpointJSON.boolean(response["captureError"])
                _ = try ReadyCutpointJSON.boolean(response["requiresFullRequest"])
                _ = try ReadyCutpointJSON.name(response["leaseID"])
                _ = try ReadyCutpointJSON.decimal(response["frames"], positive: true)
                _ = try ReadyCutpointJSON.decimal(response["wireBytes"], positive: true)
                guard try ReadyCutpointJSON.integer(response["durationMilliseconds"], positive: true) == duration,
                      try ReadyCutpointJSON.digest(response["requestDigest"]) == boundDigest,
                      try ReadyCutpointJSON.uuid(response["attemptID"]) == frame.attemptID,
                      try ReadyCutpointJSON.decimal(response["sequence"], positive: true) == frame.sequence else { return nil }
                digest = boundDigest; requestHash = ReadyCutpointJSON.hash(nestedData); kind = .positivePrepareLease
            case "read":
                try ReadyCutpointJSON.keys(request, ["kind", "version", "operation", "requestID", "routeGeneration", "leaseID", "requestDigest", "attemptID", "sequence", "index"])
                _ = try ReadyCutpointJSON.name(request["leaseID"])
                _ = try ReadyCutpointJSON.decimal(request["index"])
                digest = try ReadyCutpointJSON.digest(request["requestDigest"])
                frame = try ReadyCutpointJSON.frame(output)
                guard try ReadyCutpointJSON.uuid(request["attemptID"]) == frame.attemptID,
                      try ReadyCutpointJSON.decimal(request["sequence"], positive: true) == frame.sequence,
                      frame.requestDigest == nil || frame.requestDigest == digest else { return nil }
                switch frame.kind {
                case .manifest: kind = .manifest
                case .contentPage: kind = .contentPage
                case .receiptPage: kind = .receiptPage
                case .end: kind = .end
                case .request: return nil
                }
                requestHash = nil
            default: return nil
            }
            guard frame.routeGeneration == route,
                  frame.receiverIncarnation == peer.receiverIncarnation.uuidString.lowercased(),
                  frame.channelIncarnation == peer.channelIncarnation.uuidString.lowercased(),
                  frame.channel.utf8.elementsEqual(channel.utf8) else { return nil }
            return .init(kind: kind, frame: frame, requestDigest: digest, requestFrameSHA256: requestHash)
        } catch { return nil }
    }

    /// Shared one-time comparison for the actual source frame and post-reap
    /// stored wire. Callers separately require stored route == "1" and bind the
    /// original route to Q/M. No input payload is retained in the returned value.
    static func canonicalFrame(_ data: Data) -> RelayReadyCanonicalFrame? {
        try? ReadyCutpointJSON.frame(data)
    }
}

private enum ReadyCutpointJSON {
    static let byteLimit = 65_536
    enum Invalid: Error { case shape }
    static func require(_ condition: Bool) throws { if !condition { throw Invalid.shape } }
    static func object(_ data: Data) throws -> [String: Any] {
        var scan = ReadyCutpointSyntax(data)
        try scan.validate() // duplicates and token types must survive until here
        return try object(JSONSerialization.jsonObject(with: data))
    }
    static func object(_ value: Any?) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw Invalid.shape }; return object
    }
    static func keys(_ object: [String: Any], _ fields: [String]) throws {
        try require(object.count == fields.count && fields.allSatisfy { object[$0] != nil })
    }
    static func string(_ value: Any?, cap: Int = 256) throws -> String {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= cap else { throw Invalid.shape }; return text
    }
    static func name(_ value: Any?, cap: Int = 256) throws -> String {
        let text = try string(value, cap: cap)
        try require(!text.utf8.contains { $0 < 32 || $0 == 127 }); return text
    }
    static func hex(_ value: Any?, count: Int) throws -> String {
        let text = try string(value, cap: count)
        try require(text.utf8.count == count && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }); return text
    }
    static func digest(_ value: Any?) throws -> String { try hex(value, count: 64) }
    static func uuid(_ value: Any?) throws -> String {
        let text = try string(value, cap: 36), bytes = Array(text.utf8)
        try require(bytes.count == 36)
        for (index, byte) in bytes.enumerated() {
            try require([8, 13, 18, 23].contains(index) ? byte == 45 : (48...57).contains(byte) || (97...102).contains(byte))
        }
        return text
    }
    static func decimal(_ value: Any?, positive: Bool = false) throws -> String {
        let text = try string(value, cap: 19)
        guard let number = Int64(text), number >= (positive ? 1 : 0), String(number) == text else { throw Invalid.shape }; return text
    }
    static func integer(_ value: Any?, positive: Bool = false) throws -> Int64 {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let result = Int64(number.stringValue), result >= (positive ? 1 : 0) else { throw Invalid.shape }; return result
    }
    static func boolean(_ value: Any?) throws -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw Invalid.shape }; return number.boolValue
    }
    static func null(_ value: Any?) -> Bool { value is NSNull }
    static func array(_ value: Any?) throws -> [Any] {
        guard let values = value as? [Any], values.count <= 256 else { throw Invalid.shape }; return values
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func control(_ value: [String: Any], requestID: String) throws {
        try require(try string(value["kind"]) == "recoveryReady" && integer(value["version"]) == 1 && uuid(value["requestID"]) == requestID)
    }
    static func settlement(_ value: Any?) throws -> String {
        let value = try object(value)
        try keys(value, ["state", "unexpectedCommitObserved", "primaryError", "cleanupError", "postcommitError", "notificationError"])
        let state = try string(value["state"])
        try require(["refused", "rolledBack", "committed", "unsettled", "ownershipLost"].contains(state))
        for key in ["unexpectedCommitObserved", "primaryError", "cleanupError", "postcommitError", "notificationError"] { _ = try boolean(value[key]) }
        return state
    }
    static func source(_ value: Any?) throws -> [String: Any] {
        let value = try object(value); try keys(value, ["authority", "source_id", "epoch", "scope_digest", "schema_digest"])
        _ = try name(value["authority"]); _ = try uuid(value["source_id"]); _ = try uuid(value["epoch"])
        _ = try digest(value["scope_digest"]); _ = try digest(value["schema_digest"]); return value
    }
    static func identity(_ value: Any?) throws -> [String] {
        let value = try object(value); try keys(value, ["table", "id"])
        return [try name(value["table"]), try name(value["id"])]
    }
    static func binding(_ value: Any?) throws {
        let value = try object(value); try keys(value, ["producer", "cohortID", "cohortRevision", "operationCodec"])
        let producer = try object(value["producer"]); try keys(producer, ["registrationID", "incarnation"])
        _ = try name(producer["registrationID"]); _ = try uuid(producer["incarnation"]); _ = try uuid(value["cohortID"])
        _ = try integer(value["cohortRevision"], positive: true); try require(try integer(value["operationCodec"]) == 1)
    }
    static func profile(_ body: [String: Any], version: Int, manifest: Bool) throws -> [String] {
        guard version == 3 else { return [] }
        try binding(body["registered_producer"]); _ = try name(body["receipt_namespace"])
        if manifest { _ = try decimal(body["coverage_revision"]) }
        return ["registered_producer", "receipt_namespace"] + (manifest ? ["coverage_revision"] : [])
    }
    static func mode(_ body: [String: Any]) throws {
        let mode = try string(body["mode"])
        try require(mode == "full" || mode == "delta")
        if mode == "full" { try require(null(body["base"])) } else { _ = try decimal(body["base"]) }
    }
    static func request(_ body: [String: Any], version: Int, sequence: String) throws {
        let extra = try profile(body, version: version, manifest: false)
        try keys(body, ["source", "mode", "base", "expected_install", "limits", "receipt_requests", "request_digest"] + extra)
        let current = try source(body["source"]); try mode(body); _ = try digest(body["request_digest"])
        let expected = try object(body["expected_install"]); try keys(expected, ["revision", "binding", "frontier"])
        let revision = try decimal(expected["revision"]), frontier = try object(expected["frontier"])
        let frontierKind = try string(frontier["kind"])
        if frontierKind == "position" { try keys(frontier, ["kind", "value"]); _ = try decimal(frontier["value"]) }
        else { try keys(frontier, ["kind"]); try require(["uninitialized", "beginning_null"].contains(frontierKind)) }
        try require((frontierKind == "position") == (revision != "0") && Int64(sequence)! > Int64(revision)!)
        if null(expected["binding"]) { try require(frontierKind == "uninitialized") }
        else {
            let old = try source(expected["binding"])
            try require(try string(old["authority"]).utf8.elementsEqual(string(current["authority"]).utf8) && digest(old["scope_digest"]) == digest(current["scope_digest"]))
        }
        if try string(body["mode"]) == "delta" {
            let old = try source(expected["binding"])
            for key in ["authority", "source_id", "epoch", "scope_digest", "schema_digest"] { try require(try string(old[key]).utf8.elementsEqual(string(current[key]).utf8)) }
            let frontierValue = try decimal(frontier["value"]), base = try decimal(body["base"])
            try require(frontierKind == "position" && frontierValue == base)
        }
        let limits = try object(body["limits"])
        try keys(limits, ["frame_bytes", "payload_bytes", "items_per_page", "content_pages", "content_identities", "content_bytes", "receipt_pages", "receipts", "receipt_bytes"])
        for key in limits.keys { _ = try decimal(limits[key], positive: ["frame_bytes", "payload_bytes", "items_per_page"].contains(key)) }
        try require(Int64(try decimal(limits["frame_bytes"]))! <= 16_777_216 && Int64(try decimal(limits["payload_bytes"]))! <= Int64(try decimal(limits["frame_bytes"]))! && Int64(try decimal(limits["items_per_page"]))! <= 4096)
        var previous: String?, targetCount = 0
        let receipts = try array(body["receipt_requests"])
        try require(Int64(receipts.count) <= Int64(try decimal(limits["receipts"]))!)
        for raw in receipts {
            let item = try object(raw)
            try keys(item, ["original_id", "targets", version == 3 ? "operation_digest" : "provenance"])
            let original = try name(item["original_id"])
            if let previous { try require(previous.utf8.lexicographicallyPrecedes(original.utf8)) }; previous = original
            if version == 3 { _ = try digest(item["operation_digest"]) }
            else {
                let provenance = try object(item["provenance"]), kind = try string(provenance["kind"])
                if kind == "negotiated" { try keys(provenance, ["kind", "namespace_id"]); _ = try name(provenance["namespace_id"]) }
                else { try keys(provenance, ["kind"]); try require(kind == "unknown") }
            }
            let targets = try array(item["targets"]); try require(!targets.isEmpty)
            targetCount += targets.count; try require(targetCount <= 256)
            var prior: [String]?
            for target in targets {
                let id = try identity(target)
                if let prior { try require(prior[0].utf8.elementsEqual(id[0].utf8) ? prior[1].utf8.lexicographicallyPrecedes(id[1].utf8) : prior[0].utf8.lexicographicallyPrecedes(id[0].utf8)) }; prior = id
            }
        }
    }
    static func manifest(_ body: [String: Any], version: Int) throws {
        let extra = try profile(body, version: version, manifest: true)
        try keys(body, ["request_digest", "source", "mode", "base", "head", "lease", "totals", "content_digest", "receipt_digest", "rebase_digest", "manifest_digest"] + extra)
        _ = try source(body["source"]); try mode(body); let head = try decimal(body["head"])
        if !null(body["base"]) { try require(Int64(try decimal(body["base"]))! <= Int64(head)!) }
        for key in ["request_digest", "content_digest", "receipt_digest", "rebase_digest", "manifest_digest"] { _ = try digest(body[key]) }
        let lease = try object(body["lease"]); try keys(lease, ["id", "duration_ms"])
        _ = try name(lease["id"]); _ = try decimal(lease["duration_ms"], positive: true)
        let totals = try object(body["totals"])
        try keys(totals, ["content_pages", "identities", "present", "tombstones", "content_bytes", "receipt_pages", "receipts", "receipt_bytes", "rebase_identities", "rebase_bytes"])
        for value in totals.values { _ = try decimal(value) }
    }
    static func page(_ body: [String: Any], version: Int, receipts: Bool) throws {
        try keys(body, ["manifest_digest", "index", "count", "bytes", "digest", "items"])
        _ = try digest(body["manifest_digest"]); _ = try digest(body["digest"]); _ = try decimal(body["index"])
        let count = try decimal(body["count"], positive: true); _ = try decimal(body["bytes"], positive: true)
        let items = try array(body["items"]); try require(Int64(items.count) == Int64(count)!)
        for raw in items {
            let item = try object(raw)
            if !receipts {
                let tag = try string(item["tag"])
                try keys(item, ["table", "id", "tag"] + (tag == "present" ? ["payload"] : []))
                _ = try name(item["table"]); _ = try name(item["id"])
                if tag == "present" { _ = try string(item["payload"], cap: byteLimit) } else { try require(tag == "tombstone") }
            } else {
                _ = try name(item["original_id"]); let status = try string(item["status"])
                var fields = ["original_id", "status"]
                if status == "unknown" {
                    fields += ["reason"]
                    try require(["legacy", "missing_coverage", "retired_coverage", "source_changed", "unproved_provenance"].contains(try string(item["reason"])))
                } else {
                    try require(status == "committed" || (status == "not_committed" && version == 2))
                    fields += ["namespace_id", "coverage_id"]
                    _ = try name(item["namespace_id"]); _ = try name(item["coverage_id"])
                    if status == "committed" {
                        fields += ["decision", "position", "accepted_target"]
                        try require(["applied", "no_op", "policy"].contains(try string(item["decision"])))
                        _ = try decimal(item["position"], positive: true)
                        if !null(item["accepted_target"]) { _ = try identity(item["accepted_target"]) }
                    }
                }
                if version == 3 {
                    fields += ["operation_digest", "legacy_unbound"]; _ = try digest(item["operation_digest"])
                    let legacy = try boolean(item["legacy_unbound"]); try require(!legacy || status == "committed")
                }
                try keys(item, fields)
            }
        }
    }
    static func frame(_ data: Data) throws -> RelayReadyCanonicalFrame {
        var root = try object(data); try keys(root, ["latticeCanonicalRange"])
        var envelope = try object(root["latticeCanonicalRange"])
        try keys(envelope, ["version", "attempt", "route_generation", "kind", "body"])
        let version = try integer(envelope["version"]); try require(version == 2 || version == 3)
        let attempt = try object(envelope["attempt"])
        try keys(attempt, ["receiver_incarnation", "channel_incarnation", "channel", "sequence", "attempt_id"])
        let receiver = try uuid(attempt["receiver_incarnation"]), incarnation = try uuid(attempt["channel_incarnation"])
        let channel = try name(attempt["channel"], cap: 64), id = try uuid(attempt["attempt_id"])
        let sequence = try decimal(attempt["sequence"], positive: true), route = try decimal(envelope["route_generation"], positive: true)
        guard let kind = RelayReadyCanonicalFrame.Kind(rawValue: try string(envelope["kind"])) else { throw Invalid.shape }
        let body = try object(envelope["body"])
        switch kind {
        case .request: try request(body, version: Int(version), sequence: sequence)
        case .manifest: try manifest(body, version: Int(version))
        case .contentPage, .receiptPage: try page(body, version: Int(version), receipts: kind == .receiptPage)
        case .end: try keys(body, ["manifest_digest"]); _ = try digest(body["manifest_digest"])
        }
        envelope["route_generation"] = "1"; root["latticeCanonicalRange"] = envelope
        let normalized = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
        try require(normalized.count <= byteLimit)
        return .init(kind: kind, canonicalVersion: Int(version), receiverIncarnation: receiver,
            channelIncarnation: incarnation, channel: channel, attemptID: id, sequence: sequence,
            routeGeneration: route, requestDigest: body["request_digest"] as? String,
            manifestDigest: body["manifest_digest"] as? String, pageIndex: body["index"] as? String,
            itemCount: body["count"] as? String, payloadBytes: body["bytes"] as? String,
            nativePageDigest: body["digest"] as? String, normalizedFrameSHA256: hash(normalized))
    }
}

/// Syntax-only scanner. Foundation receives nothing until this accepts the whole
/// UTF-8 buffer. Keys are compared as decoded UTF-8 bytes (including escapes),
/// not Swift's Unicode-canonical String equality. Payload strings stay opaque.
/// Internal visibility permits pure bounds tests; it carries no native authority.
struct ReadyCutpointSyntax {
    private let bytes: [UInt8]
    private var offset = 0, nodes = 0
    init(_ data: Data) { bytes = data.count <= ReadyCutpointJSON.byteLimit ? Array(data) : [] }
    mutating func validate() throws {
        try check(!bytes.isEmpty && String(bytes: bytes, encoding: .utf8) != nil)
        try value(depth: 0); whitespace(); try check(offset == bytes.count)
    }
    private func check(_ condition: Bool) throws { try ReadyCutpointJSON.require(condition) }
    private mutating func node() throws { nodes += 1; try check(nodes <= 4096) }
    private mutating func whitespace() { while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 } }
    private mutating func consume(_ byte: UInt8) throws { try check(offset < bytes.count && bytes[offset] == byte); offset += 1 }
    private mutating func value(depth: Int) throws {
        whitespace(); try node(); try check(offset < bytes.count)
        switch bytes[offset] {
        case 123:
            try check(depth < 16); offset += 1; whitespace()
            if offset < bytes.count && bytes[offset] == 125 { offset += 1; return }
            var keys = Set<Data>()
            while true {
                whitespace(); try node(); let key = try string(); try check(keys.count < 32 && keys.insert(Data(key)).inserted)
                whitespace(); try consume(58); try value(depth: depth + 1); whitespace()
                if offset < bytes.count && bytes[offset] == 125 { offset += 1; return }
                try consume(44)
            }
        case 91:
            try check(depth < 16); offset += 1; whitespace()
            if offset < bytes.count && bytes[offset] == 93 { offset += 1; return }
            var count = 0
            while true {
                count += 1; try check(count <= 256); try value(depth: depth + 1); whitespace()
                if offset < bytes.count && bytes[offset] == 93 { offset += 1; return }
                try consume(44)
            }
        case 34: _ = try string()
        case 116: try literal(Array("true".utf8))
        case 102: try literal(Array("false".utf8))
        case 110: try literal(Array("null".utf8))
        default:
            let start = offset
            if bytes[offset] == 45 { offset += 1 }
            try check(offset < bytes.count)
            if bytes[offset] == 48 { offset += 1 }
            else {
                try check((49...57).contains(bytes[offset])); offset += 1
                while offset < bytes.count && (48...57).contains(bytes[offset]) { offset += 1 }
            }
            // Fractions/exponents never reach Foundation; the next separator
            // check rejects them. Signed integers must fit the protocol bound.
            try check(Int64(String(decoding: bytes[start..<offset], as: UTF8.self)) != nil)
        }
    }
    private mutating func literal(_ token: [UInt8]) throws { for byte in token { try consume(byte) } }
    private mutating func hex4() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            try check(offset < bytes.count); let byte = bytes[offset]; offset += 1
            let digit: UInt32
            switch byte { case 48...57: digit = UInt32(byte - 48); case 65...70: digit = UInt32(byte - 55); case 97...102: digit = UInt32(byte - 87); default: throw ReadyCutpointJSON.Invalid.shape }
            value = value * 16 + digit
        }
        return value
    }
    private mutating func string() throws -> [UInt8] {
        try consume(34); var result: [UInt8] = []
        while offset < bytes.count {
            let byte = bytes[offset]; offset += 1
            if byte == 34 { return result }
            try check(byte >= 32)
            if byte != 92 { result.append(byte) }
            else {
                try check(offset < bytes.count); let escaped = bytes[offset]; offset += 1
                switch escaped {
                case 34, 47, 92: result.append(escaped)
                case 98: result.append(8)
                case 102: result.append(12)
                case 110: result.append(10)
                case 114: result.append(13)
                case 116: result.append(9)
                case 117:
                    var code = try hex4()
                    if (0xD800...0xDBFF).contains(code) {
                        try consume(92); try consume(117); let low = try hex4(); try check((0xDC00...0xDFFF).contains(low))
                        code = 0x10000 + (code - 0xD800) * 1024 + low - 0xDC00
                    } else { try check(!(0xDC00...0xDFFF).contains(code)) }
                    guard let scalar = UnicodeScalar(code) else { throw ReadyCutpointJSON.Invalid.shape }
                    result.append(contentsOf: String(scalar).utf8)
                default: throw ReadyCutpointJSON.Invalid.shape
                }
            }
            try check(result.count <= ReadyCutpointJSON.byteLimit)
        }
        throw ReadyCutpointJSON.Invalid.shape
    }
}
