import Foundation
import NIOCore
import Vapor
import Lattice

// Inactive qualification-only machinery. No production mount selects this
// factory, and nothing here authenticates a source, recipient or scope.
enum RelayProtectedExportError: Error, Sendable, Equatable {
    case stopped, invalidPage, alreadyConsumed, failed(String)
}
struct RelayExportDeliveryReceipt: Sendable, Equatable {
    let count: Int
    let lastID: Int64
    let serial: UInt64
}
private func exportDiagnostic(_ error: any Error) -> String {
    // Do not invoke an arbitrary Error description or retain foreign payloads.
    "transport promise failed"
}

/// Immutable physical sink. ByteBuffer is the distinct NIO-owned output copy;
/// this boundary never lends native backing to NIO or returns Data to an actor.
struct RelayExportSink: Sendable {
    let eventLoop: any EventLoop
    let isClosed: @Sendable () -> Bool
    let write: @Sendable (ByteBuffer, EventLoopPromise<Void>) throws -> Void
    let close: @Sendable () -> Void

    init(socket: WebSocket) {
        eventLoop = socket.eventLoop
        isClosed = { socket.isClosed }
        write = { buffer, promise in socket.send(buffer, opcode: .binary, promise: promise) }
        close = { socket.close(promise: nil) }
    }
    // Mechanical qualification injection: actual NIO promises still govern
    // settlement. A throwing writer may have enqueued and must settle its own
    // exact promise; the wrapper never fabricates failure completion for it.
    init(eventLoop: any EventLoop, isClosed: @escaping @Sendable () -> Bool,
         write: @escaping @Sendable (ByteBuffer, EventLoopPromise<Void>) throws -> Void,
         close: @escaping @Sendable () -> Void) {
        self.eventLoop = eventLoop; self.isClosed = isClosed; self.write = write; self.close = close
    }
}

/// Nil by default; mechanical qualification only. This rendezvous owns no
/// callback/owner/payload, and waits only when explicitly armed by a test.
/// Its finite timeout is a failed fixture witness, never permission to send.
final class RelayExportQualificationRendezvous: @unchecked Sendable {
    private let condition = NSCondition()
    private var holdTransport = false
    private var transportClaimed = false
    private var nativeFinished = false
    private var holdPublication = false
    private var creditsReleased = false
    private var preparations = 0
    private var preparedStatus: RecoveryExportNativeStatus?
    private var preparedSerial: UInt64 = 0
    private var publications = 0
    private var timedOut = false
    func armPublication() { condition.lock(); holdPublication = true; condition.unlock() }
    func releasePublication() { condition.lock(); holdPublication = false; condition.broadcast(); condition.unlock() }
    func waitForCreditsRelease() -> Bool {
        condition.lock(); defer { condition.unlock() }; return wait { creditsReleased }
    }
    var preparationSnapshot: (count: Int, status: RecoveryExportNativeStatus?, serial: UInt64) {
        condition.lock(); defer { condition.unlock() }; return (preparations, preparedStatus, preparedSerial)
    }
    fileprivate func afterPreparation(status: RecoveryExportNativeStatus, serial: UInt64) {
        condition.lock(); preparations += 1; preparedStatus = status; preparedSerial = serial; condition.unlock()
    }
    fileprivate func afterCreditsRelease() {
        condition.lock(); creditsReleased = true; condition.broadcast()
        if holdPublication { _ = wait { !holdPublication } }
        condition.unlock()
    }
    func armTransport() { condition.lock(); holdTransport = true; condition.unlock() }
    func releaseTransport() { condition.lock(); holdTransport = false; condition.broadcast(); condition.unlock() }
    private func wait(_ predicate: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(5)
        while !predicate() {
            if !condition.wait(until: end) { timedOut = true; return false }
        }
        return true
    }
    func waitForTransportClaim() -> Bool {
        condition.lock(); defer { condition.unlock() }; return wait { transportClaimed }
    }
    var hasFinishedNative: Bool { condition.lock(); defer { condition.unlock() }; return nativeFinished }
    var publicationCount: Int { condition.lock(); defer { condition.unlock() }; return publications }
    var didTimeOut: Bool { condition.lock(); defer { condition.unlock() }; return timedOut }
    fileprivate func afterTransportClaim() {
        condition.lock(); transportClaimed = true; condition.broadcast()
        if holdTransport { _ = wait { !holdTransport } }
        condition.unlock()
    }
    fileprivate func afterNativeFinish() {
        condition.lock(); nativeFinished = true; condition.broadcast(); condition.unlock()
    }
    fileprivate func beforePublication() {
        condition.lock(); publications += 1; condition.unlock()
    }
}

