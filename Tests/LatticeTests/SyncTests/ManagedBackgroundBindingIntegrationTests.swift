import Foundation
import Testing
import NIOConcurrencyHelpers
import LatticeTestSupport
@testable import Lattice

private enum ManagedBindingIntegrationFailure: Error {
    case observerTimedOut(Int64)
}

/// A positive receipt from the shipping native table observer. Waiting yields
/// the borrower actor so its normal scheduler can deliver the notification.
private final class ManagedBindingChangeReceipt: Sendable {
    private let insertedRows = NIOLockedValueBox<Set<Int64>>([])

    func record(_ changes: [TableChangeEvent]) {
        insertedRows.withLockedValue { rows in
            for change in changes where change.operation == "INSERT" { rows.insert(change.rowId) }
        }
    }

    func wait(for rowID: Int64) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !insertedRows.withLockedValue({ $0.contains(rowID) }) {
            guard ContinuousClock.now < deadline else {
                throw ManagedBindingIntegrationFailure.observerTimedOut(rowID)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct ManagedBindingMemberSnapshot: Sendable {
    let identity: Int64
    let sharesGroup: Bool
    let isManagedLocalBorrower: Bool
    let nativeRows: Int64
    let outstandingKeepers: Int
}

/// Only Sendable references, IDs and receipts cross this actor's boundary.
/// The borrowed facade and its observer registration remain on their actor.
private actor ManagedBindingBorrower {
    private var store: Lattice?
    private var observer: UInt64?

    func open(_ reference: LatticeThreadSafeReference,
              group: BackgroundSyncBindingGroup) throws -> ManagedBindingMemberSnapshot {
        let candidate = reference.resolve(isolation: self)
        let resolved = try #require(candidate)
        store = resolved
        return snapshot(group: group)
    }

    func snapshot(group: BackgroundSyncBindingGroup) -> ManagedBindingMemberSnapshot {
        guard let store else {
            return .init(identity: 0, sharesGroup: false, isManagedLocalBorrower: false,
                         nativeRows: 0, outstandingKeepers: 0)
        }
        let config = store.configuration
        return .init(identity: store.backend.identityHash,
                     sharesGroup: config.backgroundSyncLineage?.current === group,
                     isManagedLocalBorrower: config.backgroundSyncManaged && config.backgroundSync == nil &&
                        config.wssEndpoint == nil && config.authorizationToken == nil &&
                        config.ipcTargets?.isEmpty != false && config.syncStartup == .deferred,
                     nativeRows: store.backend.count(table: SimpleSyncObject.entityName),
                     outstandingKeepers: store.backend.localReadGenerationsOutstanding())
    }

    /// Keep the native generation alive until the group retires it. This tests
    /// real SQLite keeper admission, independently of a Results cache hit.
    func acquireKeeper() throws -> UInt64 {
        try #require(store).backend.acquireReadGeneration()
    }

    func observe(_ receipt: ManagedBindingChangeReceipt) throws {
        let store = try #require(store)
        observer = store.backend.addTableObserver(table: SimpleSyncObject.entityName) {
            receipt.record($0)
        }
    }

    func values() throws -> Set<Int> {
        Set(try #require(store).objects(SimpleSyncObject.self).map(\.value))
    }

    func add(value: Int) throws {
        try #require(store).add(SimpleSyncObject(value: value, floatValue: Float(value)))
    }

    func resolves(_ reference: LatticeThreadSafeReference) -> Bool {
        reference.resolve(isolation: self) != nil
    }

    func close() {
        guard let store else { return }
        if let observer {
            store.backend.removeTableObserver(table: SimpleSyncObject.entityName, observerId: observer)
            self.observer = nil
        }
        store.close()
        // Retain the facade deliberately: later checks distinguish native
        // close from merely releasing the test's last Swift reference.
    }
}

@Suite("Managed background lineage with native stores", .serialized)
actor ManagedBackgroundBindingIntegrationTests {
    private func directory() throws -> URL {
        let url = LatticeTestScratch.directory.appendingPathComponent("managed-lineage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func configuration(in directory: URL) -> Lattice.Configuration {
        var config = Lattice.Configuration(fileURL: directory.appendingPathComponent("store.sqlite"))
        // Exercise native lifecycle/group integration on macOS without
        // registering an Apple task or introducing a relay dependency.
        config.backgroundSyncManaged = true
        return config
    }

    @Test(.timeLimit(.minutes(1)))
    func crossActorBorrowerObservesAndSettlesWithOwnerThenCannotReopenClosedLineage() async throws {
        let directory = try directory()
        let owner = try Lattice(isolation: self, SimpleSyncObject.self,
                                configuration: configuration(in: directory))
        let borrower = ManagedBindingBorrower()
        do {
            let group = try #require(owner.configuration.backgroundSyncLineage?.current)
            let reference = owner.sendableReference
            let initial = try await borrower.open(reference, group: group)
            #expect(initial.identity != owner.backend.identityHash)
            #expect(initial.sharesGroup)
            #expect(initial.isManagedLocalBorrower)
            #expect(owner.backend.acquireReadGeneration() == 0)
            #expect(try await borrower.acquireKeeper() == 0)

            #expect(try await group.perform(.resume) == .completed)
            #expect(owner.backend.acquireReadGeneration() != 0)
            #expect(try await borrower.acquireKeeper() != 0)
            let changes = ManagedBindingChangeReceipt()
            try await borrower.observe(changes)
            let row = SimpleSyncObject(value: 11, floatValue: 11)
            try owner.add(row)
            try await changes.wait(for: #require(row.primaryKey))
            #expect(try await borrower.values() == [11])

            #expect(try await group.perform(.suspend) == .completed)
            #expect(owner.backend.localReadGenerationsOutstanding() == 0)
            #expect(owner.backend.acquireReadGeneration() == 0)
            let suspended = await borrower.snapshot(group: group)
            #expect(suspended.outstandingKeepers == 0)
            #expect(suspended.nativeRows == 1)
            #expect(try await borrower.acquireKeeper() == 0)

            #expect(try await group.perform(.resume) == .completed)
            #expect(owner.backend.acquireReadGeneration() != 0)
            #expect(try await borrower.acquireKeeper() != 0)
            #expect(try await borrower.values() == [11])

            owner.close()
            #expect(group.isInvalidated)
            // The file still exists with its row: failure to resolve is the
            // retired lineage fence, not the missing-file guard.
            #expect(FileManager.default.fileExists(atPath: owner.configuration.fileURL.path))
            #expect(!(await borrower.resolves(reference)))
            let closed = await borrower.snapshot(group: group)
            #expect(closed.nativeRows == 0)
            #expect(closed.outstandingKeepers == 0)
            #expect(try await borrower.acquireKeeper() == 0)
            #expect(try await group.perform(.resume) == .unavailable)
        } catch {
            await borrower.close()
            owner.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        await borrower.close()
        owner.close()
        try FileManager.default.removeItem(at: directory)
    }

    @Test(.timeLimit(.minutes(1)))
    func closingDerivedNativeIdentityLeavesOwnerAndOtherActorUsable() async throws {
        let directory = try directory()
        let owner = try Lattice(isolation: self, SimpleSyncObject.self,
                                configuration: configuration(in: directory))
        let first = ManagedBindingBorrower(), second = ManagedBindingBorrower()
        do {
            let group = try #require(owner.configuration.backgroundSyncLineage?.current)
            let reference = owner.sendableReference
            let firstID = try await first.open(reference, group: group).identity
            let secondInitial = try await second.open(reference, group: group)
            #expect(Set([owner.backend.identityHash, firstID, secondInitial.identity]).count == 3)
            #expect(secondInitial.sharesGroup && secondInitial.isManagedLocalBorrower)
            #expect(try await group.perform(.resume) == .completed)
            #expect(try await first.acquireKeeper() != 0)
            #expect(try await second.acquireKeeper() != 0)

            await first.close()
            #expect(!group.isInvalidated)
            #expect(try await first.acquireKeeper() == 0)
            let changes = ManagedBindingChangeReceipt()
            try await second.observe(changes)
            let row = SimpleSyncObject(value: 21, floatValue: 21)
            try owner.add(row)
            try await changes.wait(for: #require(row.primaryKey))
            #expect(try await second.values() == [21])
            try await second.add(value: 22)
            #expect(Set(owner.objects(SimpleSyncObject.self).map(\.value)) == [21, 22])

            #expect(try await group.perform(.suspend) == .completed)
            #expect(owner.backend.acquireReadGeneration() == 0)
            #expect(try await second.acquireKeeper() == 0)
            #expect(try await group.perform(.resume) == .completed)
            #expect(owner.backend.acquireReadGeneration() != 0)
            #expect(try await second.acquireKeeper() != 0)
            #expect(try await first.acquireKeeper() == 0)
            #expect(try await second.values() == [21, 22])
            #expect(owner.backend.count(table: SimpleSyncObject.entityName) == 2)
        } catch {
            await first.close()
            await second.close()
            owner.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        await first.close()
        await second.close()
        owner.close()
        try FileManager.default.removeItem(at: directory)
    }
}
