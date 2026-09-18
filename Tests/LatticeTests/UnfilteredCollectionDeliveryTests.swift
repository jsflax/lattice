import Foundation
import Testing
@testable import Lattice

@Model final class UnfilteredDeliveryItem {
    var value: Int = 0
}

@Suite("Unfiltered collection delivery", .serialized)
@available(iOS 16.4, macOS 13.3, tvOS 16.4, watchOS 9.4, *)
struct UnfilteredCollectionDeliveryTests {
    @Test(.timeLimit(.minutes(1)))
    func allOperationsPreserveBatchOrderWithoutResolutionOrSQL() async throws {
        let owner = try Lattice(isolation: nil, for: [UnfilteredDeliveryItem.self],
                                configuration: .init(storage: .memory()))
        defer { owner.close() }
        let removed = UnfilteredDeliveryItem()
        try owner.add(removed)
        let removedID = try #require(removed.primaryKey)
        let capture = UnfilteredDeliveryCapture()
        let token = owner._observeCollection(UnfilteredDeliveryItem.self,
                                             diagnostic: capture.diagnostic) {
            capture.delivered($0)
        }
        defer { token.cancel() }
        let inserted = UnfilteredDeliveryItem()
        try owner.transaction {
            try owner.add(inserted)
            inserted.value = 1
            owner.delete(removed)
        }
        let insertedID = try #require(inserted.primaryKey)
        let finished = await waitForUnfilteredDelivery { capture.snapshot().completed == 3 }
        try #require(finished)
        let snapshot = capture.snapshot()
        #expect(snapshot.deliveries == ["INSERT:\(insertedID)", "UPDATE:\(insertedID)", "DELETE:\(removedID)"])
        #expect(snapshot.started == 1)
        #expect(snapshot.skipped == 1)
        #expect(snapshot.resolved == 0)
        #expect(snapshot.sqlDeltas == [0], "decision phase must issue no native SQL")
    }

    @Test(.timeLimit(.minutes(1)))
    func missingFileAtDequeueDropsPayloadWithoutRecreatingStore() async throws {
        let config = makeUnfilteredDeliveryConfiguration()
        let owner = try Lattice(isolation: nil, for: [UnfilteredDeliveryItem.self], configuration: config)
        let row = UnfilteredDeliveryItem()
        try owner.add(row)
        let capture = UnfilteredDeliveryCapture()
        let token = owner._observeCollection(UnfilteredDeliveryItem.self,
                                             diagnostic: capture.diagnostic) {
            capture.delivered($0)
        }
        defer { capture.clearStartAction(); token.cancel(); owner.close(); try? Lattice.delete(for: config) }
        // The diagnostic runs after enqueue and before the file guard. Execute
        // setup there synchronously; never park the shared delivery worker.
        capture.installStartAction {
            // Normal deletion closes same-path backends before unlinking. Its
            // legacy missing-sidecar error is irrelevant; assert absence below.
            try? Lattice.delete(for: config)
        }
        row.value = 1
        let dropped = await waitForUnfilteredDelivery { capture.snapshot().missing == 1 }
        try #require(dropped)
        let snapshot = capture.snapshot()
        #expect(snapshot.startActions == 1)
        #expect(snapshot.deliveries.isEmpty)
        #expect(snapshot.resolved == 0)
        #expect(!FileManager.default.fileExists(atPath: config.fileURL.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func queuedPayloadStillDeliversAfterCloseAndCancellation() async throws {
        let config = makeUnfilteredDeliveryConfiguration()
        let owner = try Lattice(isolation: nil, for: [UnfilteredDeliveryItem.self], configuration: config)
        let row = UnfilteredDeliveryItem()
        try owner.add(row)
        let rowID = try #require(row.primaryKey)
        let capture = UnfilteredDeliveryCapture()
        let token = owner._observeCollection(UnfilteredDeliveryItem.self,
                                             diagnostic: capture.diagnostic) {
            capture.delivered($0)
        }
        defer { capture.clearStartAction(); token.cancel(); owner.close(); try? Lattice.delete(for: config) }
        capture.installStartAction {
            owner.close()
            token.cancel()
        }
        row.value = 1
        let finished = await waitForUnfilteredDelivery { capture.snapshot().completed == 1 }
        try #require(finished)
        let snapshot = capture.snapshot()
        #expect(snapshot.startActions == 1)
        #expect(snapshot.deliveries == ["UPDATE:\(rowID)"])
        #expect(snapshot.skipped == 1)
        #expect(snapshot.resolved == 0)
        #expect(snapshot.sqlDeltas == [0])
        #expect(FileManager.default.fileExists(atPath: config.fileURL.path))
        #expect(owner.object(UnfilteredDeliveryItem.self, primaryKey: rowID) == nil)
    }
}

