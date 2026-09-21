import Foundation
import Testing
@testable import Lattice
@testable import LatticeServerKit

// No production changes or return-time substitute for the causal WAL probe.
enum SyncVisibilityClock {
    static func now() -> UInt64 {
        #if LATTICE_SYNC_COMMIT_PROBE
        return lattice.sync_commit_probe_clock_ns()
        #else
        return DispatchTime.now().uptimeNanoseconds
        #endif
    }
    static var name: String {
        #if LATTICE_SYNC_COMMIT_PROBE
        "native-steady-ns/tagged-WAL-entry"
        #else
        "dispatch-uptime/no-probe"
        #endif
    }
    static var hasProbe: Bool {
        #if LATTICE_SYNC_COMMIT_PROBE
        true
        #else
        false
        #endif
    }
}

enum SyncVisibilityFailure: Error { case invalid(String) }

@Model final class SyncVisibilityObject {
    var operationID: String = ""
    var runID: String = ""
    var stream: String = ""
    var phase: String = ""
    var writer: Int = 0
    var sequence: Int = 0
    var content: String = ""
    var expectedValue: String = ""
    var project: String = ""
    var topic: String = ""
    var source: String = ""

    init(_ expected: SyncVisibilityExpected) {
        operationID = expected.id; runID = expected.runID
        stream = expected.stream; phase = expected.phase
        writer = expected.writer; sequence = expected.sequence
        content = expected.content; expectedValue = expected.expectedValue
        project = expected.project; topic = expected.topic; source = expected.source
    }
}

struct SyncVisibilityExpected: Sendable, Equatable {
    let id: String, runID: String, stream: String, phase: String
    let writer: Int, sequence: Int
    let content: String, expectedValue: String, project: String, topic: String, source: String

    init(runID: String, stream: String, phase: String, writer: Int, sequence: Int, bytes: Int) {
        id = "\(runID)/\(stream)/\(phase)/\(writer)/\(sequence)"
        self.runID = runID; self.stream = stream; self.phase = phase
        self.writer = writer; self.sequence = sequence
        content = String(repeating: String(UnicodeScalar(97 + (writer + sequence) % 26)!), count: bytes)
        expectedValue = "immutable:\(stream):\(writer):\(sequence):\(phase)"
        project = "visibility-fixture"; topic = stream; source = "writer-\(writer)"
    }

    // Only a model observer's exact primary-key read may construct this value.
    init(_ row: SyncVisibilityObject) {
        id = row.operationID; runID = row.runID; stream = row.stream; phase = row.phase
        writer = row.writer; sequence = row.sequence; content = row.content
        expectedValue = row.expectedValue; project = row.project; topic = row.topic; source = row.source
    }
}

struct SyncVisibilityReceipt: Codable, Sendable {
    let id: String, token: UInt64, runID: String, stream: String, phase: String
    let writer: Int, sequence: Int, writerStoreID: String
    var readerStoreID: String?, observedID: String?
    var scheduledNS: UInt64?, offeredNS: UInt64?, writeStartNS: UInt64?, writeReturnNS: UInt64?
    var observationDeadlineNS: UInt64?
    var probeArmedNS: UInt64?, postcommitNS: UInt64?, firstExactReadNS: UInt64?, lateExactReadNS: UInt64?
    var armStatus: Int?, probeStatus: Int?
    var probeOperationID: UInt64?, probeAttemptID: UInt64?, probeOwnerID: UInt64?
    var probeConnectionID: UInt64?, probeThreadID: UInt64?
    var ignoredOwnerCommits: UInt64?, ignoredSchemaCommits: UInt64?
    var valueMatch: Bool?
    var valueMismatchCount = 0, duplicateCallbacks = 0
    var writeError: String?
    var timedOut = false
}

struct SyncVisibilityCounters: Codable, Sendable {
    var unknownOperation = 0, duplicateCallbacks = 0, valueMismatch = 0, readMiss = 0
    var diagnosticOverflow = 0, malformedObservation = 0
    var rawSyncStateTrue = 0, rawSyncStateFalse = 0, rawSyncErrors = 0
}

struct SyncVisibilityProbe: Sendable {
    var armStatus: Int?, status: Int?
    var operation: UInt64?, attempt: UInt64?, owner: UInt64?, connection: UInt64?, thread: UInt64?
    var armed: UInt64?, postcommit: UInt64?, ignoredOwner: UInt64?, ignoredSchema: UInt64?
}

/// Fixed receipt storage and lookup are allocated before offering any writes.
/// No raw frame bodies, growing callback list, per-operation logs or table scans.
final class SyncVisibilityRecorder: @unchecked Sendable {
    let expected: [SyncVisibilityExpected]
    private let indices: [String: Int]
    private let lock = NSLock()
    private var receipts: [SyncVisibilityReceipt]
    private var counters = SyncVisibilityCounters()
    private var errors: [String] = []
    private var frozenPhases: Set<String> = []
    private let expectedByPhase: [String: Int]
    private var visibleByPhase: [String: Int] = ["warmup": 0, "measured": 0]

