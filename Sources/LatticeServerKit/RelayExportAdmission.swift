import Foundation

/// Qualification-only limits. Native/shim bytes and enqueued output have
/// different release witnesses. These logical charges are not a process RSS
/// bound, and a successful socket write does not prove NIO freed its backing.
struct RelayExportLimits: Sendable {
    let endpoints: Int
    let pages: Int
    let nativeBytes: Int
    let outputBytes: Int
}

enum RelayExportAdmissionError: Error, Sendable, Equatable {
    case invalidLimits, closed, endpoints, endpointStopped, pageBusy
    case invalidCharge, pages, nativeBytes, outputBytes
}

struct RelayExportAdmissionSnapshot: Sendable, Equatable {
    let closed: Bool
    let endpoints: Int
    let pages: Int
    let nativeBytes: Int
    let outputBytes: Int
}

/// Accounting only: owns no payloads, native handles, sockets, tasks, callbacks
/// or retirement queue. The IO wrapper must reserve before allocating a native
/// context/frame or submitting work. Dropping a lease is deliberately NOT a
/// release witness. An abandoned witness conservatively retains its charge.
///
/// This service is not selected by any production relay route. It neither
/// authorizes export nor validates the caller's conservative byte estimate.
final class RelayExportAdmission: @unchecked Sendable {
    let limits: RelayExportLimits
    private let lock = NSLock()
    private var closed = false
    private var endpointCount = 0
    private var pageCount = 0
    private var nativeBytes = 0
    private var outputBytes = 0

    init(limits: RelayExportLimits) throws {
        guard limits.endpoints > 0, limits.pages > 0,
              limits.nativeBytes > 0, limits.outputBytes > 0 else {
            throw RelayExportAdmissionError.invalidLimits
        }
        self.limits = limits
    }

    var snapshot: RelayExportAdmissionSnapshot {
        lock.lock(); defer { lock.unlock() }
        return .init(closed: closed, endpoints: endpointCount, pages: pageCount,
                     nativeBytes: nativeBytes, outputBytes: outputBytes)
    }

    /// Fences new admission only. Existing witnesses still have to settle;
    /// close never infers native retirement or cancels an outstanding promise.
    func closeAdmission() {
        lock.lock(); defer { lock.unlock() }
        closed = true
    }

    func reserveEndpoint() throws -> Endpoint {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw RelayExportAdmissionError.closed }
        guard endpointCount < limits.endpoints else { throw RelayExportAdmissionError.endpoints }
        endpointCount += 1
        return Endpoint(service: self)
    }

    /// A shared identity with no native state. Copies cannot return capacity
    /// twice. All mutable fields below belong to this service's one lock.
    final class Endpoint: @unchecked Sendable {
        fileprivate let service: RelayExportAdmission
        fileprivate var stopped = false
        fileprivate var nativeReleased = false
        fileprivate var outstandingPage = false
        fileprivate var returned = false
        fileprivate init(service: RelayExportAdmission) { self.service = service }

        /// The first caller owns submission of the endpoint's one retirement
        /// operation. A stopped endpoint stays charged while that IO is delayed.
        @discardableResult func beginRetirement() -> Bool { service.stop(self) }

        /// Call only after actual IO-owned endpoint/context retirement, or
        /// cleanup of a failed construction that published no native endpoint.
        /// Outstanding pages retain endpoint capacity independently.
        @discardableResult func confirmNativeRelease() -> Bool { service.releaseNative(self) }

        /// One conservative charge covers preparation and its one output copy.
        /// This reserves accounting; it does not authorize a subsequent send.
        func reservePage(nativeBytes: Int, outputBytes: Int) throws -> Page {
            try service.reservePage(self, nativeBytes: nativeBytes, outputBytes: outputBytes)
        }
    }

    final class Page: @unchecked Sendable {
        fileprivate let endpoint: Endpoint
        fileprivate let nativeCharge: Int
        fileprivate let outputCharge: Int
        fileprivate var nativeReleased = false
        fileprivate var transportSettled = false
        fileprivate var returned = false
        fileprivate init(endpoint: Endpoint, nativeBytes: Int, outputBytes: Int) {
            self.endpoint = endpoint; nativeCharge = nativeBytes; outputCharge = outputBytes
        }

        /// After frame/shim storage and every admitted native turn are gone.
        /// Inline promise completion cannot stand in for this IO witness.
        @discardableResult func confirmNativeRelease() -> Bool {
            endpoint.service.releasePageNative(self)
        }

        /// After the exact promise/cancellation settles, or definite refusal
        /// before enqueue. A throw after possible enqueue is not this witness.
        @discardableResult func confirmTransportSettlement() -> Bool {
            endpoint.service.settleTransport(self)
        }
    }

    private func stop(_ endpoint: Endpoint) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !endpoint.stopped else { return false }
        endpoint.stopped = true
        return true
    }

    private func releaseNative(_ endpoint: Endpoint) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard endpoint.stopped, !endpoint.nativeReleased else { return false }
        endpoint.nativeReleased = true
        returnEndpointIfSettled(endpoint)
        return true
    }

    private func reservePage(_ endpoint: Endpoint, nativeBytes requestedNative: Int,
                             outputBytes requestedOutput: Int) throws -> Page {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw RelayExportAdmissionError.closed }
        guard !endpoint.stopped else { throw RelayExportAdmissionError.endpointStopped }
        guard !endpoint.outstandingPage else { throw RelayExportAdmissionError.pageBusy }
        guard requestedNative > 0, requestedOutput > 0 else { throw RelayExportAdmissionError.invalidCharge }
        guard pageCount < limits.pages else { throw RelayExportAdmissionError.pages }
        // Compare against remaining capacity before addition: Int.max-sized
        // supplied bounds cannot overflow counters or turn refusal into credit.
        guard requestedNative <= limits.nativeBytes - nativeBytes else {
            throw RelayExportAdmissionError.nativeBytes
        }
        guard requestedOutput <= limits.outputBytes - outputBytes else {
            throw RelayExportAdmissionError.outputBytes
        }
        pageCount += 1; nativeBytes += requestedNative; outputBytes += requestedOutput
        endpoint.outstandingPage = true
        return Page(endpoint: endpoint, nativeBytes: requestedNative, outputBytes: requestedOutput)
    }

    private func releasePageNative(_ page: Page) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !page.nativeReleased else { return false }
        page.nativeReleased = true
        nativeBytes -= page.nativeCharge
        returnPageIfSettled(page)
        return true
    }

    private func settleTransport(_ page: Page) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !page.transportSettled else { return false }
        page.transportSettled = true
        outputBytes -= page.outputCharge
        returnPageIfSettled(page)
        return true
    }

    // Caller holds lock. No callbacks, payload release or further admission.
    private func returnPageIfSettled(_ page: Page) {
        guard !page.returned, page.nativeReleased, page.transportSettled else { return }
        page.returned = true; pageCount -= 1
        page.endpoint.outstandingPage = false
        returnEndpointIfSettled(page.endpoint)
    }

    private func returnEndpointIfSettled(_ endpoint: Endpoint) {
        guard !endpoint.returned, endpoint.stopped, endpoint.nativeReleased,
              !endpoint.outstandingPage else { return }
        endpoint.returned = true; endpointCount -= 1
    }
}