/// Truly payload-free: no closure, owner, endpoint box, page or sink/context.
private final class RelayExportStopState: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var native: RecoveryExportNativeStop?
    func bind(_ value: RecoveryExportNativeStop) {
        lock.lock(); precondition(native == nil); native = value; let stop = stopped; lock.unlock()
        if stop { value.stop() }
    }
    func stop() {
        lock.lock(); stopped = true; let value = native; lock.unlock(); value?.stop()
    }
    var isStopped: Bool {
        lock.lock(); let stopped = stopped, value = native; lock.unlock()
        return stopped || value?.isStopped == true
    }
    var nativeReleased: Bool {
        lock.lock(); let value = native; lock.unlock()
        return value?.resourcesReleased ?? true
    }
}
/// Also payload-free. Three bounded transitions may attempt confirmation:
/// endpoint IO retirement, page IO retirement and exact transport settlement.
private final class RelayExportEndpointRelease: @unchecked Sendable {
    let permit: RelayExportAdmission.Endpoint
    let stop = RelayExportStopState()
    private let lock = NSLock()
    private var nativeBoxGone = false
    init(_ permit: RelayExportAdmission.Endpoint) { self.permit = permit }
    func markNativeBoxGone() {
        lock.lock(); nativeBoxGone = true; lock.unlock(); tryRelease()
    }
    func tryRelease() {
        lock.lock(); let gone = nativeBoxGone; lock.unlock()
        if gone && stop.nativeReleased { permit.confirmNativeRelease() }
    }
}

/// One immutable receipt cell, never an IO box. Its result/promise state owns
/// only scalars, copied diagnostic strings, payload-free native tokens and
/// accounting witnesses. It is removed from the native sink before enqueue.
private final class RelayExportPendingSend: @unchecked Sendable {
    let serial: UInt64
    let future: EventLoopFuture<RelayExportDeliveryReceipt>
    private let promise: EventLoopPromise<RelayExportDeliveryReceipt>
    private let lock = NSLock()
    private let completion: RecoveryExportNativeCompletion
    private let permit: RelayExportAdmission.Page
    private let endpoint: RelayExportEndpointRelease
    private let receipt: RelayExportDeliveryReceipt
    private var began = false
    private var transportClaimed = false
    private var transportDone = false
    private var transportSuccess = false
    private var transportMessage: String?
    private var nativeClaimed = false
    private var nativeDone = false
    private var nativeResult: RecoveryExportNativeResult?
    private var nativeAccounted = false
    private var transportAccounted = false
    private var published = false
    private weak var rendezvous: RelayExportQualificationRendezvous?

