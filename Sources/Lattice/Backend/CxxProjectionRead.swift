import Foundation
import Dispatch
import LatticeSwiftCppBridge
import LatticeSwiftModule
import CxxStdlib

extension CxxBackend: ProjectionReadBackend {
    func _startProjection(_ request: ProjectionReadRequest) throws -> any ProjectionReadOperation {
        var native = lattice.projection_request()
        native.setTable(std.string(request.descriptor.schema.table))
        try checkProjectionBridgeError()
        for column in request.selectedColumns {
            native.addColumn(std.string(column))
            try checkProjectionBridgeError()
        }
        if let predicate = request.descriptor.whereSQL {
            native.setWhere(std.string(predicate))
            try checkProjectionBridgeError()
        }
        native.setOrderBy(std.string(request.descriptor.orderBySQL))
        try checkProjectionBridgeError()
        // Combined distinct/group reads retain only requested values plus
        // their ordering dependencies in the intermediate SQL relation.
        if let sort = request.descriptor.sort {
            native.addOrderColumn(std.string(sort.column))
            try checkProjectionBridgeError()
        }
        native.addOrderColumn(std.string("id"))
        try checkProjectionBridgeError()
        if let group = request.descriptor.groupBy {
            native.setGroupBy(std.string(group))
            try checkProjectionBridgeError()
        }
        if let distinct = request.descriptor.distinctBy {
            native.setDistinctBy(std.string(distinct))
            try checkProjectionBridgeError()
        }
        if let bounds = request.descriptor.bounds {
            native.setBounds(column: std.string(bounds.column),
                minLat: bounds.minLat, maxLat: bounds.maxLat,
                minLon: bounds.minLon, maxLon: bounds.maxLon)
            try checkProjectionBridgeError()
        }
        for value in request.descriptor.bindings {
            guard DispatchTime.now().uptimeNanoseconds < request.deadlineNanoseconds else {
                throw ProjectionReadError.deadlineExceeded
            }
            let cell = value.cxxValue
            try checkProjectionBridgeError()
            native.addParameter(cell)
            try checkProjectionBridgeError()
        }
        native.setLimit(numericCast(request.effectiveLimit ?? -1))
        native.setOffset(0)
        native.setMaxRows(numericCast(request.limits.maxRows))
        native.setMaxCopiedBytes(numericCast(request.limits.maxBytes))
        native.setMaxCaptureBytes(numericCast(request.limits.maxCaptureBytes))
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < request.deadlineNanoseconds else { throw ProjectionReadError.deadlineExceeded }
        let remaining = request.deadlineNanoseconds - now
        // The Core watchdog uses milliseconds. Round up without overflow;
        // Swift still enforces the original finer-grained absolute deadline.
        let milliseconds = remaining / 1_000_000 + (remaining % 1_000_000 == 0 ? 0 : 1)
        native.setTimeoutMilliseconds(numericCast(milliseconds))
        let operation = ref.startProjection(native)
        try checkProjectionBridgeError()
        return CxxProjectionReadOperation(operation,
            columns: request.selectedColumns.count, deadline: request.deadlineNanoseconds)
    }
}

/// Thread safety belongs to Core's operation state: one stepping caller,
/// concurrent cancellation signals, and a private connection per operation.
private final class CxxProjectionReadOperation: ProjectionReadOperation, @unchecked Sendable {
    private let operation: lattice.projection_operation
    private let columns: Int
    private let released = ProjectionReleaseGate()
    private let deadline: UInt64
    private let cancellationLock = NSLock()
    private var cancelled = false

    init(_ operation: lattice.projection_operation, columns: Int, deadline: UInt64) {
        self.operation = operation
        self.columns = columns
        self.deadline = deadline
    }

    deinit { operation.close() }

    func cancel() {
        cancellationLock.lock()
        cancelled = true
        cancellationLock.unlock()
        operation.cancel()
    }
    func close() { operation.close() }

    func waitUntilClosed() async {
        await released.wait { [self] context, callback in
            operation.whenReleased(context: context, callback: callback)
        }
    }

