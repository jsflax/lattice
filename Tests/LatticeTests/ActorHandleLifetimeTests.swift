import Foundation
import Testing
import LatticeTestSupport
@testable import Lattice

@Model private final class ActorLifetimeItem {
    var value: String = "fixture"
}

private final class WeakLifetimeActor: @unchecked Sendable {
    weak var value: LifetimeActor?
    init(_ value: LifetimeActor) { self.value = value }
}

private final class WeakLifetimeBackend {
    weak var value: (any LatticeBackend)?
    init(_ value: any LatticeBackend) { self.value = value }
}

private final class LifetimeErrorCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private actor LifetimeActor {
    func configuration(_ url: URL) -> Lattice.Configuration { .init(fileURL: url) }

    func openAndClose(_ url: URL) throws {
        let db = try Lattice(ActorLifetimeItem.self, configuration: .init(fileURL: url))
        try db.add(ActorLifetimeItem())
        db.close()
    }

    func closeFirstAndInspectSibling(_ firstURL: URL, _ secondURL: URL) throws -> Bool {
        let first = try Lattice(ActorLifetimeItem.self, configuration: .init(fileURL: firstURL))
        let second = try Lattice(ActorLifetimeItem.self, configuration: .init(fileURL: secondURL))
        defer { second.close() }
        let firstRef = first.cxxLatticeRef, secondRef = second.cxxLatticeRef
        let secondIdentity = second.backend.identityHash
        first.close()
        guard Lattice(ref: firstRef) == nil, let cached = Lattice(ref: secondRef),
              cached.backend.identityHash == secondIdentity, cached.isolation === self else { return false }
        try second.add(ActorLifetimeItem())
        return cached.objects(ActorLifetimeItem.self).count == 1
    }

    func cachedHandleRetainsOriginalIsolation(_ url: URL) throws -> Bool {
        let first = try Lattice(ActorLifetimeItem.self, configuration: .init(fileURL: url))
        let copy = first
        let cached = try Lattice(ActorLifetimeItem.self, configuration: .init(fileURL: url))
        defer { first.close() }
        guard first.backend.identityHash == cached.backend.identityHash,
              let resurrected = Lattice(ref: copy.cxxLatticeRef) else { return false }
        return resurrected.isolation === self && cached.isolation === self
    }

    private func scopedSibling(_ url: URL, nativeIdentity: Int64) throws -> WeakLifetimeBackend? {
        let sibling = try Lattice(ActorLifetimeItem.self, configuration: .init(fileURL: url))
        guard sibling.backend.identityHash == nativeIdentity else { return nil }
        return WeakLifetimeBackend(sibling.backend)
    }

    func originalFacadeSurvivesNewestFacadeRelease(_ url: URL) throws -> Bool {
        let original = try Lattice(ActorLifetimeItem.self, configuration: .init(fileURL: url))
        defer { original.close() }
        guard let retired = try scopedSibling(url, nativeIdentity: original.backend.identityHash),
              retired.value == nil,
              let resurrected = Lattice(ref: original.cxxLatticeRef) else { return false }
        return resurrected.backend === original.backend && resurrected.isolation === self
    }

    func cachedFacadesKeepSeparateQueryErrorHandlers(_ url: URL) throws -> Bool {
        let original = try Lattice(ActorLifetimeItem.self, configuration: .init(fileURL: url))
        let sibling = try Lattice(ActorLifetimeItem.self, configuration: .init(fileURL: url))
        guard original.backend.identityHash == sibling.backend.identityHash,
              original.backend !== sibling.backend else { original.close(); return false }
        let originalErrors = LifetimeErrorCount(), siblingErrors = LifetimeErrorCount()
        original.onQueryError { _ in originalErrors.increment() }
        sibling.onQueryError { _ in siblingErrors.increment() }
        original.close()
        do { _ = try original.storedSchemaVersion(); return false } catch { }
        guard originalErrors.value == 1 && siblingErrors.value == 0 else { return false }
        do { _ = try sibling.storedSchemaVersion(); return false } catch { }
        return originalErrors.value == 1 && siblingErrors.value == 1
    }
}

@Suite("Actor handle lifetime", .serialized)
struct ActorHandleLifetimeTests {
    private func directory() throws -> URL {
        let url = LatticeTestScratch.directory.appendingPathComponent("actor-lifetime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func retainedPlainConfigurationDoesNotRetainItsCreatorActor() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        func makeConfiguration() async -> (Lattice.Configuration, WeakLifetimeActor) {
            let owner = LifetimeActor()
            let weakOwner = WeakLifetimeActor(owner)
            return (await owner.configuration(directory.appendingPathComponent("configuration.sqlite")), weakOwner)
        }
        let (configuration, retired) = await makeConfiguration()
        withExtendedLifetime(configuration) {
            #expect(retired.value == nil, "a plain configuration's scheduler must not inherit a creator actor")
        }
    }

    @Test func repeatedlyClosedHandlesDoNotRetainTheirReaderActors() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        func useActor(_ url: URL) async throws -> WeakLifetimeActor {
            let owner = LifetimeActor()
            let weakOwner = WeakLifetimeActor(owner)
            try await owner.openAndClose(url)
            return weakOwner
        }
        var retired: [WeakLifetimeActor] = []
        for index in 0..<20 {
            retired.append(try await useActor(directory.appendingPathComponent("reader-\(index).sqlite")))
        }
        #expect(retired.allSatisfy { $0.value == nil }, "closed handles must not pin transient reader actors")
    }

    @Test func closingOneHandleRetiresOnlyItsLookupAndLeavesSiblingIsolationIntact() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let owner = LifetimeActor()
        let result = try await owner.closeFirstAndInspectSibling(
            directory.appendingPathComponent("first.sqlite"), directory.appendingPathComponent("second.sqlite"))
        #expect(result)
    }

    @Test func valueCopiesAndNativeCacheReuseKeepPerActorIsolation() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let owner = LifetimeActor()
        #expect(try await owner.cachedHandleRetainsOriginalIsolation(directory.appendingPathComponent("shared.sqlite")))
    }

    @Test func newerFacadeCanExpireWhileOriginalTrampolineLookupRemainsValid() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let owner = LifetimeActor()
        #expect(try await owner.originalFacadeSurvivesNewestFacadeRelease(directory.appendingPathComponent("nested.sqlite")))
    }

    @Test func nativeCacheHitsKeepQueryErrorCollectorsPerFacade() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let owner = LifetimeActor()
        #expect(try await owner.cachedFacadesKeepSeparateQueryErrorHandlers(directory.appendingPathComponent("errors.sqlite")))
    }
}