private func makeUnfilteredDeliveryConfiguration() -> Lattice.Configuration {
    .init(fileURL: FileManager.default.temporaryDirectory
        .appending(path: "unfiltered-delivery-\(UUID().uuidString).sqlite"))
}

private func waitForUnfilteredDelivery(_ predicate: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(15)
    while !predicate(), ContinuousClock.now < deadline {
        do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
    }
    return predicate()
}

@available(iOS 16.4, macOS 13.3, tvOS 16.4, watchOS 9.4, *)
private final class UnfilteredDeliveryCapture: @unchecked Sendable {
    struct Snapshot {
        var deliveries: [String] = []
        var sqlDeltas: [UInt64] = []
        var started = 0
        var skipped = 0
        var resolved = 0
        var missing = 0
        var completed = 0
        var startActions = 0
    }
    private let lock = NSLock()
    private var startAction: (() -> Void)?
    private var state = Snapshot()
    private var statementStarts: [UUID: UInt64] = [:]
    // Installed before the triggering write, consumed once by the native
    // worker. The closure can capture the deliberately nil-isolated owner.
    // No closure or captured owner is released while holding this leaf lock.
    func installStartAction(_ action: @escaping () -> Void) {
        lock.withLock {
            precondition(startAction == nil)
            startAction = action
        }
    }
    private func takeStartAction() -> (() -> Void)? {
        lock.withLock {
            let action = startAction
            startAction = nil
            return action
        }
    }
    func clearStartAction() {
        let action = takeStartAction()
        withExtendedLifetime(action) {}
    }
    var diagnostic: PayloadObserverDiagnostic {
        .init(observer: "unfiltered-fast-path", capture: { [self] in record($0) })
    }
    private func record(_ event: PayloadObserverDiagnosticEvent) {
        if event.stage == "job_started", let action = takeStartAction() {
            action() // No capture lock, SQL lock, task or semaphore is held here.
            lock.withLock { state.startActions += 1 }
        }
        // Both samples run synchronously on the same serial native worker,
        // before user callbacks. Sample AFTER the test setup action so its
        // close/delete SQL does not pollute the decision budget.
        let statements = Lattice.threadSQLStatementCount
        lock.withLock {
            switch event.stage {
            case "job_started":
                state.started += 1
                if let batch = event.batch { statementStarts[batch] = statements }
            case "collection_resolution_skipped": state.skipped += 1
            case "collection_resolution_completed": state.resolved += 1
            case "collection_resolution_nil": state.missing += 1
            case "collection_decisions_completed":
                if let batch = event.batch, let start = statementStarts.removeValue(forKey: batch) {
                    state.sqlDeltas.append(statements - start)
                }
            case "collection_emission_returned": state.completed += event.count ?? 0
            default: break
            }
        }
    }
    func delivered(_ change: CollectionChange) {
        let value: String
        switch change {
        case .insert(let id): value = "INSERT:\(id)"
        case .update(let id): value = "UPDATE:\(id)"
        case .delete(let id): value = "DELETE:\(id)"
        }
        lock.withLock { state.deliveries.append(value) }
    }
    func snapshot() -> Snapshot { lock.withLock { state } }
}
