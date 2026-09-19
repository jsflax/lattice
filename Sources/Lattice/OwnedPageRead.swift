#if LATTICE_EXPERIMENTAL_OWNED_READ
import Foundation
import Dispatch

// Private, default-off single-page transport. This does not enable framing,
// acknowledge delivery, persist a cursor, retry, or register an observer.
internal struct OwnedPageLimits: Sendable {
    let maxFrames: Int
    let maxRows: Int
    let maxNativeBytes: UInt64
    let maxDecodedBytes: Int
    let maxVMSteps: UInt64

    init(maxFrames: Int = 64, maxRows: Int = 1_024,
         maxNativeBytes: UInt64 = 1_048_576, maxDecodedBytes: Int = 1_048_576,
         maxVMSteps: UInt64 = 2_000_000) throws {
        guard (1...256).contains(maxFrames), (1...4_096).contains(maxRows),
              (1...8_388_608).contains(maxNativeBytes),
              (OwnedPageDecodeBudget.pageCharge...8_388_608).contains(maxDecodedBytes),
              (128...50_000_000).contains(maxVMSteps) else {
            throw OwnedPageReadError.invalidRequest
        }
        self.maxFrames = maxFrames; self.maxRows = maxRows
        self.maxNativeBytes = maxNativeBytes; self.maxDecodedBytes = maxDecodedBytes
        self.maxVMSteps = maxVMSteps
        // Exact native sizeof(page)+reserved arrays fit remains Core's check;
        // Swift layout sizes are not a substitute for the native ABI.
    }
}

internal struct OwnedPageRequest: Sendable {
    let operationID: UUID
    let model: String
    let cursor: Data
    let limits: OwnedPageLimits
    let deadlineNanoseconds: UInt64

    init(model: String, cursor: Data, limits: OwnedPageLimits,
         timeoutMilliseconds: UInt64 = 5_000) throws {
        let now = DispatchTime.now().uptimeNanoseconds
        guard (1...30_000).contains(timeoutMilliseconds),
              (1...64).contains(model.utf8.count), model.utf8.first != 95,
              model.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || $0 == 95 }),
              ownedCursorIsCanonical(cursor) else { throw OwnedPageReadError.invalidRequest }
        let (deadline, overflow) = now.addingReportingOverflow(timeoutMilliseconds * 1_000_000)
        guard !overflow else { throw OwnedPageReadError.invalidRequest }
        operationID = UUID()
        self.model = String(decoding: Array(model.utf8), as: UTF8.self)
        // Copy exactly the fixed transport, not a slice retaining a larger buffer.
        self.cursor = cursor.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: 139) }
        self.limits = limits; deadlineNanoseconds = deadline
    }
}

internal func ownedCursorIsCanonical(_ token: Data) -> Bool {
    guard token.count == 139 else { return false }
    let b = Array(token) // fixed 139 bytes, never an audit payload
    guard Array(b[0..<5]) == [108, 114, 99, 49, 58],
          [111, 102, 115].contains(b[5]), [6, 39, 72, 105, 122].allSatisfy({ b[$0] == 58 }) else { return false }
    func hex(_ range: Range<Int>) -> Bool {
        range.allSatisfy { (48...57).contains(b[$0]) || (97...102).contains(b[$0]) }
    }
    guard hex(7..<39), hex(40..<72), hex(106..<122), hex(123..<139),
          (48...55).contains(b[106]), (48...55).contains(b[123]) else { return false }
    let frameZero = (106..<122).allSatisfy { b[$0] == 48 }
    let afterZero = (123..<139).allSatisfy { b[$0] == 48 }
    let dashedKey = (73..<105).allSatisfy { b[$0] == 45 }
    if b[5] == 111 { return frameZero && afterZero && dashedKey }
    if b[5] == 115 && frameZero { return dashedKey }
    return !frameZero && !afterZero && hex(73..<105)
}

internal struct OwnedAuditSnapshot: Sendable, Equatable {
    let auditHead: Int64
    let captureStartedAfter: Int64
    let prunedThrough: Int64
    let storeID: Data
    let epoch: Data
}

internal struct OwnedPageTerminal: Sendable, Equatable {
    let status: Int32
    let sqliteCode: Int32
    let metadataStatus: Int32
    let cleanupOK: Bool
    let boundaryFrameID: Int64
    let boundaryFirstAuditID: Int64
    let boundaryLastAuditID: Int64
    let auditHead: Int64
    let captureStartedAfter: Int64
    let prunedThrough: Int64
    // Nil means extraction did not complete, not an invented zero identity.
    var storeID: Data? = nil
    var epoch: Data? = nil
    // Distinguishes a sealed exception from an ordinary diagnostic page even
    // when cleanup failure takes precedence over the executor's stop error.
    var bridgeFailure: Data? = nil
}