    init(loop: any EventLoop, page: RecoveryExportNativePage,
         permit: RelayExportAdmission.Page, endpoint: RelayExportEndpointRelease,
         rendezvous: RelayExportQualificationRendezvous?) {
        self.rendezvous = rendezvous
        serial = page.serial; completion = page.completion; self.permit = permit; self.endpoint = endpoint
        receipt = .init(count: page.count, lastID: page.lastID!, serial: page.serial)
        promise = loop.makePromise(of: RelayExportDeliveryReceipt.self); future = promise.futureResult
    }
    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !began, !transportClaimed else { return false }; began = true; return true
    }
    func transport(_ result: Result<Void, any Error>) {
        let succeeded: Bool, message: String?
        switch result { case .success: succeeded = true; message = nil
        case .failure(let error): succeeded = false; message = exportDiagnostic(error) }
        settleTransport(success: succeeded, message: message)
    }
    private func settleTransport(success: Bool, message: String?) {
        lock.lock()
        guard !transportClaimed else { lock.unlock(); return }
        transportClaimed = true
        lock.unlock()
        rendezvous?.afterTransportClaim()
        // Real token recording precedes publish-readiness; it has no callback
        // into this cell. Native IO completion may proceed independently.
        completion.record(success: success)
        lock.lock()
        transportSuccess = success; transportMessage = message; transportDone = true
        let decision = accountAndDecideLocked()
        lock.unlock()
        publish(decision)
    }
    func finishNative(_ result: RecoveryExportNativeResult) {
        lock.lock(); precondition(!nativeClaimed); nativeClaimed = true
        let noEnqueue = !began
        // Caller has already cleared EVERY IO-owned page copy. Only this
        // mutex's decision owner may return either remaining accounting credit.
        nativeResult = result; nativeDone = true
        let decision = accountAndDecideLocked()
        lock.unlock()
        publish(decision)
        if noEnqueue { settleTransport(success: false, message: result.message ?? "page was not enqueued") }
        rendezvous?.afterNativeFinish()
    }
    func definitelyNotEnqueued(_ message: String) { settleTransport(success: false, message: message) }
    /// Caller holds only pending.lock. Core token/stop and admission locks are
    /// callback-free scalar leaves; none acquire pending.lock in reverse.
    /// The first side can return its actual bytes, but the final page witness
    /// remains held until the immutable old-serial decision has been sampled.
    private func accountAndDecideLocked() -> Result<RelayExportDeliveryReceipt, RelayProtectedExportError>? {
        var decision: Result<RelayExportDeliveryReceipt, RelayProtectedExportError>?
        if !published, nativeDone, transportDone, let nativeResult {
            published = true
            let stopped = endpoint.stop.isStopped
            let success = transportSuccess && nativeResult.status == .enqueued && completion.permitsAdvance && !stopped
            decision = success ? .success(receipt) : .failure(stopped ? .stopped :
                .failed(nativeResult.message ?? transportMessage ?? "export handoff refused"))
        }
        // The serial cannot advance through this wrapper while either witness
        // is withheld. No independent completion can release it behind us.
        if nativeDone && !nativeAccounted { nativeAccounted = true; permit.confirmNativeRelease() }
        if transportDone && !transportAccounted { transportAccounted = true; permit.confirmTransportSettlement() }
        return decision
    }
    private func publish(_ decision: Result<RelayExportDeliveryReceipt, RelayProtectedExportError>?) {
        endpoint.tryRelease()
        guard let decision else { return }
        rendezvous?.afterCreditsRelease()
        rendezvous?.beforePublication()
        // Actual credits are returned before continuations can prepare another
        // page. Never re-read its now-mutable Core serial or stop state here.
        switch decision { case .success(let value): promise.succeed(value)
        case .failure(let error): promise.fail(error) }
    }

}

