import Foundation
import Testing
@testable import Lattice

@Model private final class AttachedIdentityItem {
    var rank: Int = 0
    var value: String = ""
}

private final class AttachedTopologyBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

@Suite("Attached Instance Identity Tests")
struct AttachedInstanceIdentityTests {
    @Test func pageReadsKeepOverlappingPrimaryKeysInTheirOwnStores() throws {
        try runScenario(useIterator: false)
    }

    @Test func iteratorReadsKeepOverlappingPrimaryKeysInTheirOwnStores() throws {
        try runScenario(useIterator: true)
    }

    @Test(arguments: [false, true])
    func existingFacadeSwitchesToOffsetWhenAttachedSortKeysAndPrimaryKeysTie(useIterator: Bool) throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = packageRoot.appendingPathComponent(".build/attached-identity-fixtures")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = Lattice.Configuration(fileURL: directory.appendingPathComponent("local.sqlite"))
        configuration.resultsTuning.pageSize = 3
        var local = try Lattice(AttachedIdentityItem.self, configuration: configuration)
        defer { local.close() }
        let attached = try Lattice(AttachedIdentityItem.self,
                                   configuration: .init(fileURL: directory.appendingPathComponent("other.sqlite")))
        defer { attached.close() }

        // Every pair ties on both components of the old (rank, id) anchor.
        // More than 100 rows also crosses the OFFSET iterator's batch size.
        for (store, prefix) in [(local, "local"), (attached, "attached")] {
            try store.withTransaction {
                for index in 0..<60 {
                    let row = AttachedIdentityItem()
                    row.rank = 0
                    row.value = "\(prefix)-\(index)"
                    try store.add(row)
                }
            }
        }
        let localRows = local.objects(AttachedIdentityItem.self).snapshot()
        let attachedRows = attached.objects(AttachedIdentityItem.self).snapshot()
        try #require(localRows.compactMap(\.primaryKey) == attachedRows.compactMap(\.primaryKey))
        var expectedIDs = Set((localRows + attachedRows).compactMap(\.globalId))
        try #require(expectedIDs.count == 120)

        // One preceding row puts an equal-(rank,id) pair across the OFFSET
        // iterator's 100-row boundary, as well as across the three-row pages.
        let preceding = AttachedIdentityItem()
        preceding.rank = -1
        preceding.value = "preceding"
        try local.add(preceding)
        expectedIDs.insert(try #require(preceding.globalId))

        // Prime the descriptor, generation and pages BEFORE attach. The
        // results facade holds a value copy of Lattice, so its old Swift
        // attachedSchemas list cannot be used to detect the new topology.
        let results = local.objects(AttachedIdentityItem.self).sortedBy(\.rank)
        let oldShape = results._shapeState
        #expect(results.count == 61)
        #expect(results.element(at: 0)?.value == "preceding")
        #expect(oldShape.anchorCount == 1)
        #expect(!local.backend._hasAttachedStores)

        try local.attach(lattice: attached)
        #expect(local.backend._hasAttachedStores)
        let attachedShape = results._shapeState
        #expect(attachedShape !== oldShape,
                "Attaching must replace the memoized non-attached query shape")
        #expect(results.count == 121)

