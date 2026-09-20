import Foundation
import NIOCore
import NIOConcurrencyHelpers

/// Exact-mount injection for production-path tests; production reads once at
/// mount creation and otherwise uses the process service.
enum RelayApplyAdmissionTesting {
    private static let mounts = NIOLockedValueBox<[URL: RelayApplyAdmission]>([:])
    static func install(_ service: RelayApplyAdmission, for url: URL) {
        mounts.withLockedValue { $0[url] = service }
    }
    static func service(for url: URL) -> RelayApplyAdmission? { mounts.withLockedValue { $0[url] } }
    static func remove(_ service: RelayApplyAdmission, for url: URL) {
        mounts.withLockedValue { if $0[url] === service { $0[url] = nil } }
    }
}

enum RelayApplyAdmissionError: Error, Sendable, Equatable {
    case overloaded, shutdown, cancelled
}

/// Opt-in test handle invoking the same state transition as task cancellation.
struct RelayApplyTestCancellation: Sendable {
    let cancel: @Sendable () -> Void
}

private enum RelayApplyInput: Sendable {
    case buffer(ByteBuffer)
    case ingress(RelayIngressFrame)
    var byteCount: Int {
        switch self {
        case .buffer(let buffer): buffer.readableBytes
        case .ingress(let frame): frame.byteCount
        }
    }
    func makeOwnedCopy() -> Data {
        switch self {
        case .buffer(let buffer):
            buffer.withUnsafeReadableBytes { bytes in
                bytes.isEmpty ? Data() : Data(bytes: bytes.baseAddress!, count: bytes.count)
            }
        case .ingress(let frame): frame.copyForApply()
        }
    }
}

/// Bounds this service's requests and owned input payload, not upstream socket
/// buffers, allocator overhead, parsed JSON, native copies or encoded output.
/// The process service shares the existing IO workers with watcher/setup work.
final class RelayApplyAdmission: Sendable {
    static let shared = RelayApplyAdmission(pool: .io)
    static let defaultMaxRequests = 64
    static let defaultMaxInputBytes = 64 * 1024 * 1024
    private let state: RelayApplyAdmissionState
    private let beforeCopyForTesting: (@Sendable () async -> Void)?
    private let beforeOperationForTesting: (@Sendable () -> Void)?
    private let didReserveForTesting: (@Sendable (RelayApplyTestCancellation) -> Void)?

    init(pool: RelayExecutionPool, maxRequests: Int = defaultMaxRequests,
         maxInputBytes: Int = defaultMaxInputBytes,
         beforeCopyForTesting: (@Sendable () async -> Void)? = nil,
         beforeOperationForTesting: (@Sendable () -> Void)? = nil,
         didReserveForTesting: (@Sendable (RelayApplyTestCancellation) -> Void)? = nil,
         afterResumeForTesting: (@Sendable () -> Void)? = nil) {
        precondition(maxRequests > 0 && maxRequests <= RelayApplyAdmission.defaultMaxRequests)
        precondition(maxInputBytes >= 0 && maxInputBytes <= RelayApplyAdmission.defaultMaxInputBytes)
        state = RelayApplyAdmissionState(pool: pool, maxRequests: maxRequests,
                                         maxInputBytes: maxInputBytes, afterResumeForTesting: afterResumeForTesting)
        self.beforeCopyForTesting = beforeCopyForTesting
        self.beforeOperationForTesting = beforeOperationForTesting
        self.didReserveForTesting = didReserveForTesting
    }

    /// Admission and FIFO position precede the explicit copy. Only owned Data
    /// enters the IO queue; a tiny slice cannot retain its large buffer backing
    /// there. Copying stays on the caller, while parsing/native work use IO.
    /// `completion` must not retain service input aliases beyond its return.
    /// Its return is the settlement boundary, not a socket write acknowledgement.
    func withAdmission<Value: Sendable>(
        for key: String, buffer: ByteBuffer,
        operation: @escaping @Sendable (Data) -> Value,
        completion: @escaping @Sendable (Value) async -> Void
    ) async throws {
        try await withAdmission(for: key, source: .buffer(buffer), operation: operation, completion: completion)
    }

