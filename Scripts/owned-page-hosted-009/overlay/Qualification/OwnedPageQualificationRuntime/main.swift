import Foundation
import CxxStdlib
import Lattice
import LatticeSwiftModule
import LatticeSwiftCppBridge
import DurablePageRuntimeFixture

typealias Page = lattice.experimental_durable_page
typealias Stop = lattice.experimental_durable_stop_control
struct Failure: Error { let reason: String }
func require(_ value: Bool, _ reason: String) throws {
    if !value { throw Failure(reason: reason) }
}
func checkBridgeError(_ context: String) throws {
    try require(String(lattice.last_bridge_error().pointee).isEmpty, "bridged accessor failure: " + context)
}
func emit(_ name: String, _ facts: [String: Any] = [:]) throws {
    let bytes = try JSONSerialization.data(withJSONObject: ["case": name, "passed": true, "facts": facts], options: [.sortedKeys])
    print("DURABLE_RUNTIME " + String(decoding: bytes, as: UTF8.self))
}
func numbers() -> [String: Any] {
    let c = durable_runtime_fixture.statistics()
    return ["failures": c.failures, "realReads": c.real_reads, "captures": c.captures,
            "commits": c.commits, "writerCountersPreserved": c.writer_counters_preserved,
            "ownerCloses": c.owner_closes, "ownerDestructions": c.owner_destructions,
            "checkpointBusy": c.checkpoint_busy, "checkpointLog": c.checkpoint_log,
            "checkpointDone": c.checkpoint_done, "preCancelReads": c.pre_cancel_reads,
            "preCancelStatus": c.pre_cancel_status, "preCancelCleanup": c.pre_cancel_cleanup,
            "preCancelFileAbsent": c.pre_cancel_file_absent]
}
func nativeExpected(_ group: Int32, _ row: UInt64 = 0, _ field: Int32 = 0) -> Int64 {
    durable_runtime_fixture.expected_number(group, row, field)
}
func verifyBytes(_ page: Page) throws -> [String: Any] {
    try require(page.statusCode() == 0 && page.result().cleanup_ok && page.hasCursor() && page.atHead(), "ready complete real page")
    try require(page.frameCount() == 1 && page.rowCount() == 2, "one frame/two audit rows")
    try require(page.textBytes() == UInt64(nativeExpected(7)), "same arena byte count")
    try require(page.allocatedBackingBytes() > page.textBytes(), "backing accounts for arena and headers")
    let snapshot = page.snapshot()
    let actualSnapshot = [snapshot.audit_head, snapshot.capture_started_after, snapshot.pruned_through]
    for field in 0..<3 { try require(actualSnapshot[field] == nativeExpected(0, 0, Int32(field)), "snapshot counter bytes") }
    let frame = page.frame(0)
    try checkBridgeError("frame")
    let actualFrame = [frame.id, frame.first_audit_id, frame.last_audit_id, Int64(frame.row_offset), Int64(frame.row_count)]
    for field in 0..<5 { try require(actualFrame[field] == nativeExpected(1, 0, Int32(field)), "frame header") }
    var auditIDs: [Int64] = []
    var allText: [[[String: Any]]] = []
    var allIntegers: [[[String: Any]]] = []
    for row in UInt64(0)..<UInt64(2) {
        let id = page.auditId(row: row)
        try checkBridgeError("auditId")
        try require(id == nativeExpected(2, row), "audit identity")
        auditIDs.append(id)
        var textFacts: [[String: Any]] = []
        for field in Int32(0)..<Int32(5) {
            let value = page.textField(row: row, field: field)
            try checkBridgeError("textField")
            try require(value.is_null == (nativeExpected(3, row, field) == 1), "text null flag")
            try require(value.byte_count == UInt64(nativeExpected(4, row, field)) && value.byte_count <= 4096, "bounded exact text length")
            var bytes: [UInt8] = []
            for byte in 0..<value.byte_count {
                let actual = page.textByte(row: row, field: field, byte: byte)
                try checkBridgeError("textByte")
                try require(actual == durable_runtime_fixture.expected_byte(3, row, field, byte), "exact raw stored header byte")
                bytes.append(actual)
            }
            if field == 1 { try require(bytes == Array("OwnedModel".utf8), "known table name") }
            if field == 2 { try require(bytes == Array((row == 0 ? "INSERT" : "UPDATE").utf8), "known operation order") }
            textFacts.append(["field": field, "isNull": value.is_null, "bytes": bytes])
        }
        allText.append(textFacts)
        var integerFacts: [[String: Any]] = []
        for field in Int32(0)..<Int32(3) {
            let value = page.integerField(row: row, field: field)
            try checkBridgeError("integerField")
            try require(value.is_null == (nativeExpected(5, row, field) == 1), "integer null flag")
            try require(value.value == nativeExpected(6, row, field), "integer value")
            integerFacts.append(["field": field, "isNull": value.is_null, "value": value.value])
        }
        allIntegers.append(integerFacts)
    }
    try require(page.cursorByteCount() == 139, "canonical cursor length")
    var token: [UInt8] = [], identities: [[UInt8]] = [], frameKey: [UInt8] = []
    for byte in UInt64(0)..<UInt64(139) {
        let actual = page.cursorByte(byte)
        try checkBridgeError("cursorByte")
        try require(actual == durable_runtime_fixture.expected_byte(0, 0, 0, byte), "exact native cursor bytes")
        token.append(actual)
    }
    try require(Array(token.prefix(7)) == Array("lrc1:f:".utf8), "frame token discriminator")
    for identity in Int32(0)..<Int32(2) {
        var bytes: [UInt8] = []
        for byte in UInt64(0)..<UInt64(32) {
            let actual = page.snapshotIdentityByte(identity: identity, byte: byte)
            try checkBridgeError("snapshotIdentityByte")
            try require(actual == durable_runtime_fixture.expected_byte(1, 0, identity, byte), "snapshot identity bytes")
            bytes.append(actual)
        }
        identities.append(bytes)
    }
    for byte in UInt64(0)..<UInt64(32) {
        let actual = page.frameKeyByte(frame: 0, byte: byte)
        try checkBridgeError("frameKeyByte")
        try require(actual == durable_runtime_fixture.expected_byte(2, 0, 0, byte), "frame key bytes")
        frameKey.append(actual)
    }
    try require(String(lattice.last_bridge_error().pointee).isEmpty, "no bridged bounds/conversion error")
    try require(durable_runtime_fixture.statistics().failures == 0, "no sealed native test failure")
    return ["snapshot": actualSnapshot, "frame": actualFrame, "auditIDs": auditIDs,
            "text": allText, "integers": allIntegers, "cursorBytes": token, "snapshotIdentities": identities,
            "frameKey": frameKey, "arenaBytes": page.textBytes(), "backingBytes": page.allocatedBackingBytes()]
}

