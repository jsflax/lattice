import Foundation
import Dispatch
import Testing
import LatticeSwiftCppBridge
import CxxStdlib
@testable import Lattice

@Model private final class CatalogStreamRecord {
    var name: String = ""
    var payload: Data = Data()
}

@Model private final class CatalogStreamMissingRecord { var name: String = "" }

private enum CatalogStreamFixtureError: Error, Equatable { case fixtureRoot, consumer, workerTimedOut }

enum CatalogCallbackBoundary: CaseIterable, Sendable, Equatable {
    case path, closed, optimize, add, preservingAdd, checkpoint, reclaim, close, generation
}

private final class CatalogCallbackReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var releases = 0
    func called() { lock.lock(); calls += 1; lock.unlock() }
    func released() { lock.lock(); releases += 1; lock.unlock() }
    var counts: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (calls, releases) }
}

// A noncapturing C destroy callback can observe this explicit shared receipt.
// The enclosing suite serializes the one nil-context regression; no production
// observer or pointer owns this receipt.
private let catalogNilContextDestroyReceipt = CatalogCallbackReceipt()

// Deliberately non-Sendable. Only the SDK worker constructs and uses this value.
private final class CatalogStreamAccumulator {
    var rows = 0
    var column = ""
    var payloadBytes = 0
    var payloadSum: UInt64 = 0
    var largestChunk = 0
}

