#if LATTICE_EXPERIMENTAL_OWNED_READ
import Foundation
import Dispatch
import Testing
@testable import Lattice

private func ownedTestToken(frame: Bool = false) -> Data {
    let zero = String(repeating: "0", count: 32)
    let counter = String(repeating: "0", count: 15)
    return Data(("lrc1:" + (frame ? "f:" : "o:") + zero + ":" + zero + ":"
        + String(repeating: frame ? "a" : "-", count: 32) + ":"
        + counter + (frame ? "1:" : "0:") + counter + (frame ? "2" : "0")).utf8)
}
private func ownedTestTerminal(status: Int32 = 0, cleanup: Bool = true,
                               metadata: Int32 = 1) -> OwnedPageTerminal {
    OwnedPageTerminal(status: status, sqliteCode: 0, metadataStatus: metadata, cleanupOK: cleanup,
        boundaryFrameID: 1, boundaryFirstAuditID: 2, boundaryLastAuditID: 2,
        auditHead: 2, captureStartedAfter: 0, prunedThrough: 0)
}
private enum OwnedPageTestError: Error { case gateTimeout }
private final class OwnedPageTestGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func open() { semaphore.signal() }
    func wait() throws {
        guard semaphore.wait(timeout: .now() + 5) == .success else { throw OwnedPageTestError.gateTimeout }
    }
}
private final class OwnedPageTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func use<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock(); defer { lock.unlock() }; return body(&value)
    }
}
private final class OwnedPageTestStop: OwnedPageStop, @unchecked Sendable {
    let calls = OwnedPageTestBox(0)
    func cancel() { calls.use { $0 += 1 } }
}
private final class OwnedPageTestBackend: OwnedPageReadBackend, @unchecked Sendable {
    typealias Read = @Sendable (OwnedPageRequest, OwnedPageOperationState) throws -> OwnedAuditPage
    let readCount = OwnedPageTestBox(0)
    let stops = OwnedPageTestBox<[OwnedPageTestStop]>([])
    let body: Read
    let creationHook: @Sendable () throws -> Void
    init(onMakeStop: @escaping @Sendable () throws -> Void = {},
         _ body: @escaping Read = { try decodeOwnedPage(OwnedPageTestSource(), request: $0, state: $1) }) {
        self.body = body; creationHook = onMakeStop
    }
    func makeOwnedPageStop() throws -> any OwnedPageStop {
        let stop = OwnedPageTestStop(); stops.use { $0.append(stop) }
        try creationHook(); return stop
    }
    func readOwnedPage(_ request: OwnedPageRequest, state: OwnedPageOperationState) throws -> OwnedAuditPage {
        readCount.use { $0 += 1 }; return try body(request, state)
    }
    var cancellationCalls: Int { stops.use { $0.reduce(0) { $0 + $1.calls.use { $0 } } } }
}

private final class OwnedPageTestSource: OwnedPageByteSource {
    var terminal = ownedTestTerminal()
    var frameCount: UInt64 = 1
    var rowCount: UInt64 = 1
    var fields: [Data?] = [nil, Data(), Data([255, 0, 65]), Data("id".utf8), Data("names".utf8)]
    var textByteCount: UInt64 { UInt64(fields.reduce(0) { $0 + ($1?.count ?? 0) }) }
    var hasCursor = true
    var cursorByteCount: UInt64 = 139
    var atHead = true
    var token = ownedTestToken(frame: true)
    var header = OwnedPageFrameHeader(id: 1, firstAuditID: 2, lastAuditID: 2, rowOffset: 0, rowCount: 1)
    var calls = 0
    var failAt: Int?
    var onTextByte: ((UInt64) -> Void)?
    var textCopies = 0
    private func access() throws {
        calls += 1
        if calls == failAt { throw OwnedPageReadError.bridgeFailure(Data("injected".utf8)) }
    }
    func frame(_ index: UInt64) throws -> OwnedPageFrameHeader { try access(); return header }
    func frameKeyByte(frame: UInt64, byte: UInt64) throws -> UInt8 { try access(); return 97 }
    func auditID(row: UInt64) throws -> Int64 { try access(); return 2 }
    func integerField(row: UInt64, field: Int32) throws -> Int64? {
        try access(); return field == 0 ? nil : (field == 1 ? 2 : -1)
    }
    func textField(row: UInt64, field: Int32) throws -> OwnedPageTextField {
        try access(); let data = fields[Int(field)]
        return OwnedPageTextField(byteCount: UInt64(data?.count ?? 0), isNull: data == nil)
    }
    func textByte(row: UInt64, field: Int32, byte: UInt64) throws -> UInt8 {
        try access(); onTextByte?(byte); textCopies += 1
        return fields[Int(field)]![Int(byte)]
    }
    func snapshotIdentityByte(identity: Int32, byte: UInt64) throws -> UInt8 { try access(); return 48 }
    func cursorByte(_ byte: UInt64) throws -> UInt8 { try access(); return token[Int(byte)] }
}

