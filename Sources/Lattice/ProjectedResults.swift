import Foundation

/// An immutable selection of stored scalar fields. Values are copied from one
/// committed read snapshot; they are not live models and do not register model
/// observers. Async reads do not inherit a caller's thread-owned transaction.
///
/// Byte limits cover encoded cells copied from SQLite, not SQLite workspace or
/// allocations inside custom scalar decoders. Custom decoders run without any
/// database lock and must return promptly for cancellation to finish promptly.
public struct ProjectedResults<Output: Sendable>: Sendable {
    let descriptor: ProjectionQueryDescriptor
    let columns: [String]
    let decode: @Sendable ([ColumnValue]) throws -> Output
    let factory: ProjectionOperationFactory
    let executor: ProjectionReadExecutor

    init(descriptor: ProjectionQueryDescriptor, columns: [String],
         executor: ProjectionReadExecutor = .shared,
         factory: @escaping ProjectionOperationFactory = startProjectionOperation,
         decode: @escaping @Sendable ([ColumnValue]) throws -> Output) {
        self.descriptor = descriptor
        self.columns = columns
        self.executor = executor
        self.factory = factory
        self.decode = decode
    }

    /// Observe full latest-state snapshots on consumer demand. Hints and the
    /// explicit reconciliation interval only mark this captured projection
    /// dirty; no read runs while the consumer is paused. Unchanged snapshots
    /// may be emitted. Each demanded read uses a fresh timeout from limits.
    public func latestStates(using scheduler: ObservationScheduler,
                             limits: ProjectionReadLimits,
                             reconciliationInterval: TimeInterval,
                             limit: Int? = nil) throws -> LatestStateSnapshots<Output> {
        guard let hints = descriptor.backend as? any CoarseInvalidationBackend else {
            throw ProjectionReadError.unsupportedShape("backend does not provide latest-state invalidation hints")
        }
        return try LatestStateSnapshots(projection: self, scheduler: scheduler, limits: limits,
            reconciliationInterval: reconciliationInterval, limit: limit, hints: hints)
    }

    /// Read the requested rows and release the native snapshot before decoding
    /// values. A resource limit is an error, not silent result truncation.
    public func snapshot(limit: Int? = nil, limits: ProjectionReadLimits) async throws -> [Output] {
        let request = try ProjectionReadRequest(descriptor: descriptor,
            selectedColumns: columns, limits: limits, limit: limit)
        let lifetime = ProjectionReadLifetime()
        do {
            return try await executor.submit(deadline: request.deadlineNanoseconds,
                onCancel: { lifetime.cancel() }) {
                defer { lifetime.close() }
                try lifetime.check(deadline: request.deadlineNanoseconds)
                let operation = try factory(request)
                try lifetime.install(operation)
                var rows: [[ColumnValue]] = []
                while true {
                    try lifetime.check(deadline: request.deadlineNanoseconds)
                    let batch = try operation.nextBatch(maxRows: min(256, limits.maxRows))
                    try validateProjectionBatch(batch, columns: columns.count,
                        maximumRows: min(256, limits.maxRows))
                    guard batch.rows.count <= limits.maxRows - rows.count else {
                        throw ProjectionReadError.rowBudgetExceeded
                    }
                    rows.append(contentsOf: batch.rows)
                    if batch.isComplete { break }
                }
                lifetime.releaseOperation()
                return try decodeProjectionRows(rows, deadline: request.deadlineNanoseconds,
                    lifetime: lifetime, decode: decode)
            }
        } catch {
            await lifetime.closeAndWait()
            throw projectionPublicError(error)
        }
    }

    /// A single-pass, demand-driven sequence over one snapshot, with at most
    /// `size` rows per batch. Its deadline
    /// begins here and includes queue wait and time between batches. Retaining
    /// an iterator retains its snapshot until completion, cancellation, expiry,
    /// or iterator destruction. Drop the iterator or call cancel() on an early
    /// exit. The sequence itself does not retain a cursor.
    public func batches(of size: Int, limit: Int? = nil,
                        limits: ProjectionReadLimits) throws -> ProjectedBatches<Output> {
        guard size > 0, size <= limits.maxRows else {
            throw ProjectionReadError.invalidRequest("batch size must be positive and no greater than maxRows")
        }
        let request = try ProjectionReadRequest(descriptor: descriptor,
            selectedColumns: columns, limits: limits, limit: limit)
        return ProjectedBatches(request: request, size: size, factory: factory,
            executor: executor, decode: decode)
    }
}

/// Snapshot batches have one consumer. Copies of the sequence share the same
/// admission token; a second iterator fails explicitly instead of duplicating
/// the operation ID or silently opening another snapshot.
public struct ProjectedBatches<Output: Sendable>: AsyncSequence, Sendable {
    public typealias Element = [Output]
    private let source: ProjectionBatchSource<Output>

    fileprivate init(request: ProjectionReadRequest, size: Int,
                     factory: @escaping ProjectionOperationFactory,
                     executor: ProjectionReadExecutor,
                     decode: @escaping @Sendable ([ColumnValue]) throws -> Output) {
        source = ProjectionBatchSource(request: request, size: size, factory: factory,
            executor: executor, decode: decode)
    }