// The caller checks weak expiration only AFTER this independent function scope
// returns. No assumption about the optimizer's last-use destruction point.
@inline(never)
func exerciseCopies(_ path: String, _ stop: Stop, expectedReads: Int32) throws -> [String: Any] {
    var original = path.withCString { durable_runtime_fixture.make_page($0, stop) }
    let counts = durable_runtime_fixture.statistics()
    try require(counts.failures == 0 && counts.real_reads == expectedReads, "real reader ran")
    try require(counts.owner_closes == counts.owner_destructions && counts.owner_destructions >= expectedReads, "owner closed and destroyed before returning page")
    try require(counts.checkpoint_busy == 0 && counts.checkpoint_log == 0 && counts.checkpoint_done == 0, "WAL release proof")
    var first = original
    let survivor = first
    try require(original.sharesBacking(with: first) && first.sharesBacking(with: survivor), "ordinary Swift copies share native backing")
    let originalBytes = original.allocatedBackingBytes()
    original = Page()
    try require(!original.hasCursor() && original.allocatedBackingBytes() == 0, "default reset clears only original")
    try require(first.sharesBacking(with: survivor) && !durable_runtime_fixture.backing_expired(), "first reset preserves other copies")
    first = Page()
    try require(!first.sharesBacking(with: survivor) && !durable_runtime_fixture.backing_expired(), "second reset preserves last copy")
    try require(survivor.allocatedBackingBytes() == originalBytes, "no cloned native page allocation")
    let raw = try verifyBytes(survivor)
    withExtendedLifetime(survivor) {}
    return raw
}