/// Native callback context, accessed/released only on IO. Its pending slot is
/// taken BEFORE invoking NIO, so it cannot retain an awaiting delivery task
/// back through the native endpoint. Promise callbacks never capture this box.
private final class RelayExportSinkState: @unchecked Sendable {
    let sink: RelayExportSink
    private let onIO: @Sendable () -> Bool
    private let wireBytes: Int
    private var pending: RelayExportPendingSend?
    init(sink: RelayExportSink, wireBytes: Int, onIO: @escaping @Sendable () -> Bool) {
        self.sink = sink; self.wireBytes = wireBytes; self.onIO = onIO
    }
    deinit { precondition(onIO()); precondition(pending == nil) }
    func install(_ value: RelayExportPendingSend) { precondition(onIO()); precondition(pending == nil); pending = value }
    func discard(_ value: RelayExportPendingSend) {
        precondition(onIO()); if pending === value { pending = nil }
    }
    func enqueue(_ bytes: UnsafeBufferPointer<UInt8>, serial: UInt64) -> Int32 {
        precondition(onIO())
        guard let value = pending, value.serial == serial else { return 0 }
        pending = nil
        guard bytes.count <= wireBytes, !sink.isClosed(), value.begin() else {
            value.definitelyNotEnqueued("closed sink, stale page or output limit"); return 0
        }
        let promise = sink.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenComplete { result in value.transport(result) }
        // A single explicit native-to-NIO copy, made on IO. NIO owns any
        // later buffer retention/release; successful write is not RSS proof.
        var output = ByteBufferAllocator().buffer(capacity: bytes.count)
        output.writeBytes(bytes)
        do { try sink.write(output, promise); return 1 }
        catch { return 2 } // possibly enqueued; actual promise must still settle
    }
}
private final class RelayExportEndpointBox: @unchecked Sendable {
    let onIO: @Sendable () -> Bool
    var native: RecoveryExportNativeEndpoint?
    var sink: RelayExportSinkState?
    init(native: RecoveryExportNativeEndpoint, sink: RelayExportSinkState, onIO: @escaping @Sendable () -> Bool) {
        precondition(onIO()); self.native = native; self.sink = sink; self.onIO = onIO
    }
    deinit { precondition(onIO()); precondition(native == nil && sink == nil) }
    func close() {
        precondition(onIO()); sink?.sink.close(); native?.close(); native = nil; sink = nil
    }
}
private final class RelayExportPageBox: @unchecked Sendable {
    private let onIO: @Sendable () -> Bool
    private var native: RecoveryExportNativePage?
    private var sink: RelayExportSinkState?
    let pending: RelayExportPendingSend
    init(native: RecoveryExportNativePage, sink: RelayExportSinkState, pending: RelayExportPendingSend,
         onIO: @escaping @Sendable () -> Bool) {
        precondition(onIO()); self.native = native; self.sink = sink; self.pending = pending; self.onIO = onIO
    }
    // A submitter may retain an empty box until submitRequired returns.
    // Only the already-cleared shell may then die off IO.
    deinit { precondition(native == nil && sink == nil) }
    private func retireNative(consume: Bool) -> RecoveryExportNativeResult? {
        precondition(onIO()); guard let page = native else { return nil }; native = nil
        let result = consume ? page.consume() : page.result
        sink?.discard(pending); sink = nil
        page.close()
        return result // `page` and every native copy die on this IO stack.
    }
    func finish(consume: Bool) {
        precondition(onIO())
        if let result = retireNative(consume: consume) { pending.finishNative(result) }
    }
}

/// The opening job captures only this take-once box, never its payload.
/// Empty box destruction may occur on a submitting thread; every owned input
/// and original thrown error is disposed/transferred on the IO call stack.
private final class RelayExportOpeningInputs: @unchecked Sendable {
    private struct Payload {
        let sink: RelayExportSink
        let released: @Sendable () -> Void
        let factory: @Sendable () throws -> Lattice
    }
    private var payload: Payload?
    init(sink: RelayExportSink, released: @escaping @Sendable () -> Void,
         factory: @escaping @Sendable () throws -> Lattice) {
        payload = .init(sink: sink, released: released, factory: factory)
    }
    deinit { precondition(payload == nil) }
    func consume(stopped: Bool, limits: RecoveryExportNativeLimits,
                 onIO: @escaping @Sendable () -> Bool) -> Result<RelayExportEndpointBox, RelayProtectedExportError>? {
        precondition(onIO()); precondition(payload != nil)
        let inputs = payload!; payload = nil
        guard !stopped else { return nil }
        do {
            let owner = try inputs.factory()
            let state = RelayExportSinkState(sink: inputs.sink, wireBytes: limits.wireBytes, onIO: onIO)
            let native = try RecoveryExportNativeEndpoint(forQualification: owner, limits: limits, onIO: onIO,
                enqueue: { bytes, serial in state.enqueue(bytes, serial: serial) }, contextReleased: inputs.released)
            return .success(.init(native: native, sink: state, onIO: onIO))
        } catch {
            return .failure(.failed("native endpoint construction failed"))
        }
        // `inputs` (including untransferred factory captures) and every native
        // temporary/original error die before this helper returns to publication.
    }
}

/// Shared shell storage. Native fields are touched only by this endpoint's IO
/// key. An empty slot may die anywhere; a nonempty slot may never be abandoned.
private final class RelayExportEndpointSlot: @unchecked Sendable {
    var box: RelayExportEndpointBox?
    deinit { precondition(box == nil) }
    func retire(onIO: @Sendable () -> Bool) {
        precondition(onIO()); box?.close(); box = nil
    }
}

enum RelayExportPreparation: Sendable {
    case empty // sampled view only: never a caught-up/frontier receipt
    case page(RelayExportPage)
}