internal struct OwnedAuditRow: Sendable, Equatable {
    let auditID: Int64
    let rowID: Int64?
    let isFromRemote: Int64?
    let synthesized: Int64?
    let globalID: Data?
    let tableName: Data?
    let operation: Data?
    let globalRowID: Data?
    let changedFieldsNames: Data?
}

internal struct OwnedAuditFrame: Sendable, Equatable {
    let id: Int64
    let firstAuditID: Int64
    let lastAuditID: Int64
    let key: Data
    let rows: [OwnedAuditRow]
}

internal struct OwnedAuditPage: Sendable, Equatable {
    let operationID: UUID
    let frames: [OwnedAuditFrame]
    let snapshot: OwnedAuditSnapshot
    let nextCursor: Data
    let atHead: Bool
}

internal enum OwnedPageStopReason: Sendable, Equatable { case cancelled, deadline, shutdown }
internal enum OwnedPageReadError: Error, Sendable, Equatable {
    case invalidRequest
    case invalidPage
    case decodedBudgetExceeded
    // A bounded diagnostic prefix; audit headers are never string-decoded.
    case bridgeFailure(Data)
    case nativeFailure(OwnedPageTerminal, stopping: OwnedPageStopReason?)
}

internal protocol OwnedPageStop: Sendable { func cancel() }
internal protocol OwnedPageReadBackend: Sendable {
    func makeOwnedPageStop() throws -> any OwnedPageStop
    func readOwnedPage(_ request: OwnedPageRequest, state: OwnedPageOperationState) throws -> OwnedAuditPage
}

/// Only the stop's native atomic flag crosses threads. Metadata is lock-owned;
/// no native page, reader, mutable native operation or callback lives here.
internal final class OwnedPageOperationState: @unchecked Sendable {
    let stop: any OwnedPageStop
    private let lock = NSLock()
    private var cancelled = false
    private var terminal: OwnedPageTerminal?
    init(stop: any OwnedPageStop) { self.stop = stop }

    func cancel() {
        lock.lock()
        let first = !cancelled
        cancelled = true
        lock.unlock()
        if first { stop.cancel() } // exactly the operation-local atomic signal
    }

    func record(_ value: OwnedPageTerminal) {
        lock.lock(); terminal = value; lock.unlock()
    }

    func settledTerminal() -> OwnedPageTerminal? {
        lock.lock(); defer { lock.unlock() }; return terminal
    }

    func recordBridgeFailure(_ error: any Error) {
        guard let owned = error as? OwnedPageReadError,
              case .bridgeFailure(let prefix) = owned else { return }
        lock.lock(); terminal?.bridgeFailure = Data(prefix.prefix(512)); lock.unlock()
    }

    func check(_ deadline: UInt64) throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw CancellationError() }
        if DispatchTime.now().uptimeNanoseconds >= deadline {
            throw ProjectionReadExecutorError.deadlineExceeded
        }
    }
}

internal func readOwnedPage(backend: any OwnedPageReadBackend, request: OwnedPageRequest,
                            executor: ProjectionReadExecutor) async throws -> OwnedAuditPage {
    let retainedBackend = backend // retain BEFORE stop creation and queue submission
    try Task.checkCancellation()
    guard DispatchTime.now().uptimeNanoseconds < request.deadlineNanoseconds else {
        throw ProjectionReadExecutorError.deadlineExceeded
    }
    let state = OwnedPageOperationState(stop: try retainedBackend.makeOwnedPageStop())
    do {
        return try await executor.submit(deadline: request.deadlineNanoseconds,
            onCancel: { state.cancel() }) { [retainedBackend, state, request] in
                do {
                    try state.check(request.deadlineNanoseconds)
                    let value = try retainedBackend.readOwnedPage(request, state: state)
                    try state.check(request.deadlineNanoseconds)
                    return value
                } catch {
                    state.recordBridgeFailure(error)
                    throw error
                }
            }
    } catch {
        // submit returns only after worker cleanup AND its interrupt return.
        // Its stop override must never turn rollback/cleanup failure into an
        // ordinary cancellation/deadline. Queued rejection has no terminal.
        if let terminal = state.settledTerminal(), !terminal.cleanupOK {
            let reason: OwnedPageStopReason?
            if error is CancellationError { reason = .cancelled }
            else if error as? ProjectionReadExecutorError == .deadlineExceeded { reason = .deadline }
            else if error as? ProjectionReadExecutorError == .shutdown { reason = .shutdown }
            else { reason = nil }
            throw OwnedPageReadError.nativeFailure(terminal, stopping: reason)
        }
        throw error
    }
}