func main() throws {
    try require(CommandLine.arguments.count == 2, "one owned data root argument")
    let root = CommandLine.arguments[1]
    try require(ProcessInfo.processInfo.environment["DURABLE_RUNTIME_DATA_ROOT"] == root, "exact owned data root")
    let initialStop = Stop.make()
    let raw = try exerciseCopies(root + "/original.sqlite", initialStop, expectedReads: 1)
    try emit("RealOwnedPageCopiesAndRawBytesAfterOwnerClose", raw)
    try require(durable_runtime_fixture.backing_expired(), "last Swift page handle released its native backing after function return")
    try emit("LastSwiftHandleReleasesBacking", ["expired": true])

    let originalStop = Stop.make()
    let alias = originalStop
    let independent = Stop.make()
    try require(originalStop.isValid() && alias.sameOperation(as: originalStop) && !alias.sameOperation(as: independent), "stop identity and independence")
    alias.cancel()
    try require(originalStop.isCancelled() && alias.isCancelled() && !independent.isCancelled(), "Swift alias cancellation")
    let cancelled = (root + "/cancelled.sqlite").withCString { durable_runtime_fixture.pre_cancelled_read($0, originalStop) }
    try require(cancelled.statusCode() == 12 && cancelled.result().cleanup_ok && !cancelled.hasCursor() && cancelled.rowCount() == 0 && cancelled.allocatedBackingBytes() == 0, "real owned read observed precancelled Swift alias")
    let stopped = durable_runtime_fixture.statistics()
    try require(stopped.failures == 0 && stopped.pre_cancel_reads == 1 && stopped.pre_cancel_status == 12 && stopped.pre_cancel_cleanup && stopped.pre_cancel_file_absent, "pre-cancel skipped closed-owner/missing-file admission")
    try emit("SwiftStopAliasPreCancelsActualOwnedRead", numbers())

    let secondRaw = try exerciseCopies(root + "/independent.sqlite", independent, expectedReads: 2)
    try require(!independent.isCancelled() && durable_runtime_fixture.backing_expired(), "independent read and final release")
    try emit("IndependentStopStillReadsAndReleases", secondRaw)
    let emptyPage = Page()
    let emptyStop = Stop()
    emptyStop.cancel()
    try require(emptyPage.statusCode() == 1 && !emptyPage.hasCursor() && emptyPage.rowCount() == 0 && emptyPage.allocatedBackingBytes() == 0 && !emptyStop.isValid() && !emptyStop.isCancelled(), "default values remain empty")
    try emit("DefaultPageAndStopRemainEmpty")
    let final = durable_runtime_fixture.statistics()
    try require(final.failures == 0 && final.real_reads == 2 && final.captures == 3 && final.commits == 4 && final.writer_counters_preserved == 2 && final.owner_closes == 3 && final.owner_destructions == 3, "exact bounded native operation counters")
    try emit("ExactNativeCountersAndCleanup", numbers())
}
func edgeNumbers() -> [String: Any] {
    let c = durable_runtime_fixture.edge_statistics()
    return ["failures": c.failures, "owners": c.owners, "captures": c.captures,
            "oracleReads": c.oracle_reads, "commits": c.commits, "closes": c.closes,
            "removedFiles": c.removed_files, "checkpointBusy": c.checkpoint_busy,
            "checkpointLog": c.checkpoint_log, "checkpointDone": c.checkpoint_done]
}

// Owner destruction is checked only after returning across this function scope.
// The helper sets up a real captured cursor/committed transaction but does not
// call experimentalOwnedRead. This direct Swift call qualifies its signature.
@inline(never)
func acquireEdgePage(_ path: String) throws -> Page {
    guard let owner = path.withCString({ durable_runtime_fixture.make_edge_owner($0) }) else {
        throw Failure(reason: "sealed edge setup failure")
    }
    let token = durable_runtime_fixture.edge_cursor()
    try require(token.size() == 139, "exact starting cursor transport")
    let stop = Stop.make()
    let page = lattice.experimentalOwnedRead(owner, model: std.string("OwnedModel"), cursor: token,
                                             limits: lattice.experimental_owned_read_limits(), stop: stop)
    try checkBridgeError("experimentalOwnedRead ready")
    try require(durable_runtime_fixture.finish_edge_owner(owner, page, false), "reader cleanup/WAL and owner close")
    withExtendedLifetime(owner) {}
    return page
}

@inline(never)
func exerciseEdgeCopies(_ path: String) throws -> [String: Any] {
    var original = try acquireEdgePage(path)
    try require(durable_runtime_fixture.edge_owner_expired(), "actual owning API retains no owner after return and Swift scope exit")
    let c = durable_runtime_fixture.edge_statistics()
    try require(c.failures == 0 && c.owners == 1 && c.captures == 1 && c.oracle_reads == 1 && c.commits == 2 && c.closes == 1 && c.removed_files == 0, "one bounded actual edge fixture")
    try require(c.checkpoint_busy == 0 && c.checkpoint_log == 0 && c.checkpoint_done == 0, "actual edge WAL release")
    var first = original
    let survivor = first
    try require(original.sharesBacking(with: first) && first.sharesBacking(with: survivor), "actual edge ordinary copies share backing")
    let bytes = original.allocatedBackingBytes()
    original = Page()
    first = Page()
    try require(!original.hasCursor() && !first.hasCursor() && !durable_runtime_fixture.edge_backing_expired(), "resets preserve last edge handle")
    try require(survivor.allocatedBackingBytes() == bytes, "edge copy does not clone backing")
    var facts = try verifyBytes(survivor)
    facts["edgeCounters"] = edgeNumbers()
    facts["ownerExpired"] = true
    withExtendedLifetime(survivor) {}
    return facts
}