    func nextBatch(maxRows: Int) throws -> ProjectionReadBatch {
        try checkConversionBudget()
        let batch = operation.nextBatch(maxRows: numericCast(maxRows))
        try checkProjectionBridgeError()
        let code = Int(batch.statusCode())
        switch code {
        case 0, 1: break
        case 2, 11: throw ProjectionReadError.cancelled
        case 3: throw ProjectionReadError.deadlineExceeded
        case 4: throw ProjectionReadError.rowBudgetExceeded
        case 5: throw ProjectionReadError.byteBudgetExceeded
        case 6: throw ProjectionReadError.snapshotExpired
        case 7: throw ProjectionReadError.unsupportedShape(String(batch.errorMessage()))
        case 8: throw ProjectionReadError.schemaChanged
        case 9: throw ProjectionReadError.database(String(batch.errorMessage()))
        case 10, 12: throw ProjectionReadError.invalidRequest(String(batch.errorMessage()))
        case 13: throw ProjectionReadError.resourceBusy
        case 14: throw ProjectionReadError.captureBudgetExceeded
        default: throw ProjectionReadError.database("unknown native projection status")
        }
        guard let count = Int(exactly: batch.rowCount()), count >= 0, count <= maxRows,
              Int(exactly: batch.columnCount()) == columns else {
            operation.close()
            throw ProjectionReadError.database("invalid native projection dimensions")
        }
        var rows: [[ColumnValue]] = []
        rows.reserveCapacity(count)
        for index in 0..<count {
            try checkConversionBudget()
            var row: [ColumnValue] = []
            row.reserveCapacity(columns)
            for column in 0..<columns {
                try checkConversionBudget()
                let cell = batch.value(row: numericCast(index), column: numericCast(column))
                // A sealed C++ allocation/access failure returns the variant's
                // NULL default. Check before another sealed helper clears it.
                try checkProjectionBridgeError()
                row.append(try strictProjectionCell(cell, check: checkConversionBudget))
            }
            rows.append(row)
        }
        try checkConversionBudget()
        return ProjectionReadBatch(rows: rows, isComplete: code == 1)
    }

    private func checkConversionBudget() throws {
        cancellationLock.lock()
        let isCancelled = cancelled
        cancellationLock.unlock()
        if isCancelled { throw ProjectionReadError.cancelled }
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
            throw ProjectionReadError.deadlineExceeded
        }
    }
}

private func checkProjectionBridgeError() throws {
    // C++ returns a reference to its thread-local string. Copy its pointee
    // immediately, before another sealed bridge call can clear the slot.
    let message = String(lattice.last_bridge_error().pointee)
    if !message.isEmpty { throw ProjectionReadError.database(message) }
}

private typealias ProjectionReleaseCallback = @convention(c) (UnsafeMutableRawPointer?) -> Void

/// One native registration, shared by cleanup waiters. The callback owns a
/// retain until native resources are gone; the gate owns no database handle.
private final class ProjectionReleaseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var registered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait(register: @Sendable (UnsafeMutableRawPointer?, ProjectionReleaseCallback) -> Bool) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            let shouldRegister = !registered
            registered = true
            lock.unlock()
            guard shouldRegister else { return }
            let retained = Unmanaged.passRetained(self)
            let accepted = register(retained.toOpaque(), { context in
                guard let context else { return }
                let gate = Unmanaged<ProjectionReleaseGate>.fromOpaque(context).takeRetainedValue()
                gate.signal()
            })
            // Core guarantees the first nonnull registration without allocation,
            // even for closed/rejected operations. Never report a rejected
            // callback registration as successful cleanup.
            if !accepted {
                retained.release()
                preconditionFailure("projection release callback registered more than once")
            }
        }
    }

    private func signal() {
        lock.lock()
        released = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }
}

/// Unlike the compatibility migration decoder, an unknown/missing variant is
/// an error. Only an actual nullptr variant becomes SQL NULL.
private func strictProjectionCell(_ value: lattice.column_value_t, check: () throws -> Void) throws -> ColumnValue {
    switch value.index() {
    case 0: return .null
    case 1:
        let integer = lattice.column_value_as_int(value)
        guard integer.__convertToBool() else { break }
        return .int64(numericCast(integer.pointee))
    case 2:
        let real = lattice.column_value_as_double(value)
        guard real.__convertToBool() else { break }
        return .real(real.pointee)
    case 3:
        let text = lattice.column_value_as_string(value)
        guard text.__convertToBool() else { break }
        let decoded = String(text.pointee)
        try check()
        return .text(decoded)
    case 4:
        let blob = lattice.column_value_as_blob(value)
        guard blob.__convertToBool() else { break }
        let bytes = blob.pointee
        let count: Int = numericCast(bytes.size())
        var data = Data(capacity: count)
        // Avoid the vector Collection witness path, which is unsupported by
        // the current Linux bridge for this specialization.
        for index in 0..<count {
            if index % 1024 == 0 { try check() }
            data.append(bytes[numericCast(index)])
        }
        try check()
        return .blob(data)
    default: break
    }
    throw ProjectionReadError.database("invalid native projection cell variant")
}
