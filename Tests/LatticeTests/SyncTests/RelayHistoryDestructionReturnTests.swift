import Foundation
import Testing
@_spi(LatticeServer) import Lattice

@Model private class DestructionReturnItem {
    var value: String
    init(_ value: String) { self.value = value }
}

/// Actual issued native cuts/pages and last Swift/native releases. No synthetic
/// principal, source receipt or destruction-complete flag is supplied.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RelayHistoryDestructionReturnTests {
    @Test func actualForeignLastCutReleaseAllowsSuccessorOnlyAfterReturn() throws {
        let owner = try seeded(); defer { close(owner) }
        let mounted = try owner.registerOrdinaryMountedHistorySource(models: [DestructionReturnItem.self])
        var cut: OwnedOrdinaryHistoryExport? = try mounted.capture(models: [DestructionReturnItem.self])
        let source = try #require(cut).sourceID, old = try #require(cut).cut
        let box = Transfer(cut); cut = nil
        let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), returned = DispatchSemaphore(value: 0)
        Thread.detachNewThread { var actual = box.take(); held.signal(); _ = release.wait(timeout: .now() + 5); withExtendedLifetime(actual) {}; actual = nil; returned.signal() }
        guard held.wait(timeout: .now() + 5) == .success else { release.signal(); throw Failure.deadline }
        #expect(throws: (any Error).self) { _ = try mounted.capture(models: [DestructionReturnItem.self]) }
        release.signal(); guard returned.wait(timeout: .now() + 5) == .success else { throw Failure.deadline }
        let next = try mounted.capture(models: [DestructionReturnItem.self])
        #expect(next.sourceID == source && next.cut == old + 1)
        withExtendedLifetime(next) {}
    }
    @Test func successiveDifferentPagesRequireActualForeignLastBufferRelease() throws {
        let owner = try seeded(); defer { close(owner) }
        let mounted = try owner.registerOrdinaryMountedHistorySource(models: [DestructionReturnItem.self])
        let cut = try mounted.capture(models: [DestructionReturnItem.self]); #expect(cut.frameCount >= 3)
        for index in 0..<2 {
            var page: OwnedOrdinaryHistoryPage? = try cut.page(at: index)
            let bytes = try #require(page).data(); #expect(!bytes.isEmpty)
            let box = Transfer(page); page = nil
            let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), returned = DispatchSemaphore(value: 0)
            Thread.detachNewThread { var actual = box.take(); held.signal(); _ = release.wait(timeout: .now() + 5); withExtendedLifetime(actual) {}; actual = nil; returned.signal() }
            guard held.wait(timeout: .now() + 5) == .success else { release.signal(); throw Failure.deadline }
            #expect(throws: (any Error).self) { _ = try cut.page(at: index + 1) }
            var alias: OwnedOrdinaryHistoryPage? = try cut.page(at: index); #expect(try #require(alias).data() == bytes)
            withExtendedLifetime(alias) {}; alias = nil
            // The real same-index alias has died before foreign final release.
            release.signal(); guard returned.wait(timeout: .now() + 5) == .success else { throw Failure.deadline }
            var next: OwnedOrdinaryHistoryPage? = try cut.page(at: index + 1); #expect(!(try #require(next).data()).isEmpty)
            withExtendedLifetime(next) {}; next = nil
        }
    }
    @Test func foreignLastPageRetainsCommonFourthSlotAfterCutMountAndParentClose() throws {
        let owner = try seeded(), competitor = try seeded(); defer { close(competitor) }
        var scalar: [OwnedOrdinarySyncExport] = []
        for _ in 0..<3 { scalar.append(try competitor.captureOrdinarySyncExport(models: [DestructionReturnItem.self])) }
        var mounted: OwnedOrdinaryMountedHistorySource? = try owner.registerOrdinaryMountedHistorySource(models: [DestructionReturnItem.self])
        var cut: OwnedOrdinaryHistoryExport? = try #require(mounted).capture(models: [DestructionReturnItem.self])
        var page: OwnedOrdinaryHistoryPage? = try #require(cut).page(at: 0)
        let box = Transfer(page); page = nil; cut = nil; mounted = nil; close(owner)
        let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), returned = DispatchSemaphore(value: 0)
        Thread.detachNewThread { var actual = box.take(); held.signal(); _ = release.wait(timeout: .now() + 5); withExtendedLifetime(actual) {}; actual = nil; returned.signal() }
        guard held.wait(timeout: .now() + 5) == .success else { release.signal(); throw Failure.deadline }
        do { _ = try competitor.captureOrdinarySyncExport(models: [DestructionReturnItem.self]); Issue.record("last actual page must retain shared fourth slot") }
        catch OrdinarySyncExportError.exportCapacity {} catch { Issue.record("expected actual common capacity: \(error)") }
        release.signal(); guard returned.wait(timeout: .now() + 5) == .success else { throw Failure.deadline }
        let next = try competitor.captureOrdinarySyncExport(models: [DestructionReturnItem.self]); #expect(next.frameCount > 0)
        withExtendedLifetime((scalar, next)) {}
    }
    private func seeded() throws -> Lattice {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("localdev/lattice-history-destruction-return-tests")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(UUID().uuidString).sqlite")
        let owner = try Lattice(isolation: nil, for: [DestructionReturnItem.self], configuration: .init(fileURL: url))
        for n in 0..<130 { try owner.add(DestructionReturnItem("row-\(n)")) }
        return owner
    }
    private func close(_ owner: Lattice) {
        let result = owner.closeChecked(); #expect(!result.failed && !result.cleanupFailed && result.cleanupComplete)
    }
    private final class Transfer<Value>: @unchecked Sendable {
        private let lock = NSLock(); private var value: Value?
        init(_ value: Value?) { self.value = value }
        func take() -> Value? { lock.lock(); defer { lock.unlock() }; let held = value; value = nil; return held }
    }
    private enum Failure: Error { case deadline }
}