internal struct OwnedPageFrameHeader {
    let id: Int64, firstAuditID: Int64, lastAuditID: Int64
    let rowOffset: UInt64, rowCount: UInt64
}
internal struct OwnedPageTextField { let byteCount: UInt64; let isNull: Bool }

// Worker-local seam for bounded decoder fixtures. Deliberately not Sendable:
// native page wrappers cannot be stored in jobs/results through this protocol.
internal protocol OwnedPageByteSource {
    var terminal: OwnedPageTerminal { get }
    var frameCount: UInt64 { get }
    var rowCount: UInt64 { get }
    var textByteCount: UInt64 { get }
    var hasCursor: Bool { get }
    var cursorByteCount: UInt64 { get }
    var atHead: Bool { get }
    func frame(_ index: UInt64) throws -> OwnedPageFrameHeader
    func frameKeyByte(frame: UInt64, byte: UInt64) throws -> UInt8
    func auditID(row: UInt64) throws -> Int64
    func integerField(row: UInt64, field: Int32) throws -> Int64?
    func textField(row: UInt64, field: Int32) throws -> OwnedPageTextField
    func textByte(row: UInt64, field: Int32, byte: UInt64) throws -> UInt8
    func snapshotIdentityByte(identity: Int32, byte: UInt64) throws -> UInt8
    func cursorByte(_ byte: UInt64) throws -> UInt8
}

/// Explicit payload/descriptor accounting, not MemoryLayout or RSS. Fixed
/// charges include optional tags and nested array/Data descriptors. Allocator
/// bookkeeping and caller-retained returned values are not globally capped.
internal struct OwnedPageDecodeBudget {
    static let pageCharge = 512 + 64 + 139 // includes fixed cursor-validation scratch
    static let frameCharge = 96 // includes the 32-byte frame key
    static let rowCharge = 192 // includes three nullable ints and five Data tags
    private(set) var remaining: Int
    init(_ limit: Int) { remaining = limit }
    mutating func charge(_ count: Int, each: Int = 1) throws {
        guard count >= 0, each > 0, count <= remaining / each else {
            throw OwnedPageReadError.decodedBudgetExceeded
        }
        remaining -= count * each
    }
}

