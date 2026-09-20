import Foundation
import Dispatch

/// Internal-only execution surface. Public backends do not acquire a raw-SQL
/// requirement merely because the SDK adds a typed projection convenience.
protocol ProjectionReadBackend: Sendable {
    func _startProjection(_ request: ProjectionReadRequest) throws -> any ProjectionReadOperation
}

/// A single operation owns its native cursor and snapshot. Calls that can step
/// SQLite run on ProjectionReadExecutor, never on a cooperative executor stack.
protocol ProjectionReadOperation: AnyObject, Sendable {
    /// Returning completion or throwing must release the statement/read lease.
    /// A nonfinal batch retains the snapshot, but no execution lock.
    func nextBatch(maxRows: Int) throws -> ProjectionReadBatch
    /// Prompt signals, safe on cancellation/deinit threads. Native lifecycle
    /// machinery must reap an idle cursor without needing another next call.
    func cancel()
    func close()
    /// Called after close. Awaits native release acknowledgement without SQL,
    /// polling, a worker slot, or cancellation of this cleanup wait.
    func waitUntilClosed() async
}

struct ProjectionReadBatch: Sendable {
    let rows: [[ColumnValue]]
    let isComplete: Bool
}

typealias ProjectionOperationFactory = @Sendable (ProjectionReadRequest) throws -> any ProjectionReadOperation

func startProjectionOperation(_ request: ProjectionReadRequest) throws -> any ProjectionReadOperation {
    guard let backend = request.descriptor.backend as? any ProjectionReadBackend else {
        throw ProjectionReadError.unsupportedShape("backend does not support projected reads")
    }
    return try backend._startProjection(request)
}

func projectionPublicError(_ error: any Error) -> any Error {
    if error is CancellationError { return ProjectionReadError.cancelled }
    if let error = error as? ProjectionReadExecutorError {
        switch error {
        case .deadlineExceeded: return ProjectionReadError.deadlineExceeded
        case .queueFull: return ProjectionReadError.resourceBusy
        case .shutdown: return ProjectionReadError.executorStopped
        }
    }
    return error
}

/// This slot exists before admission, so cancellation racing operation creation
/// still reaches exactly that operation. No backend call runs under its lock.
final class ProjectionReadLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: (any ProjectionReadOperation)?
    private var stopped = false

    deinit { close() }

    func install(_ operation: any ProjectionReadOperation) throws {
        let reject: Bool = locked {
            precondition(self.operation == nil, "one native operation per projection lifetime")
            self.operation = operation
            return stopped
        }
        if reject {
            operation.cancel()
            operation.close()
            throw ProjectionReadError.cancelled
        }
    }

    func current() -> (any ProjectionReadOperation)? { locked { operation } }

    func checkCancellation() throws {
        if locked({ stopped }) { throw ProjectionReadError.cancelled }
    }

    func check(deadline: UInt64) throws {
        try checkCancellation()
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
            throw ProjectionReadError.deadlineExceeded
        }
    }

    func cancel() {
        let operation = locked {
            stopped = true
            return self.operation
        }
        operation?.cancel()
    }

    func close() {
        let operation = locked {
            stopped = true
            return self.operation
        }
        operation?.close()
    }

    func closeAndWait() async {
        let operation = locked {
            stopped = true
            return self.operation
        }
        guard let operation else { return }
        operation.close()
        await operation.waitUntilClosed()
        locked { self.operation = nil }
    }

    /// Release a finished native operation while retaining cancellation state
    /// until value decoding and final publication are complete.
    func releaseOperation() {
        let operation = locked {
            let result = self.operation
            self.operation = nil
            return result
        }
        operation?.close()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
