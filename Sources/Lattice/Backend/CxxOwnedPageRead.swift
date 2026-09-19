#if LATTICE_EXPERIMENTAL_OWNED_READ
import Foundation
import Dispatch
import LatticeSwiftCppBridge
import CxxStdlib

// The qualification build must also define the matching C++ feature macro
// and FRT1 owner ABI. This import path is not qualified by page-only fixtures.
extension CxxBackend: OwnedPageReadBackend {
    func makeOwnedPageStop() throws -> any OwnedPageStop {
        let stop = lattice.experimental_durable_stop_control.make()
        try checkOwnedPageBridgeError()
        guard stop.isValid() else { throw OwnedPageReadError.invalidRequest }
        return CxxOwnedPageStop(stop)
    }

    func readOwnedPage(_ request: OwnedPageRequest, state: OwnedPageOperationState) throws -> OwnedAuditPage {
        guard let stop = state.stop as? CxxOwnedPageStop else { throw OwnedPageReadError.invalidRequest }
        try state.check(request.deadlineNanoseconds)
        var limits = lattice.experimental_owned_read_limits()
        limits.max_frames = UInt64(request.limits.maxFrames)
        limits.max_rows = UInt64(request.limits.maxRows)
        limits.max_bytes = request.limits.maxNativeBytes
        limits.max_vm_steps = request.limits.maxVMSteps
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < request.deadlineNanoseconds else { throw ProjectionReadExecutorError.deadlineExceeded }
        let remaining = request.deadlineNanoseconds - now
        let milliseconds = remaining / 1_000_000 + (remaining % 1_000_000 == 0 ? 0 : 1)
        guard (1...30_000).contains(milliseconds) else { throw OwnedPageReadError.invalidRequest }
        limits.timeout_ms = Int64(milliseconds)
        // Canonical validation guarantees ASCII, so this fixed cursor bridge
        // is lossless. Audit fields use byte getters, never String conversion.
        let page = lattice.experimentalOwnedRead(ref, model: std.string(request.model),
            cursor: std.string(String(decoding: request.cursor, as: UTF8.self)),
            limits: limits, stop: stop.native)
        let entryFailure = ownedPageBridgeFailure() // before ANY other sealed call
        let source = CxxOwnedPageSource(page: page)
        state.record(source.terminal) // preserve cleanup before throwing entry error
        if let entryFailure { throw OwnedPageReadError.bridgeFailure(entryFailure) }
        // Synchronous helper scope: the native page/backing dies before this
        // worker returns the owner-independent Swift DTO. It contains no reader.
        return try decodeOwnedPage(source, request: request, state: state)
    }
}

/// Immutable native handle, shared only for its operation-local atomic flag.
private final class CxxOwnedPageStop: OwnedPageStop, @unchecked Sendable {
    let native: lattice.experimental_durable_stop_control
    init(_ native: lattice.experimental_durable_stop_control) { self.native = native }
    func cancel() { native.cancel() }
}

private func ownedPageBridgeFailure() -> Data? {
    // Copy immediately on this thread, before another sealed helper can clear
    // TLS. The explicit length keeps embedded NUL and bounds even temporary
    // error-copy allocation. Swift's C++ importer exposes the raw data accessor
    // used by CxxStdlib; the TLS storage stays alive and unchanged until Data
    // has copied this prefix. No interior pointer escapes this scope.
    let slot = lattice.last_bridge_error()
    let count = min(512, Int(clamping: slot.pointee.size()))
    guard count > 0 else { return nil }
    return Data(buffer: UnsafeBufferPointer(start: slot.pointee.__dataUnsafe(), count: count))
}
private func checkOwnedPageBridgeError() throws {
    if let error = ownedPageBridgeFailure() { throw OwnedPageReadError.bridgeFailure(error) }
}

private struct CxxOwnedPageSource: OwnedPageByteSource {
    let page: lattice.experimental_durable_page
    var terminal: OwnedPageTerminal {
        let d = page.result(), s = page.snapshot() // fixed, nonsealed/noexcept
        return OwnedPageTerminal(status: d.status, sqliteCode: d.sqlite_code,
            metadataStatus: d.metadata_status, cleanupOK: d.cleanup_ok,
            boundaryFrameID: d.boundary_frame_id, boundaryFirstAuditID: d.boundary_first_audit_id,
            boundaryLastAuditID: d.boundary_last_audit_id, auditHead: s.audit_head,
            captureStartedAfter: s.capture_started_after, prunedThrough: s.pruned_through)
    }
    var frameCount: UInt64 { page.frameCount() }
    var rowCount: UInt64 { page.rowCount() }
    var textByteCount: UInt64 { page.textBytes() }
    var hasCursor: Bool { page.hasCursor() }
    var cursorByteCount: UInt64 { page.cursorByteCount() }
    var atHead: Bool { page.atHead() }
    func frame(_ index: UInt64) throws -> OwnedPageFrameHeader {
        let value = page.frame(index); try checkOwnedPageBridgeError()
        return OwnedPageFrameHeader(id: value.id, firstAuditID: value.first_audit_id,
            lastAuditID: value.last_audit_id, rowOffset: value.row_offset, rowCount: value.row_count)
    }
    func frameKeyByte(frame: UInt64, byte: UInt64) throws -> UInt8 {
        let value = page.frameKeyByte(frame: frame, byte: byte); try checkOwnedPageBridgeError(); return value
    }
    func auditID(row: UInt64) throws -> Int64 {
        let value = page.auditId(row: row); try checkOwnedPageBridgeError(); return value
    }
    func integerField(row: UInt64, field: Int32) throws -> Int64? {
        let value = page.integerField(row: row, field: field); try checkOwnedPageBridgeError()
        return value.is_null ? nil : value.value
    }
    func textField(row: UInt64, field: Int32) throws -> OwnedPageTextField {
        let value = page.textField(row: row, field: field); try checkOwnedPageBridgeError()
        return OwnedPageTextField(byteCount: value.byte_count, isNull: value.is_null)
    }
    func textByte(row: UInt64, field: Int32, byte: UInt64) throws -> UInt8 {
        let value = page.textByte(row: row, field: field, byte: byte); try checkOwnedPageBridgeError(); return value
    }
    func snapshotIdentityByte(identity: Int32, byte: UInt64) throws -> UInt8 {
        let value = page.snapshotIdentityByte(identity: identity, byte: byte)
        try checkOwnedPageBridgeError(); return value
    }
    func cursorByte(_ byte: UInt64) throws -> UInt8 {
        let value = page.cursorByte(byte); try checkOwnedPageBridgeError(); return value
    }
}
#endif