    init(expected: [SyncVisibilityExpected]) {
        self.expected = expected
        expectedByPhase = Dictionary(grouping: expected, by: \.phase).mapValues(\.count)
        indices = Dictionary(uniqueKeysWithValues: expected.enumerated().map { ($0.element.id, $0.offset) })
        receipts = expected.enumerated().map { index, value in
            .init(id: value.id, token: UInt64(index + 1), runID: value.runID,
                  stream: value.stream, phase: value.phase, writer: value.writer, sequence: value.sequence,
                  writerStoreID: "clients/\(value.stream)-writer-\(value.writer).sqlite")
        }
        errors.reserveCapacity(64)
    }

    func schedule(_ index: Int, at time: UInt64, deadline: UInt64) {
        lock.withLock { receipts[index].scheduledNS = time; receipts[index].observationDeadlineNS = deadline }
    }
    func offered(_ index: Int) { let now = SyncVisibilityClock.now(); lock.withLock { receipts[index].offeredNS = now } }
    func started(_ index: Int) { let now = SyncVisibilityClock.now(); lock.withLock { receipts[index].writeStartNS = now } }
    func finished(_ index: Int, at time: UInt64, probe: SyncVisibilityProbe, error: String?) {
        lock.withLock {
            receipts[index].writeReturnNS = time; receipts[index].writeError = error.map { String($0.prefix(512)) }
            receipts[index].armStatus = probe.armStatus; receipts[index].probeStatus = probe.status
            receipts[index].probeArmedNS = probe.armed
            receipts[index].postcommitNS = probe.postcommit
            receipts[index].probeOperationID = probe.operation; receipts[index].probeAttemptID = probe.attempt
            receipts[index].probeOwnerID = probe.owner; receipts[index].probeConnectionID = probe.connection
            receipts[index].probeThreadID = probe.thread
            receipts[index].ignoredOwnerCommits = probe.ignoredOwner; receipts[index].ignoredSchemaCommits = probe.ignoredSchema
        }
    }
    func observed(_ value: SyncVisibilityExpected, at time: UInt64, readerStoreID: String? = nil) {
        lock.withLock {
            guard !value.id.isEmpty, !value.runID.isEmpty else { counters.malformedObservation += 1; return }
            guard let index = indices[value.id] else { counters.unknownOperation += 1; return }
            // Keep the first observation's provenance; duplicate callbacks may
            // increment counters but cannot replace the original reader.
            if receipts[index].observedID == nil {
                receipts[index].observedID = value.id; receipts[index].readerStoreID = readerStoreID
            }
            guard value == expected[index] else {
                counters.valueMismatch += 1; receipts[index].valueMismatchCount += 1
                receipts[index].valueMatch = false; return
            }
            if receipts[index].firstExactReadNS != nil || receipts[index].lateExactReadNS != nil {
                counters.duplicateCallbacks += 1; receipts[index].duplicateCallbacks += 1; return
            }
            receipts[index].valueMatch = receipts[index].valueMismatchCount == 0
            if frozenPhases.contains(value.phase) || receipts[index].observationDeadlineNS.map({ time > $0 }) == true {
                receipts[index].lateExactReadNS = time
            } else {
                receipts[index].firstExactReadNS = time
                if receipts[index].valueMatch == true { visibleByPhase[value.phase, default: 0] += 1 }
            }
        }
    }
    func readMiss() { lock.withLock { counters.readMiss += 1 } }
    func error(_ message: String) {
        lock.withLock {
            if errors.count < 64 { errors.append(String(message.prefix(512))) }
            else { counters.diagnosticOverflow += 1 }
        }
    }
    func syncState(_ connected: Bool) {
        lock.withLock { if connected { counters.rawSyncStateTrue += 1 } else { counters.rawSyncStateFalse += 1 } }
    }
    func syncError(_ message: String) { lock.withLock { counters.rawSyncErrors += 1 }; error("sync: " + message) }
    func allVisible(phase: String) -> Bool {
        lock.withLock {
            counters.unknownOperation == 0 && counters.valueMismatch == 0 && counters.malformedObservation == 0
                && visibleByPhase[phase, default: 0] == expectedByPhase[phase, default: 0]
        }
    }
    func freeze(phase: String) {
        lock.withLock {
            frozenPhases.insert(phase)
            for index in receipts.indices where receipts[index].phase == phase {
                receipts[index].timedOut = receipts[index].firstExactReadNS == nil
            }
        }
    }
    func snapshot() -> ([SyncVisibilityReceipt], SyncVisibilityCounters, [String]) {
        lock.withLock { (receipts, counters, errors) }
    }
}