        var delivered: [AttachedIdentityItem] = []
        if useIterator {
            var iterator = results.makeIterator()
            while delivered.count < 122, let row = iterator.next() { delivered.append(row) }
        } else {
            for index in 0..<121 {
                delivered.append(try #require(results.element(at: index)))
            }
        }
        let deliveredIDs = delivered.compactMap(\.globalId)
        #expect(delivered.count == 121)
        #expect(Set(deliveredIDs).count == 121,
                "Equal store-local keys must not replace or repeat another physical row")
        #expect(Set(deliveredIDs) == expectedIDs,
                "A keyset resume would skip the other store's equal-(rank,id) row")
        #expect(delivered.first?.value == "preceding")
        #expect(attachedShape.anchorCount == 0)
        #expect(attachedShape.fillCounts.keyset == 0)
        if !useIterator {
            #expect(attachedShape.fillCounts.offset > 0)
        }
        withExtendedLifetime(localRows) {}
        withExtendedLifetime(attachedRows) {}
    }

    #if canImport(CoreFoundation) && canImport(os)
    @MainActor @Test func backgroundAttachBypassesHeldMainPinButPreservesAnExistingIterator() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = packageRoot.appendingPathComponent(".build/attached-identity-fixtures")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = Lattice.Configuration(fileURL: directory.appendingPathComponent("local.sqlite"))
        configuration.resultsTuning.pageSize = 1
        configuration.resultsTuning.crossProcessBeltIntervalMs = nil
        let local = try Lattice(isolation: nil, AttachedIdentityItem.self, configuration: configuration)
        defer { local.close() }
        let attached = try Lattice(isolation: nil, AttachedIdentityItem.self,
                                   configuration: .init(fileURL: directory.appendingPathComponent("other.sqlite")))
        defer { attached.close() }
        for (store, ranks) in [(local, [10, 30]), (attached, [20, 40])] {
            for rank in ranks {
                let row = AttachedIdentityItem()
                row.rank = rank
                try store.add(row)
            }
        }

        let results = local.objects(AttachedIdentityItem.self).sortedBy(\.rank)
        let coordinator = GenerationCoordinatorRegistry.coordinator(
            for: local.backend, tuning: configuration.resultsTuning)
        #expect(results.count == 2)
        #expect(results.element(at: 0)?.rank == 10)
        let originalPin = coordinator.resolve(table: AttachedIdentityItem.entityName)
        try #require(originalPin.generationID != 0)
        var existingIterator = results.makeIterator()
        #expect(existingIterator.next()?.rank == 10)

        let handles = AttachedTopologyBox((local, attached))
        let failure = LockedBox<String?>(nil)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            defer { done.signal() }
            do {
                var parent = handles.value.0
                try parent.attach(lattice: handles.value.1)
            } catch {
                failure.withLock { $0 = String(describing: error) }
            }
        }
        // No await or runloop pump: the pre-attach main-thread render pin
        // stays alive. A normal same-thread attach would clear it and miss
        // the defect in generation-routed attached reads.
        try #require(done.wait(timeout: .now() + 5) == .success)
        try #require(failure.withLock { $0 } == nil)
        let retainedPin = coordinator.resolve(table: AttachedIdentityItem.entityName)
        try #require(retainedPin.generationID == originalPin.generationID,
                     "The regression must keep the pre-attach render pin alive")

        // Newly resolved attached shapes read the UNION view even while
        // the coordinator still advertises the old main-only keeper.
        #expect(results.count == 4)
        #expect(results.snapshot().map(\.rank) == [10, 20, 30, 40])
        #expect((0..<4).compactMap { results.element(at: $0)?.rank } == [10, 20, 30, 40])
        var newIterator = results.makeIterator()
        var newlyWalked: [Int] = []
        while newlyWalked.count < 5, let row = newIterator.next() { newlyWalked.append(row.rank) }
        #expect(newlyWalked == [10, 20, 30, 40])

        // An iterator created before attach keeps its original snapshot;
        // forcing it live would combine a UNION with its old keyset state.
        #expect(existingIterator.next()?.rank == 30)
        #expect(existingIterator.next() == nil)
    }
    #endif

    private func runScenario(useIterator: Bool) throws {
        // Keep fixtures in this checkout's ignored build directory, including
        // when the host has not redirected its system temporary directory.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = packageRoot.appendingPathComponent(".build/attached-identity-fixtures")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let localURL = directory.appendingPathComponent("local.sqlite")
        let attachedURL = directory.appendingPathComponent("attached.sqlite")

        try readAndWrite(localURL: localURL, attachedURL: attachedURL, useIterator: useIterator)

        // All writer/query handles closed before these opens: prove the writes
        // reached the correct files, rather than merely changing cached values.
        let local = try Lattice(AttachedIdentityItem.self, configuration: .init(fileURL: localURL))
        defer { local.close() }
        let attached = try Lattice(AttachedIdentityItem.self, configuration: .init(fileURL: attachedURL))
        defer { attached.close() }
        let localValues = local.objects(AttachedIdentityItem.self)
            .sortedBy(\.rank, order: .forward).snapshot().map(\.value)
        let attachedValues = attached.objects(AttachedIdentityItem.self)
            .sortedBy(\.rank, order: .forward).snapshot().map(\.value)
        #expect(localValues == ["changed-10", "changed-30"])
        #expect(attachedValues == ["changed-20", "changed-40"])
    }

    private func readAndWrite(localURL: URL, attachedURL: URL, useIterator: Bool) throws {
        var localConfig = Lattice.Configuration(fileURL: localURL)
        localConfig.resultsTuning.pageSize = 2
        localConfig.resultsTuning.maxCachedPages = 1
        let local = try Lattice(AttachedIdentityItem.self, configuration: localConfig)
        defer { local.close() }
        let attached = try Lattice(AttachedIdentityItem.self, configuration: .init(fileURL: attachedURL))
        defer { attached.close() }

        for rank in [10, 30] {
            let item = AttachedIdentityItem()
            item.rank = rank
            item.value = "local-\(rank)"
            try local.add(item)
        }
        for rank in [20, 40] {
            let item = AttachedIdentityItem()
            item.rank = rank
            item.value = "attached-\(rank)"
            try attached.add(item)
        }
        let localIDs = local.objects(AttachedIdentityItem.self).snapshot().compactMap(\.primaryKey)
        let attachedIDs = attached.objects(AttachedIdentityItem.self).snapshot().compactMap(\.primaryKey)
        try #require(localIDs == attachedIDs, "The fixture must overlap both stores' local primary keys")

        let query = try local.attaching(lattice: attached)
        defer { query.close() }
        // Unique ranks isolate registry reuse from the separate keyset issue
        // where equal sort values and equal local primary keys need a source
        // tiebreaker (or an attached-query paging fallback).
        let results = query.objects(AttachedIdentityItem.self).sortedBy(\.rank, order: .forward)

        // snapshot() constructs independent models, so this warms both physical
        // routes in the same registry bucket before exercising reuse.
        let held = results.snapshot()
        try #require(held.count == 4)
        let expectedGlobalIDs = held.compactMap(\.globalId)
        try #require(Set(expectedGlobalIDs).count == 4)
        for row in held {
            let primaryKey = try #require(row.primaryKey)
            let found = ModelInstanceRegistry.shared.lookup(
                databasePath: query.backend.path,
                tableName: AttachedIdentityItem.entityName,
                primaryKey: primaryKey,
                backendIdentity: query.backend.identityHash,
                physicalRoute: row._dynamicObject._ref.tableName)
            #expect(found.map(ObjectIdentifier.init) == ObjectIdentifier(row),
                    "A lookup must distinguish attached stores even on one owning backend")
        }

        func readRows() -> [AttachedIdentityItem] {
            if useIterator {
                // Bound the test even if a broken reuse/anchor combination
                // repeats a page indefinitely. The fifth row is a failure.
                var iterator = results.makeIterator()
                var rows: [AttachedIdentityItem] = []
                while rows.count < 5, let row = iterator.next() { rows.append(row) }
                return rows
            }
            return results.indices.compactMap { results.element(at: $0) }
        }

        let first = readRows()
        #expect(first.map(\.rank) == [10, 20, 30, 40])
        #expect(first.compactMap(\.globalId) == expectedGlobalIDs)
        #expect(Set(first.map(ObjectIdentifier.init)).count == 4)

        results.refresh()
        let refilled = readRows()
        #expect(refilled.map(\.rank) == [10, 20, 30, 40])
        #expect(refilled.compactMap(\.globalId) == expectedGlobalIDs)
        try #require(Set(refilled.map(ObjectIdentifier.init)).count == 4)

        try query.withTransaction {
            for row in refilled { row.value = "changed-\(row.rank)" }
        }
        withExtendedLifetime(held) {}
        withExtendedLifetime(first) {}
    }
}