func requireEdgeFailure(_ page: Page, _ status: Int32) throws {
    try require(page.statusCode() == status && page.result().cleanup_ok && !page.hasCursor() && !page.atHead() && page.textBytes() == 0
                && page.frameCount() == 0 && page.rowCount() == 0 && page.allocatedBackingBytes() == 0,
                "structured nonadvancing edge failure")
}
@inline(never)
func exerciseEdgeStops(_ path: String) throws -> [String: Any] {
    guard let owner = path.withCString({ durable_runtime_fixture.make_edge_owner($0) }) else {
        throw Failure(reason: "sealed stop-edge setup failure")
    }
    let token = durable_runtime_fixture.edge_cursor()
    let model = std.string("OwnedModel")
    let bounds = lattice.experimental_owned_read_limits()
    let original = Stop.make()
    let alias = original
    let independent = Stop.make()
    try require(alias.sameOperation(as: original) && !independent.sameOperation(as: original), "actual edge operation identities")
    var statuses: [Int32] = []
    let invalid = lattice.experimentalOwnedRead(owner, model: model, cursor: std.string("invalid"), limits: bounds, stop: independent)
    try checkBridgeError("invalid cursor")
    try requireEdgeFailure(invalid, 3); statuses.append(invalid.statusCode())
    let invalidStop = lattice.experimentalOwnedRead(owner, model: model, cursor: token, limits: bounds, stop: Stop())
    try checkBridgeError("default stop")
    try requireEdgeFailure(invalidStop, 1); statuses.append(invalidStop.statusCode())
    var invalidBounds = bounds
    invalidBounds.max_rows = 0
    let limited = lattice.experimentalOwnedRead(owner, model: model, cursor: token, limits: invalidBounds, stop: independent)
    try checkBridgeError("invalid limits")
    try requireEdgeFailure(limited, 2); statuses.append(limited.statusCode())
    alias.cancel()
    try require(original.isCancelled() && alias.isCancelled() && !independent.isCancelled(), "actual edge stop alias independent control")
    let live = lattice.experimentalOwnedRead(owner, model: model, cursor: token, limits: bounds, stop: independent)
    try checkBridgeError("independent stop live read")
    let raw = try verifyBytes(live)
    statuses.append(live.statusCode())
    try require(durable_runtime_fixture.finish_edge_owner(owner, live, true), "close and delete only owned stop fixture")
    let closed = lattice.experimentalOwnedRead(owner, model: model, cursor: token, limits: bounds, stop: independent)
    let closedError = String(lattice.last_bridge_error().pointee)
    try require(closedError == "observation owner closed", "owning edge seals actual admission exception")
    try requireEdgeFailure(closed, 1); statuses.append(closed.statusCode())
    let stopped = lattice.experimentalOwnedRead(owner, model: model, cursor: token, limits: bounds, stop: original)
    try checkBridgeError("pre-cancelled alias before closed-owner/missing-file admission")
    try requireEdgeFailure(stopped, 12); statuses.append(stopped.statusCode())
    try require(!independent.isCancelled(), "no sibling stop cancellation")
    withExtendedLifetime(owner) {}
    withExtendedLifetime(live) {}
    return ["statuses": statuses, "closedError": closedError, "independentCancelled": false,
            "raw": raw, "edgeCounters": edgeNumbers()]
}
func runEdge() throws {
    let root = CommandLine.arguments[1]
    let raw = try exerciseEdgeCopies(root + "/edge.sqlite")
    try emit("SwiftOwningAPIRealPageAfterOwnerDestruction", raw)
    try require(durable_runtime_fixture.edge_owner_expired() && durable_runtime_fixture.edge_backing_expired(), "actual edge last handle destroys backing outside Swift function scope")
    try emit("SwiftOwningAPILastHandleReleasesBacking", ["ownerExpired": true, "backingExpired": true])
    var stops = try exerciseEdgeStops(root + "/edge-stop.sqlite")
    try require(durable_runtime_fixture.edge_owner_expired() && durable_runtime_fixture.edge_backing_expired(), "stop fixture owner/page lifetimes end outside Swift function scope")
    let c = durable_runtime_fixture.edge_statistics()
    try require(c.failures == 0 && c.owners == 2 && c.captures == 2 && c.oracle_reads == 2 && c.commits == 4 && c.closes == 2 && c.removed_files == 1, "exact supplemental fixture counters")
    try require(c.checkpoint_busy == 0 && c.checkpoint_log == 0 && c.checkpoint_done == 0, "supplemental checkpoint cleanup")
    stops["ownerExpired"] = true; stops["backingExpired"] = true
    try emit("SwiftOwningAPIValidationAndOperationStop", stops)
}

do { try main(); try runEdge() }
catch {
    FileHandle.standardError.write(Data("DURABLE_RUNTIME_FAILURE: \(error)\n".utf8))
    exit(1)
}