    public func makeAsyncIterator() -> Iterator { Iterator(state: source.claim()) }

    public struct Iterator: AsyncIteratorProtocol, Sendable {
        fileprivate let state: ProjectionBatchIteratorState<Output>?

        public mutating func next() async throws -> [Output]? {
            guard let state else {
                throw ProjectionReadError.invalidRequest("projected batches allow only one iterator")
            }
            return try await state.next()
        }

        /// Stop admission and signal this iterator's native operation. A next
        /// call already in flight finishes cleanup before it throws. Cancelling
        /// an idle iterator schedules native cleanup without another next call.
        public func cancel() { state?.cancel() }
    }
}

private final class ProjectionBatchSource<Output: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    let request: ProjectionReadRequest
    let size: Int
    let factory: ProjectionOperationFactory
    let executor: ProjectionReadExecutor
    let decode: @Sendable ([ColumnValue]) throws -> Output

    init(request: ProjectionReadRequest, size: Int, factory: @escaping ProjectionOperationFactory,
         executor: ProjectionReadExecutor, decode: @escaping @Sendable ([ColumnValue]) throws -> Output) {
        self.request = request
        self.size = size
        self.factory = factory
        self.executor = executor
        self.decode = decode
    }

    func claim() -> ProjectionBatchIteratorState<Output>? {
        lock.lock()
        let first = !claimed
        claimed = true
        lock.unlock()
        guard first else { return nil }
        return ProjectionBatchIteratorState(request: request, size: size, factory: factory,
            executor: executor, decode: decode)
    }
}

private struct DecodedProjectionBatch<Output: Sendable>: Sendable {
    let rows: [Output]
    let isComplete: Bool
}

fileprivate final class ProjectionBatchIteratorState<Output: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = false
    private var finished = false
    private let lifetime = ProjectionReadLifetime()
    private let request: ProjectionReadRequest
    private let size: Int
    private let factory: ProjectionOperationFactory
    private let executor: ProjectionReadExecutor
    private let decode: @Sendable ([ColumnValue]) throws -> Output

    init(request: ProjectionReadRequest, size: Int, factory: @escaping ProjectionOperationFactory,
         executor: ProjectionReadExecutor, decode: @escaping @Sendable ([ColumnValue]) throws -> Output) {
        self.request = request
        self.size = size
        self.factory = factory
        self.executor = executor
        self.decode = decode
    }

    deinit { lifetime.close() }

    func next() async throws -> [Output]? {
        guard try begin() else { return nil }
        do {
            let batch = try await executor.submit(deadline: request.deadlineNanoseconds,
                onCancel: { [lifetime] in lifetime.cancel() }) { [self] in
                try lifetime.check(deadline: request.deadlineNanoseconds)
                let operation: any ProjectionReadOperation
                if let existing = lifetime.current() {
                    operation = existing
                } else {
                    operation = try factory(request)
                    try lifetime.install(operation)
                }
                let raw = try operation.nextBatch(maxRows: size)
                try validateProjectionBatch(raw, columns: request.selectedColumns.count, maximumRows: size)
                if raw.isComplete { lifetime.releaseOperation() }
                let rows = try decodeProjectionRows(raw.rows, deadline: request.deadlineNanoseconds,
                    lifetime: lifetime, decode: decode)
                return DecodedProjectionBatch(rows: rows, isComplete: raw.isComplete)
            }
            end(complete: batch.isComplete)
            return batch.rows.isEmpty && batch.isComplete ? nil : batch.rows
        } catch {
            await lifetime.closeAndWait()
            end(complete: true)
            throw projectionPublicError(error)
        }
    }

    func cancel() {
        lifetime.cancel()
        lifetime.close()
    }

    private func begin() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !inFlight else {
            throw ProjectionReadError.invalidRequest("concurrent next calls on one projected iterator")
        }
        guard !finished else { return false }
        inFlight = true
        return true
    }

    private func end(complete: Bool) {
        lock.lock()
        inFlight = false
        finished = finished || complete
        lock.unlock()
        if complete { lifetime.close() }
    }
}

private func validateProjectionBatch(_ batch: ProjectionReadBatch, columns: Int, maximumRows: Int) throws {
    guard batch.rows.count <= maximumRows,
          batch.rows.allSatisfy({ $0.count == columns }),
          batch.isComplete || !batch.rows.isEmpty else {
        throw ProjectionReadError.database("malformed projected batch")
    }
}

private func decodeProjectionRows<Output: Sendable>(
    _ rows: [[ColumnValue]], deadline: UInt64, lifetime: ProjectionReadLifetime,
    decode: @Sendable ([ColumnValue]) throws -> Output
) throws -> [Output] {
    var values: [Output] = []
    values.reserveCapacity(rows.count)
    for row in rows {
        try lifetime.check(deadline: deadline)
        values.append(try decode(row))
    }
    try lifetime.check(deadline: deadline)
    return values
}