private final class CatalogStreamGate: @unchecked Sendable {
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var entered = false
    private var returned = false
    var hasReturned: Bool { lock.lock(); defer { lock.unlock() }; return returned }
    func markReturned() { lock.lock(); returned = true; lock.unlock() }
    func open() { release.signal() }
    func holdWorker() throws {
        lock.lock()
        entered = true
        lock.unlock()
        guard release.wait(timeout: .now() + 10) == .success else {
            throw CatalogStreamFixtureError.workerTimedOut
        }
    }
    private var hasEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    func waitUntilEntered() async throws {
        let end = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while !hasEntered {
            guard DispatchTime.now().uptimeNanoseconds < end else { throw CatalogStreamFixtureError.workerTimedOut }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

}

// Actual file-backed owner declarations, UNCOMPILED and UNRUN at source freeze.
// A successful declaration/run would cover only its stated behavior, not source
// authorization, profile/lifecycle acceptance or physical cleanup guarantees.
@MainActor @Suite("Current original-owner catalog stream", .serialized, .timeLimit(.minutes(1)))
struct OwnedCatalogCaptureTests {
    private func withStore(_ body: @MainActor (Lattice) async throws -> Void) async throws {
        let localdev = FileManager.default.homeDirectoryForCurrentUser.appending(path: "localdev")
            .standardizedFileURL.resolvingSymlinksInPath()
        let root = ProcessInfo.processInfo.environment["LATTICE_TEST_ARTIFACTS"]
            .map { URL(fileURLWithPath: $0) } ?? localdev.appending(path: "lattice-catalog-stream-fixtures")
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        guard base.path.hasPrefix(localdev.path + "/") else { throw CatalogStreamFixtureError.fixtureRoot }
        let directory = base.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try Lattice(for: [CatalogStreamRecord.self],
            configuration: .init(fileURL: directory.appending(path: "catalog.sqlite")))
        defer { store.close() }
        try await body(store)
    }

    @Test func completeCatalogExceedsOldRowAndByteCapsWithWorkerLocalState() async throws {
        try await withStore { store in
            let bytes = 5 * 1_048_576
            try store.withTransaction {
                for index in 0..<4_097 {
                    let row = CatalogStreamRecord()
                    row.name = String(index)
                    if index == 0 { row.payload = Data(repeating: 171, count: bytes) }
                    try store.add(row)
                }
            }
            let capture = try store.makeOwnedCatalogCapture([CatalogStreamRecord.self])
            // This actual large write can exceed the unchanged 16MiB WAL
            // threshold without ever creating a live-Results coordinator.
            #expect(store.configuration.resultsTuning.walKeeperEvictionThresholdBytes == 16 * 1_048_576)
            let walPath = store.configuration.fileURL.path + "-wal"
            let beforeAttributes = try FileManager.default.attributesOfItem(atPath: walPath)
            let beforeBytes = try #require(beforeAttributes[.size] as? NSNumber).uint64Value
            #expect(beforeBytes > 16 * 1_048_576)
            do {
                _ = try await capture.reduce(initial: 0) { _, _ in
                    Issue.record("Pressured admission delivered a partial catalog")
                }
                Issue.record("Pressured capture unexpectedly completed")
            } catch {
                guard let failure = error as? OwnedCatalogError,
                      case .database(let message) = failure else { throw error }
                #expect(message.contains("physical-store pressure or retirement"))
            }
            let maintenance = store.runReadPoolMaintenance()
            #expect(maintenance.completed && !maintenance.pressurePending && maintenance.error.isEmpty)
            let afterAttributes = try FileManager.default.attributesOfItem(atPath: walPath)
            let afterBytes = try #require(afterAttributes[.size] as? NSNumber).uint64Value
            #expect(afterBytes == 0) // Real present-file ending; absence is not success.
            print("catalog_pressure_fixture wal_before=\(beforeBytes) wal_after=\(afterBytes) maintenance_completed=\(maintenance.completed) pending=\(maintenance.pressurePending)")
            let result = try await capture.reduce(makeState: { CatalogStreamAccumulator() }, consume: { state, event in
                #expect(!Thread.isMainThread)
                switch event {
                case .beginRow: state.rows += 1
                case .beginCell(let column, _, _): state.column = column
                case .bytes(let data):
                    state.largestChunk = max(state.largestChunk, data.count)
                    if state.column == "payload" {
                        state.payloadBytes += data.count
                        for byte in data { state.payloadSum += UInt64(byte) }
                    }
                default: break
                }
            }, finish: { ($0.rows, $0.payloadBytes, $0.payloadSum, $0.largestChunk) })
            #expect(result.0 == 4_097 && result.1 == bytes)
            #expect(result.2 == UInt64(bytes) * 171)
            #expect(result.3 <= 65_536 && result.3 > 0)
            store.close()
            let closed = store.runReadPoolMaintenance()
            #expect(!closed.completed && closed.pressurePending && !closed.error.isEmpty)
        }
    }

    @Test func emptyTableStillCarriesPhysicalSchema() async throws {
        try await withStore { store in
            let capture = try store.makeOwnedCatalogCapture([CatalogStreamRecord.self])
            let result = try await capture.reduce(initial: (tables: 0, rows: 0, ended: 0, columns: [String]())) { state, event in
                switch event {
                case .beginTable(let table, let columns):
                    #expect(table == CatalogStreamRecord.entityName)
                    state.tables += 1
                    state.columns = columns.map(\.name)
                case .beginRow: state.rows += 1
                case .endTable: state.ended += 1
                default: break
                }
            }
            #expect(result.tables == 1 && result.rows == 0 && result.ended == 1)
            #expect(Set(result.columns).isSuperset(of: ["id", "globalId", "name", "payload"]))
        }
    }

    @Test func consumerFailureJoinsBeforeSameOwnerWriteAndRecapture() async throws {
        try await withStore { store in
            try store.add(CatalogStreamRecord())
            let capture = try store.makeOwnedCatalogCapture([CatalogStreamRecord.self])
            do {
                _ = try await capture.reduce(initial: 0) { _, _ in throw CatalogStreamFixtureError.consumer }
                Issue.record("A throwing consumer unexpectedly completed")
            } catch { #expect(error as? CatalogStreamFixtureError == .consumer) }
            let next = CatalogStreamRecord()
            next.name = "after failure"
            try store.add(next)
            let rows = try await capture.reduce(initial: 0) { rows, event in
                if case .beginRow = event { rows += 1 }
            }
            #expect(rows == 2)
        }
    }

    @Test func cancellationJoinsBlockedConsumerAndOriginalNativeEnding() async throws {
        try await withStore { store in
            try store.add(CatalogStreamRecord())
            let capture = try store.makeOwnedCatalogCapture([CatalogStreamRecord.self])
            let gate = CatalogStreamGate()
            defer { gate.open() }
            let task = Task {
                defer { gate.markReturned() }
                return try await capture.reduce(initial: 0) { count, event in
                    if case .beginTable = event { try gate.holdWorker() }
                    count += 1
                }
            }
            do { try await gate.waitUntilEntered() }
            catch {
                task.cancel()
                gate.open()
                _ = await task.result
                throw error
            }
            task.cancel()
            await Task.yield()
            #expect(!gate.hasReturned)
            gate.open()
            do { _ = try await task.value; Issue.record("Cancelled reduction returned a value") }
            catch { #expect(error is CancellationError) }
            try store.add(CatalogStreamRecord())
            let rows = try await capture.reduce(initial: 0) { rows, event in
                if case .beginRow = event { rows += 1 }
            }
            #expect(rows == 2)
        }
    }

    @Test func expiredWorkerWaitDoesNotPublishOrReturnBeforeJoin() async throws {
        try await withStore { store in
            let capture = try store.makeOwnedCatalogCapture([CatalogStreamRecord.self])
            let gate = CatalogStreamGate()
            defer { gate.open() }
            let task = Task {
                defer { gate.markReturned() }
                return try await capture.reduce(timeout: .seconds(1), initial: 0) { count, event in
                    if case .beginTable = event { try gate.holdWorker() }
                    count += 1
                }
            }
            do { try await gate.waitUntilEntered() }
            catch {
                task.cancel()
                gate.open()
                _ = await task.result
                throw error
            }
            do { try await Task.sleep(for: .milliseconds(1_100)) }
            catch {
                task.cancel()
                gate.open()
                _ = await task.result
                throw error
            }
            #expect(!gate.hasReturned)
            gate.open()
            do { _ = try await task.value; Issue.record("Expired reduction returned a value") }
            catch { #expect(error as? OwnedCatalogError == .deadlineExceeded) }
            try store.add(CatalogStreamRecord())
        }
    }

    @Test func typedFactoryRejectsEmptyRepeatedAndMissingTables() async throws {
        try await withStore { store in
            #expect(throws: (any Error).self) { try store.makeOwnedCatalogCapture([]) }
            #expect(throws: (any Error).self) {
                try store.makeOwnedCatalogCapture([CatalogStreamRecord.self, CatalogStreamRecord.self])
            }
            let missing = try store.makeOwnedCatalogCapture([CatalogStreamMissingRecord.self])
            do {
                _ = try await missing.reduce(initial: 0) { count, _ in count += 1 }
                Issue.record("Uninstalled physical table unexpectedly completed")
            } catch { #expect(!(error is CancellationError)) }
        }
    }

    // Each invocation crosses a real Swift -> C++ -> Swift consumer -> C++
    // boundary on the original file owner. Surviving alone is insufficient:
    // the typed failure/sentinel must be right, capture must remain poisoned
    // even though Swift catches the refusal, and the owner must remain usable
    // after checked ending. These tests are UNCOMPILED/UNRUN at source freeze.
    @Test(arguments: CatalogCallbackBoundary.allCases)
    func swiftCallbackRefusalsStayContainedAndPreserveOriginalOwner(_ action: CatalogCallbackBoundary) async throws {
        try await withStore { store in
            try store.add(CatalogStreamRecord())
            let backend = try #require(store.backend as? CxxBackend)
            let candidate = CatalogStreamRecord()
            candidate.name = "must remain unmanaged"
            let object = try #require(candidate.asRefType as? CxxObjectBackend)
            let receipt = CatalogCallbackReceipt()
            let capture = try store.makeOwnedCatalogCapture([CatalogStreamRecord.self])
            do {
                _ = try await capture.reduce(initial: 0) { count, event in
                    guard case .beginTable = event else { return }
                    count += 1
                    receipt.called()
                    switch action {
                    case .path:
                        #expect(String(backend.ref.path()).isEmpty)
                    case .closed:
                        // A refused lifecycle read is conservatively closed;
                        // its actual owner must still be open after ending.
                        #expect(backend.ref.isClosed())
                    case .optimize:
                        backend.optimize()
                    case .add:
                        do { try backend.add(object); Issue.record("Callback add reported success") }
                        catch { #expect(error is LatticeError) }
                    case .preservingAdd:
                        do {
                            try backend.addPreservingGlobalId(object,
                                globalId: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!)
                            Issue.record("Callback preserving add reported success")
                        } catch { #expect(error is LatticeError) }
                    case .checkpoint:
                        let result = backend.ref.checkpoint()
                        #expect(result.busy && !result.complete)
                        #expect(result.log_frames == -1 && result.checkpointed == -1)
                    case .reclaim:
                        let result = backend.ref.reclaimSpace(maxPasses: 2)
                        #expect(!result.ok && !result.error.empty())
                    case .close:
                        var result = backend.ref.closeChecked()
                        #expect(result.failed() && !result.cleanupComplete())
                        #expect(!String(result.takeMessage()).isEmpty)
                    case .generation:
                        // The checked maintenance path must refuse before a
                        // same-owner reader gap, retain its error and poison
                        // this capture even though Swift swallows the refusal.
                        let maintenance = backend.runReadPoolMaintenanceChecked()
                        #expect(!maintenance.completed && maintenance.pressurePending)
                        #expect(maintenance.error.contains("catalog callback"))
                        let result = backend.ref.count_at(0, std.string(CatalogStreamRecord.entityName),
                            lattice.OptionalString(), lattice.OptionalString(), lattice.OptionalString(),
                            lattice.ColumnValueVector())
                        #expect(result == -1 && backend.ref.lastGenerationReadStale())
                    }
                    if action != .close {
                        #expect(backend.lastQueryError()?.contains("catalog callback") == true)
                    }
                    // Deliberately return normally: swallowing the checked
                    // refusal cannot make this partial capture acceptable.
                }
                Issue.record("Callback reentry returned a completed catalog")
            } catch {
                guard let failure = error as? OwnedCatalogError, case .database(let message) = failure else {
                    Issue.record("Unexpected callback failure: \(error)")
                    return
                }
                #expect(message.contains("callback"))
            }
            #expect(receipt.counts.0 == 1)
            #expect(!candidate.isManaged && !backend.ref.isClosed())
            #expect(!backend.path.isEmpty)
            try store.add(CatalogStreamRecord())
            let rows = try await capture.reduce(initial: 0) { count, event in
                if case .beginRow = event { count += 1 }
            }
            #expect(rows == 2)
        }
    }

    @Test func callbackRegistrationRefusalConsumesTransferredContextExactlyOnce() async throws {
        try await withStore { store in
            let backend = try #require(store.backend as? CxxBackend)
            let receipt = CatalogCallbackReceipt()
            let capture = try store.makeOwnedCatalogCapture([CatalogStreamRecord.self])
            do {
                _ = try await capture.reduce(initial: 0) { count, event in
                    guard case .beginTable = event else { return }
                    count += 1
                    let context = Unmanaged.passRetained(receipt).toOpaque()
                    let token = backend.ref.add_recovery_refresh_observer(context, { context in
                        guard let context else { return }
                        Unmanaged<CatalogCallbackReceipt>.fromOpaque(context).takeUnretainedValue().called()
                    }, { context in
                        guard let context else { return }
                        Unmanaged<CatalogCallbackReceipt>.fromOpaque(context).takeRetainedValue().released()
                    })
                    // Native consumes this context on refusal. Swift must not
                    // release it again or leave a retained observer behind.
                    #expect(token == 0 && receipt.counts.1 == 1 && receipt.counts.0 == 0)
                    #expect(backend.lastQueryError()?.contains("catalog callback") == true)
                }
                Issue.record("Registration reentry completed a catalog")
            } catch { #expect(error is OwnedCatalogError) }
            #expect(receipt.counts.1 == 1 && receipt.counts.0 == 0)
            try store.add(CatalogStreamRecord())
            let rows = try await capture.reduce(initial: 0) { count, event in
                if case .beginRow = event { count += 1 }
            }
            #expect(rows == 1 && receipt.counts.1 == 1 && receipt.counts.0 == 0)
        }
    }
    @Test func nilContextCallbackClearsNeverInvokeNonnullDestroyEvenWhenRefused() async throws {
        try await withStore { store in
            let backend = try #require(store.backend as? CxxBackend)
            let destroyedBefore = catalogNilContextDestroyReceipt.counts.1
            // Each original setter promises that nil callback + nil context
            // clears without calling a nonnull deleter with nullptr. Exercise
            // the normal lower trampoline as well as the guarded refusal.
            backend.ref.set_on_sync_progress(nil, nil, { context in
                #expect(context == nil)
                catalogNilContextDestroyReceipt.released()
            })
            backend.ref.set_on_sync_error(nil, nil, { context in
                #expect(context == nil)
                catalogNilContextDestroyReceipt.released()
            })
            backend.ref.set_on_sync_state_change(nil, nil, { context in
                #expect(context == nil)
                catalogNilContextDestroyReceipt.released()
            })
            backend.ref.set_on_xproc_idle(nil, nil, { context in
                #expect(context == nil)
                catalogNilContextDestroyReceipt.released()
            })
            #expect(catalogNilContextDestroyReceipt.counts.1 == destroyedBefore)
            let entered = CatalogCallbackReceipt()
            let capture = try store.makeOwnedCatalogCapture([CatalogStreamRecord.self])
            do {
                _ = try await capture.reduce(initial: 0) { count, event in
                    guard case .beginTable = event else { return }
                    count += 1
                    entered.called()
                    backend.ref.set_on_sync_progress(nil, nil, { context in
                        #expect(context == nil)
                        catalogNilContextDestroyReceipt.released()
                    })
                    backend.ref.set_on_sync_error(nil, nil, { context in
                        #expect(context == nil)
                        catalogNilContextDestroyReceipt.released()
                    })
                    backend.ref.set_on_sync_state_change(nil, nil, { context in
                        #expect(context == nil)
                        catalogNilContextDestroyReceipt.released()
                    })
                    backend.ref.set_on_xproc_idle(nil, nil, { context in
                        #expect(context == nil)
                        catalogNilContextDestroyReceipt.released()
                    })
                    #expect(backend.lastQueryError()?.contains("catalog callback") == true)
                    #expect(catalogNilContextDestroyReceipt.counts.1 == destroyedBefore)
                }
                Issue.record("Refused callback clear completed its catalog")
            } catch { #expect(error is OwnedCatalogError) }
            #expect(entered.counts.0 == 1 && !backend.ref.isClosed())
            #expect(catalogNilContextDestroyReceipt.counts.1 == destroyedBefore)
            try store.add(CatalogStreamRecord())
            let rows = try await capture.reduce(initial: 0) { count, event in
                if case .beginRow = event { count += 1 }
            }
            #expect(rows == 1 && catalogNilContextDestroyReceipt.counts.1 == destroyedBefore)
        }
    }

}

@Suite("Catalog deadline and strict metadata data cases")
struct OwnedCatalogDataTests {
    @Test func deadlineIsOneBoundedOriginalMonotonicEnd() throws {
        #expect(try OwnedCatalogReadDeadline.make(timeout: .nanoseconds(1), now: 10) == 11)
        #expect(try OwnedCatalogReadDeadline.make(timeout: .seconds(30), now: 10) == 30_000_000_010)
        for timeout in [Duration.zero, .nanoseconds(-1), .seconds(31)] {
            #expect(throws: (any Error).self) { try OwnedCatalogReadDeadline.make(timeout: timeout, now: 10) }
        }
        #expect(throws: (any Error).self) { try OwnedCatalogReadDeadline.make(timeout: .seconds(1), now: UInt64.max) }
    }

    @Test func metadataRejectsDuplicateEscapedKeysInvalidSurrogatesAndNonStringScalars() throws {
        for invalid in [#"{"table":"a","ta\u0062le":"b","columns":[]}"#,
                        #"{"table":"\uD800","columns":[]}"#,
                        #"{"table":"a","columns":[{"name":"id","type":1}]}"#] {
            #expect(throws: (any Error).self) { try OwnedCatalogJSONShape.validate(Data(invalid.utf8)) }
        }
        #expect(throws: (any Error).self) { try OwnedCatalogJSONShape.validate(Data([0x22, 0xFF, 0x22])) }
        #expect(throws: (any Error).self) { try OwnedCatalogJSONShape.validate(Data(repeating: 32, count: 65_537)) }
    }

    @Test func decoderRejectsIncompleteCellsAndUnorderedIdentity() throws {
        let schema = Data(#"{"table":"r","columns":[{"name":"id","type":"INTEGER"},{"name":"globalId","type":"TEXT"}]}"#.utf8)
        let row = Data(#"{"id":"1","globalId":"96a230f2-fb55-44d0-b512-01122a173be6"}"#.utf8)
        var decoder = OwnedCatalogDecoder(tables: ["r"])
        _ = try decoder.accept(kind: 0, bytes: schema)
        _ = try decoder.accept(kind: 1, bytes: row)
        _ = try decoder.accept(kind: 2, bytes: Data(#"{"column":"id","kind":"integer","bytes":"8"}"#.utf8))
        _ = try decoder.accept(kind: 3, bytes: Data(repeating: 0, count: 7))
        #expect(throws: (any Error).self) { try decoder.accept(kind: 4, bytes: Data()) }
        #expect(throws: (any Error).self) { try decoder.finish() }
        #expect(throws: (any Error).self) { try decoder.accept(kind: 1, bytes: row) }
    }
}
