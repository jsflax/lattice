import Foundation
import Testing
@_spi(LatticeServer) import Lattice
@testable import LatticeServerKit

@Model private class CurrentMountedChild {
    var value: String
    init(_ value: String) { self.value = value }
}
@Model private class CurrentMountedParent {
    var value: String
    var child: CurrentMountedChild?
    init(_ value: String, child: CurrentMountedChild? = nil) { self.value = value; self.child = child }
}
@Model private class CurrentMountedOutside {
    var value: String
    init(_ value: String) { self.value = value }
}

private final class CurrentMountedSignal: Sendable {
    let stream: AsyncStream<Void>
    let continuation: AsyncStream<Void>.Continuation
    init() {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream; continuation = pair.continuation
    }
    func send() { continuation.yield(()); continuation.finish() }
    func wait() async throws {
        var iterator = stream.makeAsyncIterator()
        guard await iterator.next() != nil else { throw CancellationError() }
    }
}
private final class CurrentMountedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock(); defer { lock.unlock() }; return body(&value)
    }
}
private final class CurrentMountedLifetime: Sendable {
    let release: @Sendable () -> Void
    init(_ release: @escaping @Sendable () -> Void) { self.release = release }
    deinit { release() }
}

/// These are real executor/type/native storage seams. They do not manufacture
/// an authenticated gate or assert a positive server/TLS/checked-open witness.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RelayCurrentMountedCaptureTests {
    @Test func actualExecutingKeyDistinguishesSameWorkerAndDifferentPool() async throws {
        let pool = RelayExecutionPool(workerCount: 1, name: "relay.current.mount.key")
        let foreign = RelayExecutionPool(workerCount: 1, name: "relay.current.mount.foreign")
        let done = CurrentMountedSignal(), result = CurrentMountedBox(false)
        #expect(!pool.isExecuting(for: "actual"))
        pool.submitRequired(for: "actual") {
            result.withLock { $0 = pool.isCurrentWorker && pool.isExecuting(for: "actual") &&
                !pool.isExecuting(for: "other") && !foreign.isExecuting(for: "actual") }
            done.send()
        }
        try await done.wait(); await pool.shutdown(); await foreign.shutdown()
        #expect(result.withLock { $0 })
        #expect(!pool.isExecuting(for: "actual"))
    }
    @Test func finalCapturedTargetKeepsActualKeyAndCanEnqueueNextKey() async throws {
        let pool = RelayExecutionPool(workerCount: 1, name: "relay.current.mount.tail")
        let first = CurrentMountedBox(false), second = CurrentMountedBox(false), done = CurrentMountedSignal()
        func submitCapturedTarget() {
            let target = CurrentMountedLifetime {
                first.withLock { $0 = pool.isExecuting(for: "first") && !pool.isExecuting(for: "second") }
                pool.submitRequired(for: "second") {
                    second.withLock { $0 = pool.isExecuting(for: "second") && !pool.isExecuting(for: "first") }
                    done.send()
                }
            }
            pool.submitRequired(for: "first") { withExtendedLifetime(target) {} }
        }
        submitCapturedTarget(); try await done.wait(); await pool.shutdown()
        #expect(first.withLock { $0 } && second.withLock { $0 })
    }
    @Test func fullCatalogIncludesTheActualOptionalLinkedModel() throws {
        let full = try RelayOrdinaryModelMount.fullCatalog(for: [CurrentMountedParent.self])
        #expect(full.map { $0.entityName } == [CurrentMountedParent.entityName, CurrentMountedChild.entityName])
        let linked = try SyncOrdinaryModelProfile(identifier: "linked-v1", models: [CurrentMountedChild.self])
        _ = try RelayOrdinaryModelMount(schema: [CurrentMountedParent.self], profiles: [linked])
        let foreign = try SyncOrdinaryModelProfile(identifier: "foreign-v1", models: [CurrentMountedOutside.self])
        #expect(throws: (any Error).self) {
            _ = try RelayOrdinaryModelMount(schema: [CurrentMountedParent.self], profiles: [foreign])
        }
    }
    @Test func realNativeFullCatalogRefusesRootOnlyAndCapturesOnlyLinkedSelection() throws {
        let url = try path()
        let owner = try Lattice(isolation: nil, for: [CurrentMountedParent.self, CurrentMountedOutside.self], configuration: .init(fileURL: url))
        defer { close(owner) }
        let child = CurrentMountedChild("selected-linked-row")
        try owner.add(child)
        try owner.add(CurrentMountedParent("selected-parent-row", child: child))
        try owner.add(CurrentMountedOutside("excluded-outside-marker"))
        #expect(throws: (any Error).self) {
            _ = try owner.registerOrdinaryMountedHistorySource(models: [CurrentMountedParent.self])
        }
        let full = try RelayOrdinaryModelMount.fullCatalog(for: [CurrentMountedParent.self, CurrentMountedOutside.self])
        let mounted = try owner.registerOrdinaryMountedHistorySource(models: full)
        // Declared inbound and outbound relationships stay inside each cut.
        // This refusal must not consume the mounted source's only live cut.
        #expect(throws: (any Error).self) {
            _ = try mounted.capture(models: [CurrentMountedChild.self])
        }
        let cut = try mounted.capture(models: [CurrentMountedParent.self, CurrentMountedChild.self])
        let header = try body(cut)
        #expect(header["models"] as? [String] == [CurrentMountedChild.entityName, CurrentMountedParent.entityName])
        #expect(header["rows"] as? String == "2")
        #expect(cut.priorMountedSource == nil)
        for index in 0..<cut.frameCount {
            #expect(!String(decoding: try cut.page(at: index).data(), as: UTF8.self).contains("excluded-outside-marker"))
        }
        #expect(owner.count(CurrentMountedParent.self) == 1 && owner.count(CurrentMountedChild.self) == 1)
        #expect(owner.count(CurrentMountedOutside.self) == 1)
    }
    @Test func actualMountedCutMustReleaseBeforeSuccessorAndKeepsLineage() throws {
        let owner = try Lattice(isolation: nil, for: [CurrentMountedParent.self], configuration: .init(fileURL: try path()))
        defer { close(owner) }
        try owner.add(CurrentMountedChild("first"))
        let full = try RelayOrdinaryModelMount.fullCatalog(for: [CurrentMountedParent.self])
        let mounted = try owner.registerOrdinaryMountedHistorySource(models: full)
        var first: OwnedOrdinaryHistoryExport? = try mounted.capture(models: full)
        let source = try #require(first).sourceID, epoch = try #require(first).epoch, cut = try #require(first).cut
        #expect(throws: (any Error).self) { _ = try mounted.capture(models: full) }
        withExtendedLifetime(first) {}; first = nil
        try owner.add(CurrentMountedChild("second"))
        let next = try mounted.capture(models: full)
        #expect(next.sourceID == source && next.epoch == epoch && next.cut == cut + 1)
        #expect(try body(next)["rows"] as? String == "2")
    }
    @Test func genuineIssuedPageRetainsBytesAfterParentCheckedClose() throws {
        let owner = try Lattice(isolation: nil, for: [CurrentMountedParent.self], configuration: .init(fileURL: try path()))
        try owner.add(CurrentMountedChild("retained"))
        let full = try RelayOrdinaryModelMount.fullCatalog(for: [CurrentMountedParent.self])
        var mounted: OwnedOrdinaryMountedHistorySource? = try owner.registerOrdinaryMountedHistorySource(models: full)
        var cut: OwnedOrdinaryHistoryExport? = try #require(mounted).capture(models: full)
        let page = try #require(cut).page(at: 0), bytes = try page.data()
        let lastIndex = try #require(cut).frameCount - 1
        let lastPage = try #require(cut).page(at: lastIndex)
        let lastBytes = try lastPage.data()
        close(owner); mounted = nil; cut = nil
        #expect(try page.data() == bytes)
        #expect(try lastPage.data() == lastBytes)
    }
    private func path() throws -> URL {
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("localdev/lattice-current-mounted-capture-tests")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(UUID().uuidString).sqlite")
    }
    private func close(_ owner: Lattice) {
        let result = owner.closeChecked()
        #expect(!result.failed && !result.cleanupFailed && result.cleanupComplete)
    }
    private func body(_ cut: OwnedOrdinaryHistoryExport) throws -> [String: Any] {
        let root = try #require(try JSONSerialization.jsonObject(with: cut.page(at: 0).data()) as? [String: Any])
        return try #require(root["latticeOrdinarySync"] as? [String: Any])
    }
}
