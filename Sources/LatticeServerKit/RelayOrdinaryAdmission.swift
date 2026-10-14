import Foundation
import NIOConcurrencyHelpers

/// Payload-free FIFO admission. An existing endpoint owns at most one outgoing
/// request and one ingress request. Queued ingress bytes retain their original
/// RelayIngressFrame charge; native cuts and Data are not allocated while queued.
/// Callbacks, charges and callback captures are always released outside the lock.
final class RelayOrdinaryAdmission: @unchecked Sendable {
    // One process-wide turn covers actual required-upload receive AND merge.
    // Three other staged results + this turn's four native slots peak at seven
    // of the existing eight. Other native API users can still refuse capacity;
    // generic invalid/error results are never classified as retryable here.
    static let nativeIntake = RelayOrdinaryAdmission(cuts: 1, staging: 1)
    enum Kind: Sendable { case cut, staging }
    enum Failure: Error, Sendable { case cancelled, queueFull, timedOut }
    struct Snapshot: Sendable, Equatable { let activeCuts, activeStaging, queuedCuts, queuedStaging: Int }
    final class Lease: @unchecked Sendable {
        private let service: RelayOrdinaryAdmission
        fileprivate let kind: Kind
        fileprivate init(_ service: RelayOrdinaryAdmission, _ kind: Kind) { self.service = service; self.kind = kind }
        deinit { service.release(kind) }
    }
    final class Request: @unchecked Sendable {
        fileprivate enum State: Equatable { case created, queued, completed }
        fileprivate let service: RelayOrdinaryAdmission, kind: Kind
        fileprivate let completion: @Sendable (Result<Lease, Failure>) -> Void
        fileprivate var state = State.created // service.lock only
        let deadline: UInt64
        var expired: Bool { DispatchTime.now().uptimeNanoseconds >= deadline }
        fileprivate init(_ service: RelayOrdinaryAdmission, _ kind: Kind,
                         _ completion: @escaping @Sendable (Result<Lease, Failure>) -> Void) {
            self.service = service; self.kind = kind; self.completion = completion
            let (end, overflow) = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(30_000_000_000)
            deadline = overflow ? UInt64.max : end
        }
        // Publish the request in its owner's cancellation slot before begin().
        func begin() { service.begin(self) }
        func cancel() { service.cancel(self) }
    }
    private struct Delivery { let request: Request; let result: Result<Lease, Failure> }
    private let lock = NIOLock()
    private var cuts = 0, staging = 0
    private var cutQueue: [Request] = [], stagingQueue: [Request] = []
    private let cutLimit: Int, stagingLimit: Int
    private let queuedLimit = 128 // 64 existing endpoints, one outgoing + one ingress each
    init(cuts: Int = 4, staging: Int = 4) {
        precondition((1...4).contains(cuts) && (1...4).contains(staging))
        cutLimit = cuts; stagingLimit = staging
    }
    var snapshot: Snapshot { lock.withLock { .init(activeCuts: cuts, activeStaging: staging, queuedCuts: cutQueue.count, queuedStaging: stagingQueue.count) } }
    func request(_ kind: Kind, _ completion: @escaping @Sendable (Result<Lease, Failure>) -> Void) -> Request {
        Request(self, kind, completion)
    }
    // Compatibility for direct synchronous callers. Never jumps a queued owner.
    func reserve(_ kind: Kind) throws -> Lease {
        let lease: Lease? = lock.withLock {
            switch kind {
            case .cut:
                guard cutQueue.isEmpty, cuts < cutLimit else { return nil }
                cuts += 1
            case .staging:
                guard stagingQueue.isEmpty, staging < stagingLimit else { return nil }
                staging += 1
            }
            return Lease(self, kind)
        }
        guard let lease else { throw RelayOrdinaryError.capacity }
        return lease
    }
    private func deliver(_ deliveries: [Delivery]) {
        for delivery in deliveries { delivery.request.completion(delivery.result) }
    }
    // Returned deliveries own every removed request through mutex release.
    private func drainLocked() -> [Delivery] {
        var deliveries: [Delivery] = []
        while cuts < cutLimit, !cutQueue.isEmpty {
            let request = cutQueue.removeFirst(); request.state = .completed
            if request.expired { deliveries.append(.init(request: request, result: .failure(.timedOut))); continue }
            cuts += 1
            deliveries.append(.init(request: request, result: .success(Lease(self, .cut))))
        }
        while staging < stagingLimit, !stagingQueue.isEmpty {
            let request = stagingQueue.removeFirst(); request.state = .completed
            if request.expired { deliveries.append(.init(request: request, result: .failure(.timedOut))); continue }
            staging += 1
            deliveries.append(.init(request: request, result: .success(Lease(self, .staging))))
        }
        return deliveries
    }
    private func begin(_ request: Request) {
        let deliveries: [Delivery] = lock.withLock {
            guard request.state == .created else { return [] }
            guard cutQueue.count + stagingQueue.count < queuedLimit else {
                request.state = .completed
                return [.init(request: request, result: .failure(.queueFull))]
            }
            request.state = .queued
            switch request.kind { case .cut: cutQueue.append(request); case .staging: stagingQueue.append(request) }
            return drainLocked()
        }
        deliver(deliveries)
    }
    private func cancel(_ request: Request) {
        let deliveries: [Delivery] = lock.withLock {
            guard request.state != .completed else { return [] }
            request.state = .completed
            // The caller and Delivery retain request before queue removal, so
            // even reentrant last-owner destruction cannot happen under lock.
            var result = [Delivery(request: request, result: .failure(.cancelled))]
            switch request.kind {
            case .cut: cutQueue.removeAll { $0 === request }
            case .staging: stagingQueue.removeAll { $0 === request }
            }
            result.append(contentsOf: drainLocked())
            return result
        }
        deliver(deliveries)
    }
    private func release(_ kind: Kind) {
        let deliveries: [Delivery] = lock.withLock {
            switch kind { case .cut: precondition(cuts > 0); cuts -= 1; case .staging: precondition(staging > 0); staging -= 1 }
            return drainLocked()
        }
        deliver(deliveries)
    }
}

/// Handles cancellation racing request construction. Extract ownership while
/// locked and cancel only after unlock; completion may reenter this slot.
final class RelayOrdinaryAdmissionSlot: @unchecked Sendable {
    private let lock = NIOLock()
    private var stopped = false
    private var request: RelayOrdinaryAdmission.Request?
    func install(_ value: RelayOrdinaryAdmission.Request) -> Bool {
        let accepted = lock.withLock {
            guard !stopped, request == nil else { return false }
            request = value; return true
        }
        if !accepted { value.cancel() }
        return accepted
    }
    func clear(_ value: RelayOrdinaryAdmission.Request) {
        let retained = lock.withLock { () -> RelayOrdinaryAdmission.Request? in
            guard request === value else { return nil }
            let previous = request; request = nil; return previous
        }
        withExtendedLifetime(retained) {}
    }
    func stop() {
        let retained = lock.withLock { () -> RelayOrdinaryAdmission.Request? in
            stopped = true; let previous = request; request = nil; return previous
        }
        retained?.cancel()
    }
}