/// Inactive mechanical wrapper. One endpoint credit owns its opening turn and
/// at most one coalesced retirement turn; one page credit owns its preparation
/// and at most one consume/discard turn. The supplied pool must stay admitted
/// until these jobs finish, exactly like the existing relay actor IO lanes.
final class RelayProtectedExport: @unchecked Sendable {
    private let pool: RelayExecutionPool
    private let key: String
    private let loop: any EventLoop
    private let slot = RelayExportEndpointSlot()
    private let release: RelayExportEndpointRelease
    private let limits: RecoveryExportNativeLimits
    let ready: EventLoopFuture<Void>
    private weak var rendezvous: RelayExportQualificationRendezvous?

    // Logical payload only: raw+decoded originals, copied frame entries,
    // addressed re-read and transient decoded values each receive R; JSON
    // object copies/dump/aggregate or aggregate/binary temporary/final bytes
    // receive four W allowances. Independent inventory/claim/schema metadata,
    // containers/allocator overhead and NIO capacity rounding are excluded.
    // These validated hard maxima keep the arithmetic representable on 32 bit.
    static func nativeCharge(_ limits: RecoveryExportNativeLimits) -> Int {
        4 * limits.rawBytes + 4 * limits.wireBytes
    }

    init(forQualification service: RelayExportAdmission, limits: RecoveryExportNativeLimits,
         pool: RelayExecutionPool, key: String, sink: RelayExportSink,
         rendezvous: RelayExportQualificationRendezvous? = nil,
         contextReleased: @escaping @Sendable () -> Void = {},
         makeLattice: @escaping @Sendable () throws -> Lattice) throws {
        // This reservation precedes context creation, native allocation and IO.
        let permit = try service.reserveEndpoint()
        let release = RelayExportEndpointRelease(permit)
        self.rendezvous = rendezvous
        self.release = release; self.pool = pool; self.key = key; self.loop = sink.eventLoop; self.limits = limits
        let promise = sink.eventLoop.makePromise(of: Void.self); ready = promise.futureResult
        let slot = self.slot
        let inputs = RelayExportOpeningInputs(sink: sink, released: contextReleased, factory: makeLattice)
        pool.submitRequired(for: key) {
            let onIO: @Sendable () -> Bool = { pool.isCurrentWorker }
            guard let built = inputs.consume(stopped: release.stop.isStopped, limits: limits, onIO: onIO) else {
                permit.beginRetirement(); release.markNativeBoxGone()
                promise.fail(RelayProtectedExportError.stopped); return
            }
            switch built {
            case .success(let box):
                slot.box = box; release.stop.bind(box.native!.stop)
                if release.stop.isStopped {
                    slot.retire(onIO: onIO); permit.beginRetirement(); release.markNativeBoxGone()
                    promise.fail(RelayProtectedExportError.stopped)
                } else { promise.succeed(()) }
            case .failure(let error):
                // The opening input helper has already disposed original captures/errors on IO.
                release.stop.stop(); permit.beginRetirement(); slot.retire(onIO: onIO)
                release.markNativeBoxGone(); promise.fail(error)
            }
        }
    }
    deinit { close() }
    func close() {
        release.stop.stop()
        guard release.permit.beginRetirement() else { return }
        let slot = slot, release = release, pool = pool
        pool.submitRequired(for: key) {
            slot.retire(onIO: { pool.isCurrentWorker })
            release.markNativeBoxGone()
        }
    }
    func waitUntilReady() async throws {
        try await withTaskCancellationHandler(operation: {
            try await ready.get(); try Task.checkCancellation()
        }, onCancel: { self.close() })
    }
    func prepare(after lastID: Int64, count: Int) throws -> EventLoopFuture<RelayExportPreparation> {
        guard lastID >= 0, count > 0, count <= limits.entries else { throw RelayProtectedExportError.invalidPage }
        let permit = try release.permit.reservePage(nativeBytes: Self.nativeCharge(limits), outputBytes: limits.wireBytes)
        let promise = loop.makePromise(of: RelayExportPreparation.self)
        let slot = slot, release = release, pool = pool, key = key, loop = loop, rendezvous = rendezvous
        pool.submitRequired(for: key) { [weak self] in
            // Finish all native locals in a helper before releasing a failed or
            // empty preparation's charge. Future contains only a page shell.
            do {
                let preparation = try Self.prepareOnIO(slot: slot, release: release, permit: permit,
                    pool: pool, key: key, loop: loop, endpointShell: self, rendezvous: rendezvous, after: lastID, count: count)
                if case .empty = preparation {
                    permit.confirmNativeRelease(); permit.confirmTransportSettlement(); release.tryRelease()
                }
                promise.succeed(preparation)
            } catch {
                permit.confirmNativeRelease(); permit.confirmTransportSettlement(); release.tryRelease()
                promise.fail(release.stop.isStopped ? RelayProtectedExportError.stopped :
                    RelayProtectedExportError.failed("native history preparation refused"))
            }
        }
        return promise.futureResult
    }
    private static func prepareOnIO(slot: RelayExportEndpointSlot, release: RelayExportEndpointRelease,
                                    permit: RelayExportAdmission.Page, pool: RelayExecutionPool, key: String,
                                    loop: any EventLoop, endpointShell: RelayProtectedExport?, rendezvous: RelayExportQualificationRendezvous?, after: Int64, count: Int) throws -> RelayExportPreparation {
        precondition(pool.isCurrentWorker)
        guard !release.stop.isStopped, let endpoint = slot.box,
              let native = endpoint.native, let sink = endpoint.sink else { throw RelayProtectedExportError.stopped }
        let page = native.prepare(after: after, count: count)
        rendezvous?.afterPreparation(status: page.result.status, serial: page.serial)
        guard page.result.status == .ready else {
            page.close()
            if page.result.status == .empty { return .empty }
            throw RelayProtectedExportError.failed("protected history page unavailable")
        }
        guard page.count > 0, page.count <= count, page.lastID != nil,
              page.lastID! > after, page.serial != 0, page.completion.isValid,
              !release.stop.isStopped else { page.close(); throw RelayProtectedExportError.invalidPage }
        let pending = RelayExportPendingSend(loop: loop, page: page, permit: permit, endpoint: release, rendezvous: rendezvous)
        sink.install(pending)
        let box = RelayExportPageBox(native: page, sink: sink, pending: pending, onIO: { pool.isCurrentWorker })
        return .page(RelayExportPage(box: box, pool: pool, key: key, release: release, endpoint: endpointShell))
    }
}