internal func decodeOwnedPage(_ source: any OwnedPageByteSource, request: OwnedPageRequest,
                              state: OwnedPageOperationState) throws -> OwnedAuditPage {
    var terminal = source.terminal
    state.record(terminal) // first, even if a subsequent sealed getter fails
    var budget = OwnedPageDecodeBudget(request.limits.maxDecodedBytes)
    try budget.charge(OwnedPageDecodeBudget.pageCharge)
    // Fixed 64 bytes preserve failure snapshots. No large decode happens
    // before status/cleanup checks; this bounded copy needs no cancellation.
    var store = Data(capacity: 32), epoch = Data(capacity: 32)
    for i in 0..<32 { store.append(try source.snapshotIdentityByte(identity: 0, byte: UInt64(i))) }
    for i in 0..<32 { epoch.append(try source.snapshotIdentityByte(identity: 1, byte: UInt64(i))) }
    terminal.storeID = store; terminal.epoch = epoch; state.record(terminal)
    guard terminal.cleanupOK, terminal.status == 0, (0...11).contains(terminal.metadataStatus) else {
        throw OwnedPageReadError.nativeFailure(terminal, stopping: nil)
    }
    try state.check(request.deadlineNanoseconds)
    let count = source.frameCount, rows = source.rowCount
    guard count <= UInt64(request.limits.maxFrames), rows <= UInt64(request.limits.maxRows),
          count <= 256, rows <= 4_096, source.hasCursor, source.cursorByteCount == 139,
          source.textByteCount <= request.limits.maxNativeBytes else { throw OwnedPageReadError.invalidPage }
    try budget.charge(Int(count), each: OwnedPageDecodeBudget.frameCharge)
    try budget.charge(Int(rows), each: OwnedPageDecodeBudget.rowCharge)
    var frames: [OwnedAuditFrame] = []; frames.reserveCapacity(Int(count))
    var offset: UInt64 = 0, previousFrame: Int64 = 0, previousAudit: Int64 = 0
    var copiedText: UInt64 = 0

    func bytes(_ size: Int, get: (UInt64) throws -> UInt8) throws -> Data {
        try state.check(request.deadlineNanoseconds)
        var result = Data(capacity: size)
        for i in 0..<size {
            if i % 256 == 0 { try state.check(request.deadlineNanoseconds) }
            result.append(try get(UInt64(i)))
        }
        try state.check(request.deadlineNanoseconds)
        return result
    }
    func text(row: UInt64, field: Int32) throws -> Data? {
        try state.check(request.deadlineNanoseconds)
        let descriptor = try source.textField(row: row, field: field)
        if descriptor.isNull {
            guard descriptor.byteCount == 0 else { throw OwnedPageReadError.invalidPage }
            return nil
        }
        guard copiedText <= source.textByteCount,
              descriptor.byteCount <= source.textByteCount - copiedText,
              let size = Int(exactly: descriptor.byteCount) else { throw OwnedPageReadError.invalidPage }
        try budget.charge(size) // before Data capacity or payload copying
        copiedText += descriptor.byteCount
        return try bytes(size) { try source.textByte(row: row, field: field, byte: $0) }
    }
    for index in 0..<count {
        try state.check(request.deadlineNanoseconds)
        let header = try source.frame(index)
        guard header.id > previousFrame, header.firstAuditID > previousAudit,
              header.lastAuditID >= header.firstAuditID, header.rowOffset == offset,
              offset <= rows, header.rowCount > 0, header.rowCount <= rows - offset else {
            throw OwnedPageReadError.invalidPage
        }
        let key = try bytes(32) { try source.frameKeyByte(frame: index, byte: $0) }
        var frameRows: [OwnedAuditRow] = []; frameRows.reserveCapacity(Int(header.rowCount))
        for j in 0..<header.rowCount {
            try state.check(request.deadlineNanoseconds)
            let row = offset + j
            let id = try source.auditID(row: row)
            guard id > previousAudit, id >= header.firstAuditID, id <= header.lastAuditID,
                  j != 0 || id == header.firstAuditID,
                  j != header.rowCount - 1 || id == header.lastAuditID else { throw OwnedPageReadError.invalidPage }
            previousAudit = id
            try state.check(request.deadlineNanoseconds)
            let rowID = try source.integerField(row: row, field: 0)
            try state.check(request.deadlineNanoseconds)
            let remote = try source.integerField(row: row, field: 1)
            try state.check(request.deadlineNanoseconds)
            let synthesized = try source.integerField(row: row, field: 2)
            frameRows.append(OwnedAuditRow(auditID: id, rowID: rowID, isFromRemote: remote,
                synthesized: synthesized, globalID: try text(row: row, field: 0),
                tableName: try text(row: row, field: 1), operation: try text(row: row, field: 2),
                globalRowID: try text(row: row, field: 3), changedFieldsNames: try text(row: row, field: 4)))
        }
        offset += header.rowCount; previousFrame = header.id
        frames.append(OwnedAuditFrame(id: header.id, firstAuditID: header.firstAuditID,
            lastAuditID: header.lastAuditID, key: key, rows: frameRows))
    }
    guard offset == rows, copiedText == source.textByteCount else { throw OwnedPageReadError.invalidPage }
    let token = try bytes(139) { try source.cursorByte($0) }
    guard ownedCursorIsCanonical(token) else { throw OwnedPageReadError.invalidPage }
    try state.check(request.deadlineNanoseconds)
    let output = Array(token) // each validation copy is exactly 139 bytes
    try state.check(request.deadlineNanoseconds)
    let input = Array(request.cursor)
    func counter(_ bytes: [UInt8], at start: Int) -> Int64 {
        // Canonical validation already proved lowercase hex and Int64 range.
        (start..<(start + 16)).reduce(Int64(0)) { value, index in
            value * 16 + Int64(bytes[index] <= 57 ? bytes[index] - 48 : bytes[index] - 87)
        }
    }
    let nextAfter = counter(output, at: 123)
    guard store.elementsEqual(output[7..<39]), epoch.elementsEqual(output[40..<72]),
          store.elementsEqual(input[7..<39]), epoch.elementsEqual(input[40..<72]),
          terminal.auditHead >= 0, nextAfter <= terminal.auditHead else { throw OwnedPageReadError.invalidPage }
    if let first = frames.first, let last = frames.last {
        guard output[5] == 102, counter(output, at: 106) == last.id,
              nextAfter == last.lastAuditID, last.key.elementsEqual(output[73..<105]),
              first.id > counter(input, at: 106), first.firstAuditID > counter(input, at: 123),
              last.lastAuditID <= terminal.auditHead else { throw OwnedPageReadError.invalidPage }
    } else {
        guard source.atHead, token == request.cursor else { throw OwnedPageReadError.invalidPage }
    }
    if source.atHead && nextAfter != terminal.auditHead { throw OwnedPageReadError.invalidPage }
    try state.check(request.deadlineNanoseconds)
    return OwnedAuditPage(operationID: request.operationID, frames: frames,
        snapshot: OwnedAuditSnapshot(auditHead: terminal.auditHead,
            captureStartedAfter: terminal.captureStartedAfter, prunedThrough: terminal.prunedThrough,
            storeID: store, epoch: epoch), nextCursor: token, atHead: source.atHead)
}
#endif