@Suite("Private owned-page adapter source fixtures", .serialized)
struct OwnedPageReadTests {
    private func request(decodedBytes: Int = 1_048_576, timeout: UInt64 = 5_000) throws -> OwnedPageRequest {
        try OwnedPageRequest(model: "Rows", cursor: ownedTestToken(),
            limits: OwnedPageLimits(maxDecodedBytes: decodedBytes), timeoutMilliseconds: timeout)
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let end = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while !condition() {
            try #require(DispatchTime.now().uptimeNanoseconds < end, "synchronization gate did not settle")
            await Task.yield()
        }
    }
    private func expectCancellation<Value>(_ result: Result<Value, any Error>) {
        switch result {
        case .success: Issue.record("cancelled operation succeeded")
        case .failure(let error): #expect(error is CancellationError)
        }
    }

    @Test func canonicalCursorAndModelAdmissionRemainExact() throws {
        #expect(ownedCursorIsCanonical(ownedTestToken()))
        #expect(ownedCursorIsCanonical(ownedTestToken(frame: true)))
        var overflow = ownedTestToken(frame: true); overflow[106] = 56
        #expect(!ownedCursorIsCanonical(overflow))
        var uppercase = ownedTestToken(frame: true); uppercase[73] = 65
        #expect(!ownedCursorIsCanonical(uppercase))
        var trailing = ownedTestToken(); trailing.append(0)
        #expect(!ownedCursorIsCanonical(trailing))
        #expect(throws: OwnedPageReadError.invalidRequest) {
            try OwnedPageRequest(model: "_private", cursor: ownedTestToken(), limits: OwnedPageLimits())
        }
        #expect(throws: OwnedPageReadError.invalidRequest) {
            try OwnedPageRequest(model: "é", cursor: ownedTestToken(), limits: OwnedPageLimits())
        }
        _ = try OwnedPageRequest(model: "1Rows", cursor: ownedTestToken(), limits: OwnedPageLimits())
    }

    @Test func rawNullEmptyNulAndInvalidUTF8KeepExactBoundaryBudget() throws {
        let source = OwnedPageTestSource()
        let exact = OwnedPageDecodeBudget.pageCharge + OwnedPageDecodeBudget.frameCharge
            + OwnedPageDecodeBudget.rowCharge + Int(source.textByteCount)
        let state = OwnedPageOperationState(stop: OwnedPageTestStop())
        let value = try decodeOwnedPage(source, request: request(decodedBytes: exact), state: state)
        let row = try #require(value.frames.first?.rows.first)
        #expect(row.globalID == nil)
        #expect(row.tableName == Data())
        #expect(row.operation == Data([255, 0, 65]))
        #expect(row.rowID == nil && row.isFromRemote == 2 && row.synthesized == -1)
        #expect(value.nextCursor == ownedTestToken(frame: true))
        #expect(throws: OwnedPageReadError.decodedBudgetExceeded) {
            try decodeOwnedPage(OwnedPageTestSource(), request: request(decodedBytes: exact - 1),
                                state: OwnedPageOperationState(stop: OwnedPageTestStop()))
        }
    }

    @Test func oversizedDimensionsAndOverflowingRangesFailBeforePayloadCopy() throws {
        let source = OwnedPageTestSource(); source.frameCount = UInt64.max
        #expect(throws: OwnedPageReadError.invalidPage) {
            try decodeOwnedPage(source, request: request(), state: OwnedPageOperationState(stop: OwnedPageTestStop()))
        }
        #expect(source.textCopies == 0)
        source.frameCount = 1
        source.header = OwnedPageFrameHeader(id: 1, firstAuditID: 2, lastAuditID: 2,
                                             rowOffset: UInt64.max, rowCount: UInt64.max)
        #expect(throws: OwnedPageReadError.invalidPage) {
            try decodeOwnedPage(source, request: request(), state: OwnedPageOperationState(stop: OwnedPageTestStop()))
        }
        #expect(source.textCopies == 0)
    }

    @Test func failureDiagnosticsSurviveEarlyGetterErrorAndUnknownStatus() throws {
        let state = OwnedPageOperationState(stop: OwnedPageTestStop())
        let source = OwnedPageTestSource(); source.terminal = ownedTestTerminal(status: 17, cleanup: false)
        source.failAt = 1
        #expect(throws: OwnedPageReadError.bridgeFailure(Data("injected".utf8))) {
            try decodeOwnedPage(source, request: request(), state: state)
        }
        #expect(state.settledTerminal()?.cleanupOK == false)
        #expect(state.settledTerminal()?.boundaryLastAuditID == 2)
        #expect(state.settledTerminal()?.storeID == nil)
        let unknown = OwnedPageTestSource(); unknown.terminal = ownedTestTerminal(status: 99)
        do {
            _ = try decodeOwnedPage(unknown, request: request(), state: state)
            Issue.record("unknown native status became success")
        } catch OwnedPageReadError.nativeFailure(let diagnostic, _) {
            #expect(diagnostic.status == 99 && diagnostic.storeID?.count == 32)
        }
    }

    @Test func cancellationDuringLargeFieldStopsWithinOneCopyChunk() throws {
        let stop = OwnedPageTestStop(), source = OwnedPageTestSource()
        let state = OwnedPageOperationState(stop: stop)
        source.fields = [Data(repeating: 255, count: 4_096), nil, nil, nil, nil]
        source.onTextByte = { if $0 == 0 { state.cancel() } }
        #expect(throws: CancellationError.self) { try decodeOwnedPage(source, request: request(), state: state) }
        #expect(source.textCopies <= 256)
        state.cancel()
        #expect(stop.calls.use { $0 } == 1)
    }

    @Test func cancellationDuringStopCreationNeverStartsReader() async throws {
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 1)
        let backend = OwnedPageTestBackend(onMakeStop: { withUnsafeCurrentTask { $0?.cancel() } })
        let input = try request()
        let task = Task { try await readOwnedPage(backend: backend, request: input, executor: executor) }
        expectCancellation(await task.result)
        #expect(backend.stops.use { $0.count } == 1)
        #expect(backend.readCount.use { $0 } == 0 && backend.cancellationCalls == 0)
        await executor.shutdown()
    }

    @Test func emptyReadyPageKeepsCanonicalCursorAndFixedBudget() throws {
        let source = OwnedPageTestSource()
        source.frameCount = 0; source.rowCount = 0; source.fields = [nil, nil, nil, nil, nil]
        source.token = ownedTestToken()
        source.terminal = OwnedPageTerminal(status: 0, sqliteCode: 0, metadataStatus: 1, cleanupOK: true,
            boundaryFrameID: 0, boundaryFirstAuditID: 0, boundaryLastAuditID: 0,
            auditHead: 0, captureStartedAfter: 0, prunedThrough: 0)
        let value = try decodeOwnedPage(source, request: request(decodedBytes: OwnedPageDecodeBudget.pageCharge),
                                       state: OwnedPageOperationState(stop: OwnedPageTestStop()))
        #expect(value.frames.isEmpty && value.atHead && value.nextCursor == ownedTestToken())
    }

    @Test func canonicalButUnrelatedCursorCannotBePublished() throws {
        let source = OwnedPageTestSource(), input = try request()
        source.token[7] = 49 // still canonical, but a different store identity
        #expect(ownedCursorIsCanonical(source.token))
        #expect(throws: OwnedPageReadError.invalidPage) {
            try decodeOwnedPage(source, request: input, state: OwnedPageOperationState(stop: OwnedPageTestStop()))
        }
        source.token = ownedTestToken(frame: true)
        source.token[138] = 51 // canonical after3 differs from the frame endpoint2
        #expect(ownedCursorIsCanonical(source.token))
        #expect(throws: OwnedPageReadError.invalidPage) {
            try decodeOwnedPage(source, request: input, state: OwnedPageOperationState(stop: OwnedPageTestStop()))
        }
        #expect(input.cursor == ownedTestToken())
    }

    @Test(arguments: [Int32(4), 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17])
    func nativeFailuresRemainDistinctWithoutAdvancingInput(_ status: Int32) throws {
        let source = OwnedPageTestSource(), input = try request()
        source.terminal = ownedTestTerminal(status: status, cleanup: status != 17)
        source.hasCursor = false
        do {
            _ = try decodeOwnedPage(source, request: input, state: OwnedPageOperationState(stop: OwnedPageTestStop()))
            Issue.record("native failure published a page")
        } catch OwnedPageReadError.nativeFailure(let diagnostic, _) {
            #expect(diagnostic.status == status && diagnostic.storeID?.count == 32)
            #expect(diagnostic.boundaryLastAuditID == 2 && diagnostic.auditHead == 2)
        }
        #expect(input.cursor == ownedTestToken() && source.textCopies == 0)
    }

    @Test func cancelledRunningCleanupFailureWinsAndIndependentReadProgresses() async throws {
        let executor = ProjectionReadExecutor(workerCount: 2, maxPendingJobs: 2)
        let entered = OwnedPageTestBox(false), finished = OwnedPageTestBox(false)
        let cleanup = OwnedPageTestGate(); defer { cleanup.open() }
        let backend = OwnedPageTestBackend { _, state in
            state.record(ownedTestTerminal(status: 17, cleanup: false))
            entered.use { $0 = true }; try cleanup.wait()
            throw OwnedPageReadError.bridgeFailure(Data("cleanup getter".utf8))
        }
        let input = try request(), sibling = OwnedPageTestBackend()
        let task = Task {
            defer { finished.use { $0 = true } }
            return try await readOwnedPage(backend: backend, request: input, executor: executor)
        }
        try await waitUntil { entered.use { $0 } }
        task.cancel()
        try await waitUntil { backend.cancellationCalls == 1 }
        #expect(!finished.use { $0 })
        let siblingPage = try await readOwnedPage(backend: sibling, request: request(), executor: executor)
        #expect(siblingPage.frames.count == 1 && sibling.cancellationCalls == 0)
        cleanup.open()
        switch await task.result {
        case .success: Issue.record("cancelled operation published a page")
        case .failure(let error):
            guard case OwnedPageReadError.nativeFailure(let diagnostic, let reason) = error else {
                Issue.record("cleanup diagnostic was hidden by cancellation"); break
            }
            #expect(!diagnostic.cleanupOK && reason == .cancelled)
            #expect(diagnostic.bridgeFailure == Data("cleanup getter".utf8))
        }
        await executor.shutdown()
        #expect(executor.snapshot.liveWorkers == 0)
    }

    @Test func preCancelledQueuedFullExpiryAndShutdownDoNotReadRejectedBackend() async throws {
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 1)
        let backend = OwnedPageTestBackend(), input = try request()
        let preCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await readOwnedPage(backend: backend, request: input, executor: executor)
        }
        expectCancellation(await preCancelled.result)
        #expect(backend.readCount.use { $0 } == 0 && backend.stops.use { $0.isEmpty })
        let gate = OwnedPageTestGate(); defer { gate.open() }
        let entered = OwnedPageTestBox(false)
        let blocker = Task { try await executor.submit { entered.use { $0 = true }; try gate.wait(); return 1 } }
        try await waitUntil { entered.use { $0 } }
        let queued = Task { try await readOwnedPage(backend: backend, request: input, executor: executor) }
        try await waitUntil { executor.snapshot.pending == 1 }
        do {
            _ = try await readOwnedPage(backend: backend, request: input, executor: executor)
            Issue.record("full queue admitted a read")
        } catch { #expect(error as? ProjectionReadExecutorError == .queueFull) }
        queued.cancel(); expectCancellation(await queued.result)
        let admittedBeforeExpiry = executor.snapshot.queuedAdmissions
        let expiry = Task {
            let expiring = try request(timeout: 1_000)
            return try await readOwnedPage(backend: backend, request: expiring, executor: executor)
        }
        // Persistent admission/expiry counters distinguish real queue expiry
        // even when the test task misses the transient pending state.
        try await waitUntil { executor.snapshot.queuedAdmissions == admittedBeforeExpiry + 1 }
        switch await expiry.result {
        case .success: Issue.record("queued expiry published a page")
        case .failure(let error): #expect(error as? ProjectionReadExecutorError == .deadlineExceeded)
        }
        #expect(executor.snapshot.queuedDeadlineExpirations == 1)
        let onShutdown = Task { try await readOwnedPage(backend: backend, request: input, executor: executor) }
        try await waitUntil { executor.snapshot.pending == 1 }
        let drain = Task { await executor.shutdown() }
        switch await onShutdown.result {
        case .success: Issue.record("shutdown admitted a queued read")
        case .failure(let error): #expect(error as? ProjectionReadExecutorError == .shutdown)
        }
        #expect(backend.readCount.use { $0 } == 0 && backend.cancellationCalls == 0)
        gate.open(); _ = await blocker.result; await drain.value
        #expect(executor.snapshot.liveWorkers == 0 && executor.snapshot.pending == 0)
    }

    @Test(arguments: [false, true])
    func runningDeadlineWaitsForCleanupAndDiscardsLateSuccess(_ cleanupFails: Bool) async throws {
        let executor = ProjectionReadExecutor(workerCount: 1, maxPendingJobs: 1)
        let entered = OwnedPageTestBox(false), finished = OwnedPageTestBox(false)
        let cleanup = OwnedPageTestGate(); defer { cleanup.open() }
        let backend = OwnedPageTestBackend { input, state in
            let value = try decodeOwnedPage(OwnedPageTestSource(), request: input, state: state)
            if cleanupFails { state.record(ownedTestTerminal(status: 17, cleanup: false)) }
            entered.use { $0 = true }; try cleanup.wait()
            return value // deliberately late: executor must discard this value
        }
        let task = Task {
            defer { finished.use { $0 = true } }
            return try await readOwnedPage(backend: backend, request: request(timeout: 1_000), executor: executor)
        }
        try await waitUntil { entered.use { $0 } }
        try await waitUntil { backend.cancellationCalls == 1 }
        #expect(!finished.use { $0 })
        cleanup.open()
        switch await task.result {
        case .success: Issue.record("deadline published a late page")
        case .failure(let error):
            if cleanupFails {
                guard let owned = error as? OwnedPageReadError,
                      case .nativeFailure(let diagnostic, let reason) = owned else {
                    Issue.record("cleanup failure was hidden by deadline"); break
                }
                #expect(!diagnostic.cleanupOK && reason == .deadline)
            } else { #expect(error as? ProjectionReadExecutorError == .deadlineExceeded) }
        }
        await executor.shutdown()
        #expect(executor.snapshot.liveWorkers == 0)
    }
}
#endif
