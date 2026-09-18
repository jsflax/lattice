import Foundation
import Testing
@testable import Lattice
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Model final class ObserverIsolationItem {
    var sequence: Int = 0
    init(sequence: Int = 0) { self.sequence = sequence }
}

@Suite("Collection observer isolation", .serialized)
struct ObserverIsolationTests {
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func mainActorCollectionDeliveryRetainsAttachingIsolation() async throws {
        try await checkCollectionObserverRouting(expectActorHop: true)
    }

    @Test(.timeLimit(.minutes(1)))
    func customActorCollectionDeliveryRetainsAttachingIsolation() async throws {
        try await ObserverIsolationOwner().checkDelivery()
    }

    @Test(.timeLimit(.minutes(1)))
    func nilIsolationCollectionDeliveryUsesDeepWorkerExactlyOnce() async throws {
        try await checkCollectionObserverRouting(isolation: nil, expectActorHop: false)
    }
}

private actor ObserverIsolationOwner {
    func checkDelivery() async throws {
        try await checkCollectionObserverRouting(expectActorHop: true)
    }
}

private func checkCollectionObserverRouting(
    isolation: isolated (any Actor)? = #isolation,
    expectActorHop: Bool
) async throws {
    let fileURL = FileManager.default.temporaryDirectory
        .appending(path: "observer-isolation-\(UUID().uuidString).sqlite")
    let configuration = Lattice.Configuration(fileURL: fileURL)
    let lattice = try Lattice(ObserverIsolationItem.self, configuration: configuration)
    defer { try? Lattice.delete(for: configuration) }

    let capture = ObserverRoutingCapture()
    let diagnostic = PayloadObserverDiagnostic(observer: "isolation", capture: { capture.record($0) })
    let token = lattice._observeCollection(ObserverIsolationItem.self, diagnostic: diagnostic) { change in
        guard case .insert(let rowID) = change else { return }
        // The callback does a real row read, then returns promptly. In the
        // nil-isolation case this SQL must retain the delivery worker's stack.
        let rowExists = lattice.object(ObserverIsolationItem.self, primaryKey: rowID) != nil
        capture.delivered(rowID: rowID, rowExists: rowExists,
                          thread: ObserverThreadIdentity(),
                          stackVerified: ObserverDeliveryWorker.shared.isStackVerified)
    }
    defer { token.cancel() }

    let writes = 25
    for sequence in 0..<writes {
        try lattice.add(ObserverIsolationItem(sequence: sequence))
    }

    // Await the emission-return marker as well as the callback, so the last
    // batch's route is present before checking it. No semaphore blocks an
    // actor or the process-wide delivery worker.
    let deadline = ContinuousClock.now + .seconds(15)
    while capture.completedDeliveryCount < writes && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    let snapshot = capture.snapshot()
    #expect(capture.completedDeliveryCount == writes, "every callback batch returned")
    let rowIDs = snapshot.deliveries.map(\.rowID)
    #expect(rowIDs.count == writes)
    #expect(Set(rowIDs).count == rowIDs.count, "no duplicate deliveries")
    #expect(rowIDs.sorted() == Array(1...Int64(writes)))
    #expect(snapshot.deliveries.allSatisfy { $0.rowExists }, "each delivered row remains readable")

    let actorBatches = Set(snapshot.events.filter { $0.stage == "collection_actor_hop" }.compactMap(\.batch))
    let emittedBatches = Set(snapshot.events.filter { $0.stage == "collection_emission_returned" }.compactMap(\.batch))
    #expect(!emittedBatches.isEmpty)
    let workerThread = try #require(snapshot.workerThread, "delivery worker never started a batch")
    if expectActorHop {
        // This checks the existing routing diagnostic and actual callback
        // thread, rather than crashing through assumeIsolated on regression.
        #expect(actorBatches == emittedBatches, "every emitted batch returns to the attaching actor")
        #expect(snapshot.deliveries.allSatisfy { !$0.thread.isSame(as: workerThread) })
    } else {
        #expect(actorBatches.isEmpty)
        #expect(snapshot.deliveries.allSatisfy { $0.thread.isSame(as: workerThread) })
        #expect(snapshot.deliveries.allSatisfy { $0.stackVerified })
    }
}

private struct ObserverThreadIdentity {
    private let raw = pthread_self()

    func isSame(as other: Self) -> Bool {
        pthread_equal(raw, other.raw) != 0
    }
}

private final class ObserverRoutingCapture: @unchecked Sendable {
    struct Delivery {
        let rowID: Int64
        let rowExists: Bool
        let thread: ObserverThreadIdentity
        let stackVerified: Bool
    }

    private let lock = NSLock()
    private var events: [PayloadObserverDiagnosticEvent] = []
    private var deliveries: [Delivery] = []
    private var completed = 0
    private var workerThread: ObserverThreadIdentity?

    func record(_ event: PayloadObserverDiagnosticEvent) {
        lock.lock(); defer { lock.unlock() }
        // All batches use the same serial worker. Capture its actual identity
        // before resolution and user delivery; thread names may be truncated.
        if event.stage == "job_started" { workerThread = ObserverThreadIdentity() }
        events.append(event)
        if event.stage == "collection_emission_returned" { completed += event.count ?? 0 }
    }

    func delivered(rowID: Int64, rowExists: Bool, thread: ObserverThreadIdentity, stackVerified: Bool) {
        lock.lock(); defer { lock.unlock() }
        deliveries.append(.init(rowID: rowID, rowExists: rowExists,
                                thread: thread, stackVerified: stackVerified))
    }

    var completedDeliveryCount: Int {
        lock.lock(); defer { lock.unlock() }
        return completed
    }

    func snapshot() -> (events: [PayloadObserverDiagnosticEvent], deliveries: [Delivery], workerThread: ObserverThreadIdentity?) {
        lock.lock(); defer { lock.unlock() }
        return (events, deliveries, workerThread)
    }
}