/// Native operations use the existing big-stack worker implementation, on a
/// test-owned pool. Each driver awaits its own local write, never peer visibility.
func syncVisibilityOnWorker<T: Sendable>(pool: RelayExecutionPool, key: String,
                                         _ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        guard pool.submit(for: key, {
            do { continuation.resume(returning: try body()) }
            catch { continuation.resume(throwing: error) }
        }) else {
            continuation.resume(throwing: SyncVisibilityFailure.invalid("driver pool admission closed")); return
        }
    }
}

/// SQL reads from public observer callbacks and explicit close cannot overlap.
/// Cancellation first denies new reads, unregisters the observer, then drains
/// reads already admitted. No callback closes its own native owner.
final class SyncVisibilityClient: @unchecked Sendable {
    let key: String
    private let stream: String
    private let condition = NSCondition()
    private var db: Lattice?
    private var acceptingReads = true
    private var activeReads = 0
    private var cancelObservation: (() -> Void)?

    init(key: String, stream: String, configuration: Lattice.Configuration, recorder: SyncVisibilityRecorder, watches: Bool) throws {
        self.key = key; self.stream = stream
        let opened = try Lattice(isolation: nil, for: [SyncVisibilityObject.self], configuration: configuration)
        db = opened
        opened.onSyncError { recorder.syncError($0) }
        opened.onSyncStateChange { recorder.syncState($0) }
        if watches {
            let token = opened.observe(SyncVisibilityObject.self,
                where: Optional<LatticePredicate<SyncVisibilityObject>>.none) { [weak self] change in
                switch change {
                case .insert(let id), .update(let id): self?.read(id, recorder: recorder)
                case .delete: recorder.error("unexpected delete in immutable workload")
                }
            }
            cancelObservation = { token.cancel() }
        }
    }

    private func read(_ id: Int64, recorder: SyncVisibilityRecorder) {
        condition.lock()
        guard acceptingReads, let handle = db else { condition.unlock(); return }
        activeReads += 1; condition.unlock()
        defer { condition.lock(); activeReads -= 1; condition.broadcast(); condition.unlock() }
        guard let row = handle.object(isolation: nil, SyncVisibilityObject.self, primaryKey: id) else {
            recorder.readMiss(); return
        }
        let exact = SyncVisibilityExpected(row)
        let time = SyncVisibilityClock.now()
        guard exact.stream == stream else {
            recorder.error("operation arrived at wrong public watcher: \(key)"); return
        }
        recorder.observed(exact, at: time, readerStoreID: "clients/\(key).sqlite")
        withExtendedLifetime((handle, row)) {}
    }

    func write(index: Int, recorder: SyncVisibilityRecorder) {
        // Called only on this client's serial driver lane; teardown follows all drivers.
        guard let handle = db else { recorder.error("write on closed driver"); return }
        let expected = recorder.expected[index]
        let token = UInt64(index + 1)
        recorder.started(index)
        let row = SyncVisibilityObject(expected)
        var probe = SyncVisibilityProbe(), failure: String?
        var returned: UInt64 = 0
        defer {
            #if LATTICE_SYNC_COMMIT_PROBE
            // Finish even on failed BEGIN/body/arm/commit; never leave TLS armed.
            let receipt = handle.cxxLatticeRef.syncCommitProbeFinish(operation: token, attempt: 1)
            probe.status = Int(receipt.status)
            probe.operation = receipt.operation_id; probe.attempt = receipt.attempt_id
            probe.owner = receipt.owner_identity; probe.connection = receipt.connection_identity
            probe.thread = receipt.thread_identity
            probe.armed = receipt.armed_ns
            if receipt.status == 0 { probe.postcommit = receipt.postcommit_ns }
            probe.ignoredOwner = receipt.ignored_owner_commits; probe.ignoredSchema = receipt.ignored_schema_commits
            #endif
            recorder.finished(index, at: returned, probe: probe, error: failure)
            withExtendedLifetime((handle, row)) {}
        }
        do {
            try handle.withTransaction(isolation: nil) {
                try handle.add(row)
                #if LATTICE_SYNC_COMMIT_PROBE
                let status = handle.cxxLatticeRef.syncCommitProbeArm(operation: token, attempt: 1)
                probe.armStatus = Int(status)
                guard status == 0 else { throw SyncVisibilityFailure.invalid("probe arm status \(status)") }
                #endif
                // No SQL, suspension or application callback after successful arm.
            }
        } catch { failure = String(describing: error) }
        returned = SyncVisibilityClock.now()
    }

    func stopAndClose() {
        condition.lock(); acceptingReads = false
        let cancel = cancelObservation; cancelObservation = nil; condition.unlock()
        cancel?()
        condition.lock()
        while activeReads != 0 { condition.wait() }
        let handle = db; db = nil; condition.unlock()
        handle?.close()
    }
}
