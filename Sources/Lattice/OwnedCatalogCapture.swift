import Foundation
import Dispatch

public enum OwnedCatalogError: Error, Sendable, Equatable {
    case invalidRequest(String)
    case unsupportedBackend
    case malformedFrame(String)
    case database(String)
    case deadlineExceeded
    case resourceBusy
    case executorStopped
}

/// Cleanup observations from the original owner, without partial values or a
/// reopening recipe. The owner must retain any unsettled transaction state.
public struct OwnedCatalogCleanupError: Error, Sendable, LocalizedError {
    /// Native outcomes; -1 means the step was not observed.
    public let finalizeCode: Int32
    public let transactionCode: Int32
    public let rollbackCode: Int32
    public var errorDescription: String? {
        "Owned catalog cleanup failed [finalize=\(finalizeCode), transaction=\(transactionCode), rollback=\(rollbackCode)]"
    }

    init(finalizeCode: Int32, transactionCode: Int32, rollbackCode: Int32) {
        self.finalizeCode = finalizeCode
        self.transactionCode = transactionCode
        self.rollbackCode = rollbackCode
    }
}

/// A closed list of typed, complete physical tables on this retained backend.
/// Events remain provisional until reduction succeeds after checked native
/// cleanup. Fence new reductions and join accepted reductions before closing
/// the borrowed store. This value supplies no source authorization.
public struct OwnedCatalogCapture: Sendable {
    private let backend: any OwnedCatalogBackend
    private let tables: [String]
    private let tablesJSON: String

    init(backend: any OwnedCatalogBackend, tables: [String], tablesJSON: String) {
        self.backend = backend
        self.tables = tables
        self.tablesJSON = tablesJSON
    }

    /// One worker creates, consumes and finishes State; State need not be
    /// Sendable. Only completed Output crosses to the awaiting caller. There
    /// are two shared eight-MiB-stack workers and at most 64 pending jobs.
    /// The positive timeout is at most thirty seconds, includes queue wait,
    /// and never renews. Reducers must return and must not reenter the owner.
    /// Cancellation and expiry signal this operation and join actual native
    /// cleanup before returning; they cannot preempt arbitrary reducer/VFS code.
    public func reduce<State, Output: Sendable>(timeout: Duration = .seconds(30),
        makeState: @escaping @Sendable () throws -> State,
        consume: @escaping @Sendable (inout State, OwnedCatalogEvent) throws -> Void,
        finish: @escaping @Sendable (State) throws -> Output) async throws -> Output {
        try Task.checkCancellation()
        let deadline = try OwnedCatalogReadDeadline.make(timeout: timeout)
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { throw OwnedCatalogError.deadlineExceeded }
        // This control has no SQL lease/statement. Native admission, stepping,
        // callback and checked ending all occur inside capture on one worker.
        let native = try backend.makeOwnedCatalogOperation(tablesJSON: tablesJSON,
            timeoutNanoseconds: deadline - now)
        let cancellation = OwnedCatalogCancellation()
        return try await withTaskCancellationHandler {
            do {
                let value = try await ProjectionReadExecutor.shared.submit(deadline: deadline,
                    onCancel: { cancellation.cancel(); native.cancel() },
                    preservingFailureOnStop: { $0 is OwnedCatalogCleanupError }) { [tables] in
                        try cancellation.check(deadline: deadline)
                        var state = try makeState()
                        var decoder = OwnedCatalogDecoder(tables: tables)
                        try native.capture { kind, bytes in
                            try cancellation.check(deadline: deadline)
                            if let event = try decoder.accept(kind: kind, bytes: bytes) {
                                try consume(&state, event)
                            }
                            try cancellation.check(deadline: deadline)
                        }
                        try decoder.finish()
                        try cancellation.check(deadline: deadline)
                        let output = try finish(state)
                        try cancellation.check(deadline: deadline)
                        return output
                    }
                try cancellation.check(deadline: deadline)
                try Task.checkCancellation()
                return value
            } catch {
                // A native cleanup fault remains stronger than cancellation
                // or expiry. Accepted capture and interrupt have both returned.
                if error is OwnedCatalogCleanupError { throw error }
                if let failure = error as? ProjectionReadExecutorError {
                    switch failure {
                    case .deadlineExceeded: throw OwnedCatalogError.deadlineExceeded
                    case .queueFull: throw OwnedCatalogError.resourceBusy
                    case .shutdown: throw OwnedCatalogError.executorStopped
                    }
                }
                if cancellation.isCancelled || Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            // The executor owns and joins the native interrupt signal. This
            // outer handler only fences callbacks/final publication.
            cancellation.cancel()
        }
    }

    public func reduce<State: Sendable>(timeout: Duration = .seconds(30), initial: State,
        consume: @escaping @Sendable (inout State, OwnedCatalogEvent) throws -> Void) async throws -> State {
        try await reduce(timeout: timeout, makeState: { initial }, consume: consume, finish: { $0 })
    }
}

extension Lattice {
    /// Complete tables only: this factory takes model types, so filtered,
    /// ranked, grouped and paginated query descriptors cannot be substituted.
    /// Table/schema validity is checked again by the original native owner.
    public func makeOwnedCatalogCapture(_ modelTypes: [any Model.Type]) throws -> OwnedCatalogCapture {
        guard !modelTypes.isEmpty, modelTypes.count <= 64 else {
            throw OwnedCatalogError.invalidRequest("Expected one through 64 complete tables")
        }
        var seen = Set<String>()
        let tables = try modelTypes.map { type -> String in
            let name = type.entityName
            guard !name.isEmpty, name.utf8.count <= 1_024, !name.contains("\0"),
                  seen.insert(name).inserted else {
                throw OwnedCatalogError.invalidRequest("Expected distinct valid model table names")
            }
            return name
        }
        struct Envelope: Encodable { let version: Int; let tables: [String] }
        let data = try JSONEncoder().encode(Envelope(version: 1, tables: tables))
        guard data.count <= 65_536, let json = String(data: data, encoding: .utf8) else {
            throw OwnedCatalogError.invalidRequest("Table descriptor exceeds 64 KiB")
        }
        guard let source = backend as? any OwnedCatalogBackend else {
            throw OwnedCatalogError.unsupportedBackend
        }
        return .init(backend: source, tables: tables, tablesJSON: json)
    }
}

private final class OwnedCatalogCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check(deadline: UInt64) throws {
        if isCancelled { throw CancellationError() }
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
            throw OwnedCatalogError.deadlineExceeded
        }
    }
}