/// Copies share one take-once identity. Neither the control wrapper nor its
/// future exposes bytes, an alternate sink, native owner or an endpoint ID.
final class RelayExportPage: @unchecked Sendable {
    private let lock = NSLock()
    private var box: RelayExportPageBox?
    private let pool: RelayExecutionPool
    private let key: String
    private let release: RelayExportEndpointRelease
    private weak var endpoint: RelayProtectedExport?
    private let delivery: EventLoopFuture<RelayExportDeliveryReceipt>
    fileprivate init(box: RelayExportPageBox, pool: RelayExecutionPool, key: String,
                     release: RelayExportEndpointRelease, endpoint: RelayProtectedExport?) {
        self.endpoint = endpoint
        self.box = box; self.pool = pool; self.key = key; self.release = release
        delivery = box.pending.future
    }
    private func take() -> RelayExportPageBox? {
        lock.lock(); defer { lock.unlock() }; let value = box; box = nil; return value
    }
    deinit { close() }
    func close() {
        guard let box = take() else { return }
        pool.submitRequired(for: key) { box.finish(consume: false) }
    }
    // Synchronous handoff only queues one IO turn; no SQL or payload release
    // occurs on the caller's actor/event loop. Advance only after this future.
    func consume() throws -> EventLoopFuture<RelayExportDeliveryReceipt> {
        guard let box = take() else { throw RelayProtectedExportError.alreadyConsumed }
        pool.submitRequired(for: key) { box.finish(consume: true) }
        return delivery
    }
    func consumeAndWait() async throws -> RelayExportDeliveryReceipt {
        try await withTaskCancellationHandler(operation: {
            let result = try await consume().get(); try Task.checkCancellation(); return result
        }, onCancel: {
            // Request-only: an admitted sink promise must actually settle. The
            // endpoint shell owns socket retirement; this token cannot do IO.
            self.endpoint?.close(); self.release.stop.stop(); self.close()
        })
    }
}