extension TableResults {
    /// Select stored scalar fields in caller order. Computed, relationship and
    /// collection key paths fail before any SQL executes.
    public func project<A: ProjectionScalar>(_ field1: KeyPath<Element, A>) throws -> ProjectedResults<A> {
        let descriptor = try _projectionDescriptor
        let columns = try [
            descriptor.schema.column(for: field1, on: Element.self)
        ]
        return ProjectedResults(descriptor: descriptor, columns: columns) { row in
            try A.decodeProjectionValue(row[0])
        }
    }

    public func project<A: ProjectionScalar, B: ProjectionScalar>(_ field1: KeyPath<Element, A>, _ field2: KeyPath<Element, B>) throws -> ProjectedResults<(A, B)> {
        let descriptor = try _projectionDescriptor
        let columns = try [
            descriptor.schema.column(for: field1, on: Element.self),
            descriptor.schema.column(for: field2, on: Element.self)
        ]
        return ProjectedResults(descriptor: descriptor, columns: columns) { row in
            try (A.decodeProjectionValue(row[0]), B.decodeProjectionValue(row[1]))
        }
    }

    public func project<A: ProjectionScalar, B: ProjectionScalar, C: ProjectionScalar>(_ field1: KeyPath<Element, A>, _ field2: KeyPath<Element, B>, _ field3: KeyPath<Element, C>) throws -> ProjectedResults<(A, B, C)> {
        let descriptor = try _projectionDescriptor
        let columns = try [
            descriptor.schema.column(for: field1, on: Element.self),
            descriptor.schema.column(for: field2, on: Element.self),
            descriptor.schema.column(for: field3, on: Element.self)
        ]
        return ProjectedResults(descriptor: descriptor, columns: columns) { row in
            try (A.decodeProjectionValue(row[0]), B.decodeProjectionValue(row[1]), C.decodeProjectionValue(row[2]))
        }
    }

    public func project<A: ProjectionScalar, B: ProjectionScalar, C: ProjectionScalar, D: ProjectionScalar>(_ field1: KeyPath<Element, A>, _ field2: KeyPath<Element, B>, _ field3: KeyPath<Element, C>, _ field4: KeyPath<Element, D>) throws -> ProjectedResults<(A, B, C, D)> {
        let descriptor = try _projectionDescriptor
        let columns = try [
            descriptor.schema.column(for: field1, on: Element.self),
            descriptor.schema.column(for: field2, on: Element.self),
            descriptor.schema.column(for: field3, on: Element.self),
            descriptor.schema.column(for: field4, on: Element.self)
        ]
        return ProjectedResults(descriptor: descriptor, columns: columns) { row in
            try (A.decodeProjectionValue(row[0]), B.decodeProjectionValue(row[1]), C.decodeProjectionValue(row[2]), D.decodeProjectionValue(row[3]))
        }
    }

    public func project<A: ProjectionScalar, B: ProjectionScalar, C: ProjectionScalar, D: ProjectionScalar, E: ProjectionScalar>(_ field1: KeyPath<Element, A>, _ field2: KeyPath<Element, B>, _ field3: KeyPath<Element, C>, _ field4: KeyPath<Element, D>, _ field5: KeyPath<Element, E>) throws -> ProjectedResults<(A, B, C, D, E)> {
        let descriptor = try _projectionDescriptor
        let columns = try [
            descriptor.schema.column(for: field1, on: Element.self),
            descriptor.schema.column(for: field2, on: Element.self),
            descriptor.schema.column(for: field3, on: Element.self),
            descriptor.schema.column(for: field4, on: Element.self),
            descriptor.schema.column(for: field5, on: Element.self)
        ]
        return ProjectedResults(descriptor: descriptor, columns: columns) { row in
            try (A.decodeProjectionValue(row[0]), B.decodeProjectionValue(row[1]), C.decodeProjectionValue(row[2]), D.decodeProjectionValue(row[3]), E.decodeProjectionValue(row[4]))
        }
    }

    public func project<A: ProjectionScalar, B: ProjectionScalar, C: ProjectionScalar, D: ProjectionScalar, E: ProjectionScalar, F: ProjectionScalar>(_ field1: KeyPath<Element, A>, _ field2: KeyPath<Element, B>, _ field3: KeyPath<Element, C>, _ field4: KeyPath<Element, D>, _ field5: KeyPath<Element, E>, _ field6: KeyPath<Element, F>) throws -> ProjectedResults<(A, B, C, D, E, F)> {
        let descriptor = try _projectionDescriptor
        let columns = try [
            descriptor.schema.column(for: field1, on: Element.self),
            descriptor.schema.column(for: field2, on: Element.self),
            descriptor.schema.column(for: field3, on: Element.self),
            descriptor.schema.column(for: field4, on: Element.self),
            descriptor.schema.column(for: field5, on: Element.self),
            descriptor.schema.column(for: field6, on: Element.self)
        ]
        return ProjectedResults(descriptor: descriptor, columns: columns) { row in
            try (A.decodeProjectionValue(row[0]), B.decodeProjectionValue(row[1]), C.decodeProjectionValue(row[2]), D.decodeProjectionValue(row[3]), E.decodeProjectionValue(row[4]), F.decodeProjectionValue(row[5]))
        }
    }

}