    func withAdmission<Value: Sendable>(
        for key: String, frame: RelayIngressFrame,
        operation: @escaping @Sendable (Data) -> Value,
        completion: @escaping @Sendable (Value) async -> Void
    ) async throws {
        try await withAdmission(for: key, source: .ingress(frame), operation: operation, completion: completion)
    }

    private func withAdmission<Value: Sendable>(
        for key: String, source: RelayApplyInput,
        operation: @escaping @Sendable (Data) -> Value,
        completion: @escaping @Sendable (Value) async -> Void
    ) async throws {
        let job = RelayApplyAdmissionJob(key: key, inputBytes: source.byteCount)
        try state.reserve(job)
        let state = state
        let beforeCopy = beforeCopyForTesting
        let beforeOperation = beforeOperationForTesting
        didReserveForTesting?(.init(cancel: { state.cancel(job) }))
        try await withTaskCancellationHandler {
            if Task.isCancelled { state.cancel(job) }
            // Opt-in preparation rendezvous suspends test tasks; production's
            // nil hook takes no additional suspension. Keep the job preparing
            // and charged until the same publication below settles cancellation.
            if let beforeCopy { await beforeCopy() }
            var value: Value? = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
                // A preparing job cannot settle until this publication. Its
                // cancellation can race copying but cannot invoke native work.
                var input: Data?
                if state.needsCopy(job) {
                    input = source.makeOwnedCopy()
                } else { input = Data() }
                state.installPreparedInput(job, input: input!, operation: { input in
                    beforeOperation?()
                    let value = operation(input)
                    return { continuation.resume(returning: value) }
                }, reject: { error in continuation.resume(throwing: error) })
                input = nil
                state.preparationFinished(job)
            }
            // Running cancellation never replaces a committed/partial value.
            // Keep the request charge through governor and ACK/fan-out decisions.
            await completion(value!)
            withExtendedLifetime(value) {}
            value = nil
            await withCheckedContinuation { state.publicationFinished(job, waiter: $0) }
        } onCancel: {
            state.cancel(job)
        }
    }

    /// Test/owned-service lifecycle only. Production's process service does not
    /// stop the shared pool. Callers stop that pool separately after all users
    /// release it. Never await this from one of this service's operations.
    func closeAdmissionAndDrain() async {
        await withCheckedContinuation { state.close(waiter: $0) }
    }

    var snapshot: RelayApplyAdmissionSnapshot { state.snapshot }
}

struct RelayApplyAdmissionSnapshot: Sendable {
    let requests: Int
    let inputBytes: Int
    let preparing: Int
    let queued: Int
    let submitted: Int
    let running: Int
    let publishing: Int
    let closed: Bool
}

private typealias RelayApplyCompletion = @Sendable () -> Void
private typealias RelayApplyOperation = @Sendable (Data) -> RelayApplyCompletion
private typealias RelayApplyRejection = @Sendable (RelayApplyAdmissionError) -> Void

/// Mutable fields belong to RelayApplyAdmissionState's lock. A preparing entry
/// retains no borrowed buffer. Running work takes its closure off this object;
/// final closure/capture destruction always occurs outside the state lock.
private final class RelayApplyAdmissionJob: @unchecked Sendable {
    enum Phase: Equatable { case preparing, queued, submitted, running, publishing, releasing, settled }
    let key: String
    let inputBytes: Int
    var phase: Phase = .preparing
    var cancellation: RelayApplyAdmissionError?
    var input: Data?
    var operation: RelayApplyOperation?
    var reject: RelayApplyRejection?
    var workerPublicationFinished = false
    var consumerPublicationFinished = false
    var publicationWaiter: CheckedContinuation<Void, Never>?

    init(key: String, inputBytes: Int) { self.key = key; self.inputBytes = inputBytes }
}

