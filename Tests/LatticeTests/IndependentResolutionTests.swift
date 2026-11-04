import Foundation
import Testing
@testable import Lattice

@Model private final class IndependentResolutionItem {
    var name: String
    init(name: String = "") { self.name = name }
}

private enum IndependentMigrationV1 {
    @Model final class Item { var value: String }
}
private enum IndependentMigrationV2 {
    @Model final class Item { var value: Int }
}

private final class IndependentWeakBackend {
    weak var value: (any LatticeBackend)?
    init(_ value: any LatticeBackend) { self.value = value }
}

@Suite("Independent reference resolution", .serialized)
class IndependentResolutionTests: BaseTest {
    @Test @MainActor func publicIndependentReadersPreserveIsolationAndDoNotCloseCachedOwner() throws {
        let writer = try testLattice(IndependentResolutionItem.self)
        defer { writer.close() }
        try writer.add(IndependentResolutionItem(name: "original"))
        var config = writer.configuration
        config.isReadOnly = true
        config.uploadsEnabled = false
        config.busyTimeoutMs = 137
        config.resultsTuning.generationTTLSeconds = 7
        let cached = try Lattice(for: [IndependentResolutionItem.self], configuration: config)
        let first = try Lattice(independentFor: [IndependentResolutionItem.self], configuration: config)
        let second = try Lattice(independentFor: [IndependentResolutionItem.self], configuration: config)
        defer { first.close(); second.close(); cached.close() }
        #expect(first.backend.identityHash != cached.backend.identityHash)
        #expect(second.backend.identityHash != cached.backend.identityHash)
        #expect(first.backend.identityHash != second.backend.identityHash)
        #expect(first.isolation === MainActor.shared)
        #expect(second.isolation === MainActor.shared)
        #expect(first.configuration == config)
        #expect(first.configuration.isReadOnly && !first.configuration.uploadsEnabled)
        #expect(first.configuration.busyTimeoutMs == 137)
        #expect(first.configuration.resultsTuning.generationTTLSeconds == 7)
        #expect(first.objects(IndependentResolutionItem.self).first?.name == "original")
        let nativeRef = try #require(second.backend.asCxxLatticeRef)
        #expect(Lattice(ref: nativeRef)?.backend.identityHash == second.backend.identityHash)
        first.close()
        #expect(throws: (any Error).self) { _ = try first.storedSchemaVersion() }
        try writer.add(IndependentResolutionItem(name: "still writable"))
        try Lattice.withCurrentReadScope {
            let cachedSchemaVersion = try cached.storedSchemaVersion()
            #expect(cachedSchemaVersion > 0)
            let secondSchemaVersion = try second.storedSchemaVersion()
            #expect(secondSchemaVersion > 0)
            #expect(cached.objects(IndependentResolutionItem.self).count == 2)
            #expect(second.objects(IndependentResolutionItem.self).count == 2)
        }
        #expect(throws: (any Error).self) { try second.add(IndependentResolutionItem(name: "must fail")) }
        let stillCached = try Lattice(for: [IndependentResolutionItem.self], configuration: config)
        #expect(stillCached.backend.identityHash == cached.backend.identityHash)
        #expect(writer.objects(IndependentResolutionItem.self).count == 2)
    }

    @Test func publicIndependentReadOnlyOpenThrowsWithoutCreatingMissingStore() throws {
        let original = try testLattice(IndependentResolutionItem.self)
        var config = original.configuration
        original.close()
        try Lattice.delete(for: config)
        config.isReadOnly = true
        config.uploadsEnabled = false
        #expect(throws: (any Error).self) {
            _ = try Lattice(independentFor: [IndependentResolutionItem.self], configuration: config)
        }
        #expect(!FileManager.default.fileExists(atPath: config.fileURL.path))
        try FileManager.default.createDirectory(at: config.fileURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: config.fileURL) }
        #expect(throws: (any Error).self) {
            _ = try Lattice(independentFor: [IndependentResolutionItem.self], configuration: config)
        }
        #expect(try config.fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
    }

    @Test func publicIndependentOpenRunsConfiguredMigration() throws {
        typealias V1 = IndependentMigrationV1.Item
        typealias V2 = IndependentMigrationV2.Item
        let original = try testLattice(V1.self)
        let row = V1(); row.value = "42"
        try original.add(row)
        var config = original.configuration
        original.close()
        config.migration = [2: Migration((from: V1.self, to: V2.self), blocks: { old, new in
            new.value = Int(old.value) ?? -1
        })]
        let migrated = try Lattice(independentFor: [V2.self], configuration: config)
        defer { migrated.close() }
        #expect(migrated.objects(V2.self).first?.value == 42)
        #expect(migrated.configuration.migration?.keys.max() == 2)
    }

    @Test func distinctConnectionsKeepCachedResolutionAndStoreIdentity() throws {
        let original = try testLattice(IndependentResolutionItem.self)
        defer { original.close() }
        let reference = original.sendableReference
        let cachedValue = reference.resolve(isolation: nil)
        let cached = try #require(cachedValue)
        let first = try #require(try reference.resolveIndependent())
        let second = try #require(try reference.resolveIndependent())
        defer { first.close(); second.close() }
        #expect(cached.backend.identityHash == original.backend.identityHash)
        #expect(first.backend.identityHash != original.backend.identityHash)
        #expect(second.backend.identityHash != original.backend.identityHash)
        #expect(first.backend.identityHash != second.backend.identityHash)
        #expect(first.isolation == nil && second.isolation == nil)
        try first.add(IndependentResolutionItem(name: "independent writer"))
        #expect(second.objects(IndependentResolutionItem.self).first?.name == "independent writer")
        #expect(original.objects(IndependentResolutionItem.self).count == 1)
        let stillCachedValue = reference.resolve(isolation: nil)
        let stillCached = try #require(stillCachedValue)
        #expect(stillCached.backend.identityHash == original.backend.identityHash)
        // The pointer registry still resolves managed-object/trampoline identity.
        let nativeRef = try #require(first.backend.asCxxLatticeRef)
        #expect(Lattice(isolation: nil, ref: nativeRef)?.backend.identityHash == first.backend.identityHash)
    }

    @Test func namedMemoryPreservesStorageIdentity() throws {
        let original = try Lattice(IndependentResolutionItem.self,
            configuration: .init(storage: .memory(named: "independent-\(UUID().uuidString)")))
        let independent = try #require(try original.sendableReference.resolveIndependent())
        defer { original.close(); independent.close() }
        #expect(original.backend.identityHash != independent.backend.identityHash)
        try original.add(IndependentResolutionItem(name: "shared memory"))
        #expect(independent.objects(IndependentResolutionItem.self).first?.name == "shared memory")
    }

    @Test func completeConfigurationAndReadOnlyModeSurviveResolution() throws {
        let writer = try testLattice(IndependentResolutionItem.self)
        try writer.add(IndependentResolutionItem(name: "original"))
        var config = writer.configuration
        config.isReadOnly = true
        config.busyTimeoutMs = 137
        config.auditRetention = 1234
        config.resultsTuning.generationTTLSeconds = 7
        config.resultsTuning.walKeeperEvictionThresholdBytes = 987654
        let reference = LatticeThreadSafeReference(modelTypes: [IndependentResolutionItem.self], configuration: config)
        let reader = try #require(try reference.resolveIndependent())
        defer { reader.close(); writer.close() }
        #expect(reader.configuration.isReadOnly)
        #expect(reader.configuration.busyTimeoutMs == 137)
        #expect(reader.configuration.auditRetention == 1234)
        #expect(reader.configuration.resultsTuning.generationTTLSeconds == 7)
        #expect(reader.configuration.resultsTuning.walKeeperEvictionThresholdBytes == 987654)
        #expect(reader.modelTypes.contains { $0 == IndependentResolutionItem.self })
        #expect(reader.objects(IndependentResolutionItem.self).first?.name == "original")
        #expect(throws: (any Error).self) { try reader.add(IndependentResolutionItem(name: "must fail")) }
        #expect(writer.objects(IndependentResolutionItem.self).count == 1)
    }

    @Test func independentOpenRunsOriginalRowMigration() throws {
        typealias V1 = IndependentMigrationV1.Item
        typealias V2 = IndependentMigrationV2.Item
        let original = try testLattice(V1.self)
        let row = V1(); row.value = "42"
        try original.add(row)
        var config = original.configuration
        original.close()
        config.migration = [2: Migration((from: V1.self, to: V2.self), blocks: { old, new in
            new.value = Int(old.value) ?? -1
        })]
        let reference = LatticeThreadSafeReference(modelTypes: [V2.self], configuration: config)
        let migrated = try #require(try reference.resolveIndependent())
        defer { migrated.close() }
        #expect(migrated.objects(V2.self).first?.value == 42)
        #expect(migrated.configuration.migration?.keys.max() == 2)
    }

    @Test func missingFileIsNotRecreatedAndOpenFailureIsCatchable() throws {
        let original = try testLattice(IndependentResolutionItem.self)
        let reference = original.sendableReference
        let path = original.configuration.fileURL
        original.close()
        try Lattice.delete(for: original.configuration)
        #expect(try reference.resolveIndependent() == nil)
        #expect(!FileManager.default.fileExists(atPath: path.path))
        // Existence alone is insufficient: a directory cannot be an SQLite file.
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: path) }
        #expect(throws: (any Error).self) { _ = try reference.resolveIndependent() }
        #expect(try path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
    }

    @Test func independentBackendIsNotRetainedByRegistry() throws {
        let original = try testLattice(IndependentResolutionItem.self)
        defer { original.close() }
        func openAndRelease() throws -> IndependentWeakBackend {
            let independent = try #require(try original.sendableReference.resolveIndependent())
            return IndependentWeakBackend(independent.backend)
        }
        let probe = try openAndRelease()
        #expect(probe.value == nil, "An expired weak registry entry must not retain the independent backend")
    }
}