private final class RelayApplyAdmissionState: @unchecked Sendable {
    private let lock = NSLock()
    private let pool: RelayExecutionPool
    private let maxRequests: Int
    private let maxInputBytes: Int
    private let afterResumeForTesting: (@Sendable () -> Void)?
    private var jobs: [ObjectIdentifier: RelayApplyAdmissionJob] = [:]
    private var files: [String: [RelayApplyAdmissionJob]] = [:]
    private var inputBytes = 0
    private var closed = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    init(pool: RelayExecutionPool, maxRequests: Int, maxInputBytes: Int,
         afterResumeForTesting: (@Sendable () -> Void)?) {
        self.pool = pool; self.maxRequests = maxRequests; self.maxInputBytes = maxInputBytes
        self.afterResumeForTesting = afterResumeForTesting
    }

    func reserve(_ job: RelayApplyAdmissionJob) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw RelayApplyAdmissionError.shutdown }
        guard job.inputBytes >= 0, jobs.count < maxRequests,
              job.inputBytes <= maxInputBytes - inputBytes else {
            throw RelayApplyAdmissionError.overloaded
        }
        inputBytes += job.inputBytes
        jobs[ObjectIdentifier(job)] = job
        files[job.key, default: []].append(job)
    }

    func needsCopy(_ job: RelayApplyAdmissionJob) -> Bool {
        lock.lock(); defer { lock.unlock() }
        precondition(job.phase == .preparing)
        return job.cancellation == nil
    }

    func installPreparedInput(_ job: RelayApplyAdmissionJob, input: Data,
                  operation: @escaping RelayApplyOperation,
                  reject: @escaping RelayApplyRejection) {
        lock.lock()
        precondition(job.phase == .preparing)
        job.input = input; job.operation = operation; job.reject = reject
        lock.unlock()
    }

    func preparationFinished(_ job: RelayApplyAdmissionJob) {
        lock.lock()
        precondition(job.phase == .preparing)
        job.phase = .queued
        let cancelled = job.cancellation
        if cancelled != nil {
            removeFromFile(job)
            job.phase = .releasing
        }
        let next = nextHead(job.key)
        lock.unlock()
        if let cancelled { discard(job, error: cancelled) }
        submit(next)
    }

    /// Caller owns lock. A preparing head blocks later same-file copies from
    /// overtaking it. Only one head per file can be submitted/running.
    private func nextHead(_ key: String) -> RelayApplyAdmissionJob? {
        guard let head = files[key]?.first, head.phase == .queued else { return nil }
        head.phase = .submitted
        return head
    }

    private func removeFromFile(_ job: RelayApplyAdmissionJob) {
        guard var queue = files[job.key], let index = queue.firstIndex(where: { $0 === job }) else {
            preconditionFailure("apply request lost its FIFO position")
        }
        queue.remove(at: index) // Entire service is capped at 64 entries.
        files[job.key] = queue.isEmpty ? nil : queue
    }

    private func submit(_ job: RelayApplyAdmissionJob?) {
        guard let job else { return }
        guard pool.submit(for: job.key, { self.execute(job) }) else {
            lock.lock()
            precondition(job.phase == .submitted)
            removeFromFile(job)
            job.phase = .releasing
            let error = job.cancellation ?? .shutdown
            let next = nextHead(job.key)
            lock.unlock()
            discard(job, error: error)
            submit(next)
            return
        }
    }

    private struct Work {
        let input: Data
        let operation: RelayApplyOperation
    }

    private func execute(_ job: RelayApplyAdmissionJob) {
        lock.lock()
        precondition(job.phase == .submitted)
        if let cancelled = job.cancellation {
            removeFromFile(job)
            job.phase = .releasing
            let next = nextHead(job.key)
            lock.unlock()
            discard(job, error: cancelled)
            submit(next)
            return
        }
        // This locked transition is the no-effects/running cancellation line.
        job.phase = .running
        var work: Work? = Work(input: job.input!, operation: job.operation!)
        job.operation = nil // Work holds the closure through unlock and execution.
        lock.unlock()
        var completion: RelayApplyCompletion? = work!.operation(work!.input)
        work = nil // Release native owner/parse captures on IO, outside locks.
        lock.lock()
        precondition(job.phase == .running)
        job.phase = .publishing
        removeFromFile(job)
        let rejection = job.reject
        job.reject = nil
        let next = nextHead(job.key)
        lock.unlock()
        withExtendedLifetime(rejection) {}
        submit(next)
        completion?()
        afterResumeForTesting?()
        withExtendedLifetime(completion) {}
        completion = nil
        workerPublicationFinished(job)
    }

    func cancel(_ job: RelayApplyAdmissionJob) {
        lock.lock()
        switch job.phase {
        case .preparing, .submitted:
            // Submitted tombstones retain count until their IO turn runs.
            job.cancellation = job.cancellation ?? .cancelled
            lock.unlock()
        case .queued:
            job.cancellation = job.cancellation ?? .cancelled
            let error = job.cancellation!
            job.phase = .releasing
            removeFromFile(job)
            let next = nextHead(job.key)
            lock.unlock()
            discard(job, error: error)
            submit(next)
        case .running, .publishing, .releasing, .settled:
            // In-flight writes are not interruptible reads. Preserve result.
            lock.unlock()
        }
    }

    /// Detach first, destroy captures outside locks, then release capacity.
    private func discard(_ job: RelayApplyAdmissionJob, error: RelayApplyAdmissionError) {
        lock.lock()
        job.phase = .releasing
        var input = job.input; job.input = nil
        var operation = job.operation; job.operation = nil
        let reject = job.reject; job.reject = nil
        lock.unlock()
        withExtendedLifetime(input) {}; withExtendedLifetime(operation) {}
        input = nil; operation = nil
        finishRelease(job)
        reject?(error)
    }

    func publicationFinished(_ job: RelayApplyAdmissionJob, waiter: CheckedContinuation<Void, Never>) {
        lock.lock()
        precondition(job.phase == .publishing)
        precondition(!job.consumerPublicationFinished)
        job.consumerPublicationFinished = true
        job.publicationWaiter = waiter
        let release = job.workerPublicationFinished
        if release { job.phase = .releasing }
        lock.unlock()
        if release { releasePublishedInput(job) }
    }

    private func workerPublicationFinished(_ job: RelayApplyAdmissionJob) {
        lock.lock()
        precondition(job.phase == .publishing && !job.workerPublicationFinished)
        job.workerPublicationFinished = true
        let release = job.consumerPublicationFinished
        if release { job.phase = .releasing }
        lock.unlock()
        if release { releasePublishedInput(job) }
    }

    private func releasePublishedInput(_ job: RelayApplyAdmissionJob) {
        lock.lock()
        precondition(job.phase == .releasing)
        var input = job.input; job.input = nil
        lock.unlock()
        withExtendedLifetime(input) {}
        input = nil
        finishRelease(job)
    }

    private func finishRelease(_ job: RelayApplyAdmissionJob) {
        lock.lock()
        precondition(job.phase == .releasing)
        job.phase = .settled
        jobs[ObjectIdentifier(job)] = nil
        inputBytes -= job.inputBytes
        let publicationWaiter = job.publicationWaiter
        job.publicationWaiter = nil
        let waiters = closed && jobs.isEmpty ? drainWaiters : []
        if !waiters.isEmpty { drainWaiters.removeAll() }
        lock.unlock()
        publicationWaiter?.resume()
        for waiter in waiters { waiter.resume() }
    }

    func close(waiter: CheckedContinuation<Void, Never>) {
        lock.lock()
        closed = true
        drainWaiters.append(waiter)
        let pending = Array(jobs.values)
        for job in pending where job.phase == .preparing || job.phase == .queued || job.phase == .submitted {
            job.cancellation = job.cancellation ?? .shutdown
        }
        let empty = jobs.isEmpty
        let waiters = empty ? drainWaiters : []
        if empty { drainWaiters.removeAll() }
        lock.unlock()
        for job in pending { cancel(job) }
        for waiter in waiters { waiter.resume() }
    }

    var snapshot: RelayApplyAdmissionSnapshot {
        lock.lock(); defer { lock.unlock() }
        let values = jobs.values
        return .init(requests: jobs.count, inputBytes: inputBytes,
                     preparing: values.filter { $0.phase == .preparing }.count,
                     queued: values.filter { $0.phase == .queued }.count,
                     submitted: values.filter { $0.phase == .submitted }.count,
                     running: values.filter { $0.phase == .running }.count,
                     publishing: values.filter { $0.phase == .publishing }.count,
                     closed: closed)
    }
}
