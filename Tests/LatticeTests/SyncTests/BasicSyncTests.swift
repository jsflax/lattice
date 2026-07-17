import Foundation
#if canImport(Combine)
import Combine
#endif
#if canImport(MapKit)
import MapKit
#endif
import NIOConcurrencyHelpers
import NIOCore
import Testing
import Lattice
import Observation
import Vapor

@Suite("Sync Tests", .serialized)
actor SyncTests {
    let server: TestSyncServer
    let syncLatticeURL = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    let lattice1URL = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    let lattice2URL = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    var port: Int = 0
    var localLattice1: Lattice!
    var localLattice2: Lattice!
    var syncedLattice: Lattice!
    var syncedLatticeConfiguration: Lattice.Configuration
    var localLattice1Configuration: Lattice.Configuration
    var localLattice2Configuration: Lattice.Configuration
    
    deinit {
        server.shutdown()
        try? Lattice.delete(for: localLattice1Configuration)
        try? Lattice.delete(for: localLattice2Configuration)
        try? Lattice.delete(for: syncedLatticeConfiguration)
    }
    enum SyncTestError: Error {
        case noPort
    }

    init() async throws {
        lattice_set_log_level(lattice.log_level.warn)
        self.localLattice1Configuration = .init(fileURL: lattice1URL)
        self.localLattice2Configuration = .init(fileURL: lattice2URL)
        self.syncedLatticeConfiguration = .init(fileURL: syncLatticeURL)

        // D1b: shared TestSyncServer — one server-lifetime lattice, ordered
        // persistence (replaces the inline fresh-Lattice-per-frame handler).
        self.server = try await TestSyncServer(
            models: [SimpleSyncObject.self, SequenceSyncObject.self, SyncParent.self, SyncChild.self, SyncVectorObject.self, SyncGeoObject.self, SyncEmbeddedObject.self, TestDog.self, TestCat.self, TestPersonWithPets.self, TestPersonWithPet.self],
            configuration: syncedLatticeConfiguration,
            label: "SyncTests")
        syncedLattice = server.lattice
        self.port = server.port

        // Now create configs with the correct port
        localLattice1Configuration = Lattice.Configuration(
            fileURL: lattice1URL,
            authorizationToken: "hi",
            wssEndpoint: URL(string: "http://localhost:\(port)/test"))
        localLattice2Configuration = Lattice.Configuration(
            fileURL: lattice2URL,
            authorizationToken: "hi2",
            wssEndpoint: URL(string: "http://localhost:\(port)/test"))

        // Create Lattice instances AFTER server is running so sync connects to the right port
        localLattice1 = try Lattice(SimpleSyncObject.self, SequenceSyncObject.self, SyncParent.self, SyncChild.self, SyncVectorObject.self, SyncGeoObject.self, SyncEmbeddedObject.self, TestDog.self, TestCat.self, TestPersonWithPets.self, TestPersonWithPet.self,
                                    configuration: localLattice1Configuration)
        localLattice2 = try Lattice(SimpleSyncObject.self, SequenceSyncObject.self, SyncParent.self, SyncChild.self, SyncVectorObject.self, SyncGeoObject.self, SyncEmbeddedObject.self, TestDog.self, TestCat.self, TestPersonWithPets.self, TestPersonWithPet.self,
                                    configuration: localLattice2Configuration)
    }
    
    @Test(.timeLimit(.minutes(5))) func test_BasicSync() async throws {
        let lattice = localLattice1!
        let lattice2 = localLattice2!

        // --- Phase 1: INSERT sync (lattice1 → lattice2) ---

        var task: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let lattice2 = try await Lattice(SimpleSyncObject.self, configuration: self.localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                for try await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(isolation: nil, on: lattice2) })
                    if resolved.contains(where: { $0.operation == .insert && $0.tableName == "SimpleSyncObject" }) {
                        break
                    }
                }
            }
        }

        var taskForSynchronization: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            taskForSynchronization = Task.detached {
                let lattice1 = try await Lattice(SimpleSyncObject.self, configuration: self.localLattice1Configuration)
                let changeStream = lattice1.changeStream
                continuation.resume()
                for try await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(isolation: nil, on: lattice1) })
                    if resolved.contains(where: { $0.isSynchronized && $0.tableName == "SimpleSyncObject" }) {
                        break
                    }
                }
            }
        }

        let object = SimpleSyncObject(value: 42, floatValue: 42.42)
        try lattice.add(object)

        try await taskForSynchronization?.value
        try await task?.value

        #expect(lattice.objects(AuditLog.self).first?.isSynchronized == true)
        #expect(lattice2.objects(SimpleSyncObject.self).first?.value == 42)
        #expect(lattice2.objects(SimpleSyncObject.self).first?.floatValue == 42.42)

        // --- Phase 2: UPDATE sync ---

        await withCheckedContinuation { continuation in
            task = Task.detached {
                let lattice2 = try await Lattice(SimpleSyncObject.self, configuration: self.localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                var updateCount = 0
                for try await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(isolation: nil, on: lattice2) })
                    let updates = resolved.filter { $0.operation == .update && $0.tableName == "SimpleSyncObject" }
                    updateCount += updates.count
                    if updateCount >= 2 {
                        break
                    }
                }
            }
        }

        object.value = 84
        object.floatValue = 84.84
        try await task?.value
        #expect(lattice2.objects(SimpleSyncObject.self).first?.value == 84)
        #expect(lattice2.objects(SimpleSyncObject.self).first?.floatValue == 84.84)

        // --- Phase 3: DELETE sync ---

        let localLattice2Configuration = self.localLattice2Configuration
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let lattice2 = try Lattice(SimpleSyncObject.self, configuration: localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                for try await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(isolation: nil, on: lattice2) })
                    if resolved.contains(where: { $0.operation == .delete && $0.tableName == "SimpleSyncObject" }) {
                        break
                    }
                }
            }
        }

        _ = lattice.delete(object)
        try await task?.value
        #expect(lattice2.objects(SimpleSyncObject.self).count == 0)
    }

    /// Cross-lattice cascade for `Optional<Model>` links. Mirrors
    /// `ChatMessage.author: Member?` in ClaudeCodeIRC: lattice1 deletes
    /// the linked-to row, lattice2 must observe the link as nil — not
    /// dangling. The local-side cleanup is covered by
    /// `CascadeLinkCleanupTests`; this verifies the same invariant
    /// survives sync replay on the receiving lattice.
    @Test(.timeLimit(.minutes(5)))
    func test_DeletingLinkedChild_OptionalGoesToNilOnPeer() async throws {
        let lattice = localLattice1!
        let lattice2 = localLattice2!
        await server.sockets.waitForCount(2)

        // Phase 1: insert parent + child, link them, wait for the
        // SyncParent INSERT to land on lattice2 (the parent is the last
        // write — by then the child + link rows have already arrived).
        let localLattice2Configuration = self.localLattice2Configuration
        var task: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let l2 = try await Lattice(SyncParent.self, SyncChild.self, configuration: localLattice2Configuration)
                let changeStream = l2.changeStream
                continuation.resume()
                for try await changes in changeStream {
                    let resolved = changes.compactMap { $0.resolve(isolation: nil, on: l2) }
                    if resolved.contains(where: { $0.operation == .insert && $0.tableName == "SyncParent" }) {
                        return
                    }
                }
            }
        }

        let child = SyncChild(name: "alice")
        try lattice.add(child)
        let parent = SyncParent(name: "room")
        try lattice.add(parent)
        parent.favorite = child

        try await task?.value

        // Sanity: lattice2 sees the link live.
        let l2ParentBefore = lattice2.objects(SyncParent.self).first { $0.name == "room" }
        #expect(l2ParentBefore != nil)
        #expect(l2ParentBefore?.favorite?.name == "alice")

        // Capture the link table name from lattice1's audit log so the
        // wait + assertion aren't brittle against macro naming.
        let linkTableName = lattice.objects(AuditLog.self)
            .where { $0.operation == .insert }
            .compactMap { audit -> String? in
                let t = audit.tableName
                return (t != "SyncParent" && t != "SyncChild") ? t : nil
            }
            .first { $0.contains("favorite") }
        #expect(linkTableName != nil,
                "No favorite-link audit row found on the originating lattice — the link INSERT trigger didn't fire.")
        guard let linkTable = linkTableName else { return }

        // Phase 2: delete the child on lattice1, wait for the
        // link-table DELETE audit (the cascade signal) to apply on
        // lattice2. That's the change that flips `parent.favorite` to
        // nil; gating on it removes any race with the SyncChild DELETE
        // arriving before the cascade audit.
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let l2 = try await Lattice(SyncParent.self, SyncChild.self, configuration: localLattice2Configuration)
                let changeStream = l2.changeStream
                continuation.resume()
                for try await changes in changeStream {
                    let resolved = changes.compactMap { $0.resolve(isolation: nil, on: l2) }
                    if resolved.contains(where: { $0.operation == .delete && $0.tableName == linkTable }) {
                        return
                    }
                }
            }
        }
        lattice.delete(child)
        try await task?.value

        // Phase 3: the actual crash site in ClaudeCodeIRC was reading
        // `m.author?.nick` after the linked Member was deleted. The
        // Optional link's `getField` only checks `hasValue` (column
        // non-null) — if the link table on the peer still references a
        // missing row, we either SIGSEGV in `dynamic_object::get_object`
        // or get a non-nil ghost wrapper.
        let l2ParentAfter = lattice2.objects(SyncParent.self).first { $0.name == "room" }
        #expect(l2ParentAfter != nil)
        #expect(l2ParentAfter?.favorite == nil,
                "Expected parent.favorite to be nil on the receiving lattice after the linked SyncChild was deleted on the originating lattice. A non-nil value here means the cascade audit didn't replay over sync and the link is dangling.")
    }

    /// Wire-level companion to the test above: the link-table DELETE
    /// audit row must end up on lattice2. If it doesn't, the peer can
    /// never clean up its link table on its own — explains the
    /// orphaned `_Session_Member_host` rows seen in ClaudeCodeIRC after
    /// host `/leave`.
    @Test(.timeLimit(.minutes(5)))
    func test_LinkTableDeleteAudit_RidesOverSync() async throws {
        let lattice = localLattice1!
        let lattice2 = localLattice2!
        await server.sockets.waitForCount(2)

        let localLattice2Configuration = self.localLattice2Configuration
        var task: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let l2 = try await Lattice(SyncParent.self, SyncChild.self, configuration: localLattice2Configuration)
                let changeStream = l2.changeStream
                continuation.resume()
                for try await changes in changeStream {
                    let resolved = changes.compactMap { $0.resolve(isolation: nil, on: l2) }
                    if resolved.contains(where: { $0.operation == .insert && $0.tableName == "SyncParent" }) {
                        return
                    }
                }
            }
        }

        let child = SyncChild(name: "alice")
        try lattice.add(child)
        let parent = SyncParent(name: "room")
        try lattice.add(parent)
        parent.favorite = child
        try await task?.value

        // Capture the link table name from lattice1's audit log so the
        // assertion isn't brittle against macro naming.
        let linkTableName = lattice.objects(AuditLog.self)
            .where { $0.operation == .insert }
            .compactMap { audit -> String? in
                let t = audit.tableName
                return (t != "SyncParent" && t != "SyncChild") ? t : nil
            }
            .first { $0.contains("favorite") }
        #expect(linkTableName != nil,
                "No favorite-link audit row found on the originating lattice — the link INSERT trigger didn't fire as expected.")
        guard let linkTable = linkTableName else { return }

        // Wait for the link-table DELETE itself on lattice2 (not the
        // SyncChild DELETE — the link cascade can land separately, and
        // that's exactly the audit row we're asserting on).
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let l2 = try await Lattice(SyncParent.self, SyncChild.self, configuration: localLattice2Configuration)
                let changeStream = l2.changeStream
                continuation.resume()
                for try await changes in changeStream {
                    let resolved = changes.compactMap { $0.resolve(isolation: nil, on: l2) }
                    if resolved.contains(where: { $0.operation == .delete && $0.tableName == linkTable }) {
                        return
                    }
                }
            }
        }
        lattice.delete(child)
        try await task?.value

        let l2LinkDeletes = lattice2.objects(AuditLog.self)
            .where { $0.tableName == linkTable }
            .where { $0.operation == .delete }
            .count
        #expect(l2LinkDeletes >= 1,
                "lattice2 should have received an AuditLog DELETE for \(linkTable). Without it the link table on the peer keeps a row pointing at a SyncChild that no longer exists. count=\(l2LinkDeletes)")
    }

//    @available(macOS 15.0, *)
//    @Test(.timeLimit(.minutes(3))) func test_BigSync() async throws {
//        let lattice = localLattice1!
//        let lattice2 = localLattice2!
//
//        var task: Task<Void, any Error>?
//        await withCheckedContinuation { continuation in
//            task = Task { @MainActor in
//                let lattice2 = try Lattice(SequenceSyncObject.self, configuration: localLattice2Configuration)
//                let changeStream = lattice2.changeStream
//                continuation.resume()
//                var changeCount = 0
//                for await changes in changeStream {
//                    changeCount += changes.count(where: { $0.tableName == "SequenceSyncObject" && $0.operation == .insert }) // why? updating isSynchronized will also update this block
//                    print("Change count: \(changeCount)")
//                    if changeCount == 100_000 {
//                        break
//                    }
//                }
//            }
//        }
//        let objects = (0..<100_000).map { _ in SequenceSyncObject() }
//        lattice.transaction {
//            try lattice.add(contentsOf: objects)
//        }
//        try await task?.value
//        
//        #expect(lattice2.objects(SequenceSyncObject.self).count == 100_000)
//        #expect(lattice2.objects(AuditLog.self).count == 100_000)
//    }
    
    @Test func testIsolation() async throws {
        await MainActor.shared.invoke { _ in
            await #isolation?.invoke { @Sendable _ in
            }
        }
    }

    /// Test that List<T> relationships sync properly between clients.
    /// This test verifies that when a parent object with children is created on one client,
    /// the relationship (not just the objects) syncs to the other client.
    @Test(.timeLimit(.minutes(5))) func test_ListRelationshipSync() async throws {
        let lattice = localLattice1!
        let lattice2 = localLattice2!

        // Set up changeStreams BEFORE adding data to avoid race conditions
        var task: Task<Void, any Error>?
        var taskForSynchronization: Task<Void, any Error>?

        await withCheckedContinuation { continuation in
            task = Task.detached {
                let lattice2 = try await Lattice(SyncParent.self, SyncChild.self, configuration: self.localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                var insertCount = 0
                for try await changes in changeStream {
                    let changes = changes.compactMap({ $0.resolve(isolation: nil, on: lattice2) })
                    insertCount += changes.count(where: { $0.operation == .insert })
                    // 3 model inserts: 1 parent + 2 children
                    // (link table AuditLog entries don't generate changeStream notifications)
                    if insertCount >= 3 { break }
                }
            }
        }

        await withCheckedContinuation { continuation in
            taskForSynchronization = Task.detached {
                let lattice1 = try await Lattice(SyncParent.self, SyncChild.self, configuration: self.localLattice1Configuration)
                let changeStream = lattice1.changeStream
                continuation.resume()
                for try await changes in changeStream {
                    let changes = changes.compactMap({ $0.resolve(isolation: nil, on: lattice1) })
                    if changes.allSatisfy({ $0.isSynchronized }) {
                        break
                    }
                }
            }
        }

        // Create parent with children on lattice1
        let parent = SyncParent(name: "Parent")
        let child1 = SyncChild(name: "Child1")
        let child2 = SyncChild(name: "Child2")

        try lattice.transaction {
            try lattice.add(parent)
            parent.children.append(child1)
            parent.children.append(child2)
        }

        // Verify local state
        #expect(parent.children.count == 2)
        #expect(lattice.objects(SyncChild.self).count == 2)

        // Check that AuditLog entries were created for the link table
        // This is what we're testing - link table changes should generate audit log entries
        let auditLogs = lattice.objects(AuditLog.self).snapshot()
        let linkTableLogs = auditLogs.filter { $0.tableName.hasPrefix("_SyncParent_SyncChild") }

        // THIS IS THE KEY TEST: Link table operations should be in the audit log
        #expect(linkTableLogs.count >= 2, "Link table INSERT operations should be in AuditLog for sync to work. Found: \(linkTableLogs.count)")

        // Wait for sync to complete
        try await taskForSynchronization?.value
        try await task?.value
        // Verify lattice2 received the objects
        #expect(lattice2.objects(SyncParent.self).count == 1, "Parent should sync")
        #expect(lattice2.objects(SyncChild.self).count == 2, "Children should sync")

        // Link table changes are internal — flush_changes translates them to parent
        // table UPDATE notifications, NOT AuditLog INSERTs. The changeStream (which
        // watches AuditLog) only sees 3 model inserts. If link entries arrive in a
        // separate server message, they won't be committed when changeStream breaks.
        // Use observe() on the Results to catch the parent UPDATE notification.
        //
        // Register the observer BEFORE checking the condition to avoid a TOCTOU race:
        // if children become ready between the check and observer registration, the
        // continuation would never resume.
        let childrenReady = NIOLockedValueBox(false)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var cancellable: AnyCancellable?
            let tryComplete = {
                if (lattice2.objects(SyncParent.self).first?.children.count ?? 0) >= 2 {
                    if !childrenReady.withLockedValue({ val in
                        let was = val; val = true; return was
                    }) {
                        cancellable?.cancel()
                        continuation.resume()
                    }
                }
            }
            cancellable = lattice2.objects(SyncParent.self).observe { _ in
                tryComplete()
            }
            // Check if condition is already met after registering the observer.
            tryComplete()
        }

        // THIS IS THE KEY TEST: Verify the relationship synced, not just the objects
        let syncedParent = lattice2.objects(SyncParent.self).first
        #expect(syncedParent != nil, "Should have synced parent")
        #expect(syncedParent?.children.count == 2, "Parent-child relationship should sync (List<T> links)")
        #expect(syncedParent?.children.contains(where: { $0.name == "Child1" }) == true, "Child1 should be linked")
        #expect(syncedParent?.children.contains(where: { $0.name == "Child2" }) == true, "Child2 should be linked")
    }

    /// Test that FloatVector fields sync properly between clients.
    @Test(.timeLimit(.minutes(5))) func test_VectorSync() async throws {
        let lattice = localLattice1!
        let lattice2 = localLattice2!

        let embedding: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]

        // Wait for lattice2 to receive the insert
        var task: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let lattice2 = try await Lattice(SyncVectorObject.self, configuration: self.localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                for try await changes in changeStream {
                    let changes = changes.compactMap({ $0.resolve(isolation: nil, on: lattice2) })
                    if changes.contains(where: { $0.operation == .insert && $0.tableName == "SyncVectorObject" }) {
                        break
                    }
                }
            }
        }

        // Wait for lattice1 to confirm sync
        var syncTask: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            syncTask = Task.detached {
                let lattice1 = try await Lattice(SyncVectorObject.self, configuration: self.localLattice1Configuration)
                let changeStream = lattice1.changeStream
                continuation.resume()
                for try await changes in changeStream {
                    let changes = changes.compactMap({ $0.resolve(isolation: nil, on: lattice1) })
                    if changes.allSatisfy({ $0.isSynchronized }) {
                        break
                    }
                }
            }
        }

        let obj = SyncVectorObject(label: "test-vector", embedding: embedding)
        try lattice.add(obj)

        try await syncTask?.value
        try await task?.value

        // Verify the object synced
        let synced = lattice2.objects(SyncVectorObject.self)
        #expect(synced.count == 1, "Vector object should sync")

        let syncedObj = synced.first!
        #expect(syncedObj.label == "test-vector")
        #expect(syncedObj.embedding.dimensions == 5, "Vector dimensions should be preserved")

        // Verify vector values are preserved
        for (i, value) in syncedObj.embedding.enumerated() {
            #expect(abs(value - embedding[i]) < 0.0001, "Vector element \(i) should match")
        }

        // Test updating the vector
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let lattice2 = try await Lattice(SyncVectorObject.self, configuration: self.localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                for try await changes in changeStream {
                    let changes = changes.compactMap({ $0.resolve(isolation: nil, on: lattice2) })
                    if changes.contains(where: { $0.operation == .update && $0.tableName == "SyncVectorObject" }) {
                        break
                    }
                }
            }
        }

        obj.embedding = FloatVector([1.0, 2.0, 3.0, 4.0, 5.0])
        try await task?.value

        let updated = lattice2.objects(SyncVectorObject.self).first!
        #expect(abs(updated.embedding[0] - 1.0) < 0.0001, "Updated vector should sync")
        #expect(abs(updated.embedding[4] - 5.0) < 0.0001, "Updated vector should sync")
    }

    /// Test that CLLocationCoordinate2D (R*Tree virtual table) fields sync properly.
    @Test(.timeLimit(.minutes(5))) func test_GeoboundsSync() async throws {
        let lattice = localLattice1!
        let lattice2 = localLattice2!

        var task: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let lattice2 = try await Lattice(SyncGeoObject.self, configuration: self.localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                for try await changes in changeStream {
                    let changes = changes.compactMap({ $0.resolve(isolation: nil, on: lattice2) })
                    if changes.contains(where: { $0.operation == .insert && $0.tableName == "SyncGeoObject" }) {
                        break
                    }
                }
            }
        }

        var syncTask: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            syncTask = Task.detached {
                let lattice1 = try await Lattice(SyncGeoObject.self, configuration: self.localLattice1Configuration)
                let changeStream = lattice1.changeStream
                continuation.resume()
                for try await changes in changeStream {
                    let changes = changes.compactMap({ $0.resolve(isolation: nil, on: lattice1) })
                    if changes.allSatisfy({ $0.isSynchronized }) {
                        break
                    }
                }
            }
        }

        let obj = SyncGeoObject(name: "NYC", latitude: 40.7128, longitude: -74.0060)
        try lattice.add(obj)

        try await syncTask?.value
        try await task?.value

        let synced = lattice2.objects(SyncGeoObject.self)
        #expect(synced.count == 1, "Geo object should sync")

        let syncedObj = synced.first!
        #expect(syncedObj.name == "NYC")
        #expect(Swift.abs(syncedObj.location.latitude - 40.7128) < 0.0001, "Latitude should be preserved")
        #expect(Swift.abs(syncedObj.location.longitude - (-74.0060)) < 0.0001, "Longitude should be preserved")

        // Test updating location
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let lattice2 = try await Lattice(SyncGeoObject.self, configuration: self.localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                for try await changes in changeStream {
                    let changes = changes.compactMap({ $0.resolve(isolation: nil, on: lattice2) })
                    if changes.contains(where: { $0.operation == .update && $0.tableName == "SyncGeoObject" }) {
                        break
                    }
                }
            }
        }

        obj.location = CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)
        try await task?.value

        let updatedObj = lattice2.objects(SyncGeoObject.self).first!
        #expect(Swift.abs(updatedObj.location.latitude - 34.0522) < 0.0001, "Updated latitude should sync")
        #expect(Swift.abs(updatedObj.location.longitude - (-118.2437)) < 0.0001, "Updated longitude should sync")
    }

    /// Test that EmbeddedModel fields sync properly.
    @Test(.timeLimit(.minutes(5))) func test_EmbeddedModelSync() async throws {
        let lattice = localLattice1!
        let lattice2 = localLattice2!

        var task: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let lattice2 = try await Lattice(SyncEmbeddedObject.self, configuration: self.localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                for try await changes in changeStream {
                    let changes = changes.compactMap({ $0.resolve(isolation: nil, on: lattice2) })
                    if changes.contains(where: { $0.operation == .insert && $0.tableName == "SyncEmbeddedObject" }) {
                        break
                    }
                }
            }
        }

        var syncTask: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            syncTask = Task.detached {
                let lattice1 = try await Lattice(SyncEmbeddedObject.self, configuration: self.localLattice1Configuration)
                let changeStream = lattice1.changeStream
                continuation.resume()
                for try await changes in changeStream {
                    let changes = changes.compactMap({ $0.resolve(isolation: nil, on: lattice1) })
                    if changes.allSatisfy({ $0.isSynchronized }) {
                        break
                    }
                }
            }
        }

        let obj = SyncEmbeddedObject(name: "test", metadata: SyncEmbedded(detail: "hello"))
        try lattice.add(obj)

        try await syncTask?.value
        try await task?.value

        let synced = lattice2.objects(SyncEmbeddedObject.self)
        #expect(synced.count == 1, "Embedded object should sync")
        #expect(synced.first?.name == "test")
        #expect(synced.first?.metadata?.detail == "hello", "Embedded field should be preserved")

        // Test updating the embedded field
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let lattice2 = try await Lattice(SyncEmbeddedObject.self, configuration: self.localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                for try await changes in changeStream {
                    let changes = changes.compactMap({ $0.resolve(isolation: nil, on: lattice2) })
                    if changes.contains(where: { $0.operation == .update && $0.tableName == "SyncEmbeddedObject" }) {
                        break
                    }
                }
            }
        }

        obj.metadata = SyncEmbedded(detail: "updated")
        try await task?.value

        #expect(lattice2.objects(SyncEmbeddedObject.self).first?.metadata?.detail == "updated", "Updated embedded field should sync")
    }

    /// test_BasicSync only tests lattice1→lattice2. This tests lattice2→lattice1 as well.
    @Test(.timeLimit(.minutes(5))) func test_BidirectionalSync() async throws {
        let lattice = localLattice1!
        let lattice2 = localLattice2!

        // Step 1: lattice1 writes, lattice2 receives
        var task: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let l2 = try await Lattice(SimpleSyncObject.self, configuration: self.localLattice2Configuration)
                let changeStream = l2.changeStream
                continuation.resume()
                for try await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(isolation: nil, on: l2) })
                    if resolved.contains(where: { $0.operation == .insert && $0.tableName == "SimpleSyncObject" }) {
                        break
                    }
                }
            }
        }

        let obj1 = SimpleSyncObject(value: 111, floatValue: 1.1)
        try lattice.add(obj1)
        try await task?.value
        #expect(lattice2.objects(SimpleSyncObject.self).count >= 1, "Lattice2 should receive from lattice1")

        // Step 2: lattice2 writes back, lattice1 receives (reverse direction)
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let l1 = try await Lattice(SimpleSyncObject.self, configuration: self.localLattice1Configuration)
                let changeStream = l1.changeStream
                continuation.resume()
                for try await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(isolation: nil, on: l1) })
                    if resolved.contains(where: { $0.operation == .insert && $0.tableName == "SimpleSyncObject" }) {
                        break
                    }
                }
            }
        }

        let obj2 = SimpleSyncObject(value: 222, floatValue: 2.2)
        try lattice2.add(obj2)
        try await task?.value

        let l1Values = Set(lattice.objects(SimpleSyncObject.self).map(\.value))
        let l2Values = Set(lattice2.objects(SimpleSyncObject.self).map(\.value))
        #expect(l1Values.contains(111) && l1Values.contains(222), "Lattice1 should see values from both clients")
        #expect(l2Values.contains(111) && l2Values.contains(222), "Lattice2 should see values from both clients")
    }

    /// Test that a fresh client receives historical events on connect via eventsAfter().
    @Test(.timeLimit(.minutes(5))) func test_CatchUpSync() async throws {
        let lattice = localLattice1!

        // Write data and wait for it to arrive in the SERVER's DB.
        // The test server sends ACK before Task.detached DB persistence, so
        // we observe the server DB directly via cross-instance changeStream.
        let syncedConfig = self.syncedLatticeConfiguration
        var serverTask: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            serverTask = Task.detached {
                let server = try Lattice(SimpleSyncObject.self, configuration: syncedConfig)
                let changeStream = server.changeStream
                continuation.resume()
                for try await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(isolation: nil, on: server) })
                    if resolved.contains(where: { $0.tableName == "SimpleSyncObject" }) {
                        break
                    }
                }
            }
        }

        let obj = SimpleSyncObject(value: 999, floatValue: 9.9)
        try lattice.add(obj)
        try await serverTask?.value

        // Create a fresh client — it should receive the historical data on connect.
        // Observer Lattice (no sync) set up FIRST so changeStream is ready before
        // the sync Lattice connects and delivers initial events via eventsAfter.
        let freshURL = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 30)).sqlite")
        let freshObserverConfig = Lattice.Configuration(fileURL: freshURL)
        var freshTask: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            freshTask = Task.detached {
                let observer = try Lattice(SimpleSyncObject.self, SequenceSyncObject.self, SyncParent.self, SyncChild.self, SyncVectorObject.self, SyncGeoObject.self, SyncEmbeddedObject.self, configuration: freshObserverConfig)
                let changeStream = observer.changeStream
                continuation.resume()
                for try await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(isolation: nil, on: observer) })
                    if resolved.contains(where: { $0.tableName == "SimpleSyncObject" }) {
                        break
                    }
                }
            }
        }

        let freshConfig = Lattice.Configuration(
            fileURL: freshURL,
            authorizationToken: "hi3",
            wssEndpoint: URL(string: "http://localhost:\(port)/test"))
        let freshLattice = try Lattice(SimpleSyncObject.self, SequenceSyncObject.self, SyncParent.self, SyncChild.self, SyncVectorObject.self, SyncGeoObject.self, SyncEmbeddedObject.self, configuration: freshConfig)
        try await freshTask?.value

        let objects = freshLattice.objects(SimpleSyncObject.self)
        #expect(objects.count >= 1, "Fresh client should receive historical data on connect")
        #expect(objects.first?.value == 999, "Historical value should be correct")

        try? Lattice.delete(for: freshConfig)
    }

    /// Test that server-side compaction doesn't break catch-up sync.
    /// After the server compacts its audit log (replacing history with INSERT snapshots),
    /// a fresh client should still receive all current data on connect.
    @Test(.timeLimit(.minutes(5))) func test_ServerCompactionCatchUp() async throws {
        let lattice = localLattice1!

        // Step 1: Write data and wait for it to arrive in the SERVER's DB.
        // The test server sends ACK before Task.detached DB persistence, so
        // observing lattice1's isSynchronized is insufficient — observe the
        // server DB directly via cross-instance changeStream notification.
        let syncedConfig = self.syncedLatticeConfiguration
        var serverTask: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            serverTask = Task.detached {
                let server = try Lattice(SimpleSyncObject.self, configuration: syncedConfig)
                let changeStream = server.changeStream
                continuation.resume()
                for try await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(isolation: nil, on: server) })
                    if resolved.contains(where: { $0.tableName == "SimpleSyncObject" }) {
                        break
                    }
                }
            }
        }

        let obj = SimpleSyncObject(value: 555, floatValue: 5.5)
        try lattice.add(obj)
        try await serverTask?.value

        // Step 2: Force compact the server's audit log — replaces all history with INSERT snapshots
        let serverEntries = syncedLattice.forceCompactHistory()
        #expect(serverEntries >= 1, "Server should create snapshot entries for existing objects")

        // Verify the server still has the data
        #expect(syncedLattice.objects(SimpleSyncObject.self).count >= 1, "Server data should survive compaction")

        // Step 3: A fresh client connects — should receive data from the compacted snapshots.
        // Create an observer Lattice (no sync) FIRST to set up changeStream before
        // the sync Lattice connects and delivers data.
        let freshURL = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 30)).sqlite")
        let freshObserverConfig = Lattice.Configuration(fileURL: freshURL)
        var freshTask: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            freshTask = Task.detached {
                let observer = try Lattice(SimpleSyncObject.self, SequenceSyncObject.self, SyncParent.self, SyncChild.self, SyncVectorObject.self, SyncGeoObject.self, SyncEmbeddedObject.self, configuration: freshObserverConfig)
                let changeStream = observer.changeStream
                continuation.resume()
                for try await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(isolation: nil, on: observer) })
                    if resolved.contains(where: { $0.tableName == "SimpleSyncObject" }) {
                        break
                    }
                }
            }
        }

        let freshConfig = Lattice.Configuration(
            fileURL: freshURL,
            authorizationToken: "compact-test",
            wssEndpoint: URL(string: "http://localhost:\(port)/test"))
        let freshLattice = try Lattice(SimpleSyncObject.self, SequenceSyncObject.self, SyncParent.self, SyncChild.self, SyncVectorObject.self, SyncGeoObject.self, SyncEmbeddedObject.self, configuration: freshConfig)
        try await freshTask?.value

        let objects = freshLattice.objects(SimpleSyncObject.self)
        #expect(objects.count >= 1, "Fresh client should receive data from compacted server")
        #expect(objects.first?.value == 555, "Value should match original")
        #expect(objects.first?.floatValue == 5.5, "Float value should match original")

        try? Lattice.delete(for: freshConfig)
    }

    /// Test that client-side compaction doesn't break ongoing sync.
    /// After a client compacts its local audit log, new changes should still sync.
    @Test(.timeLimit(.minutes(5))) func test_ClientCompactionThenSync() async throws {
        let lattice = localLattice1!
        let lattice2 = localLattice2!

        // Step 1: Write data and wait for sync to lattice2
        var receiveTask: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            receiveTask = Task.detached {
                let l2 = try await Lattice(SimpleSyncObject.self, configuration: self.localLattice2Configuration)
                let changeStream = l2.changeStream
                continuation.resume()
                for try await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(isolation: nil, on: l2) })
                    if resolved.contains(where: { $0.operation == .insert && $0.tableName == "SimpleSyncObject" }) {
                        break
                    }
                }
            }
        }

        let obj1 = SimpleSyncObject(value: 100, floatValue: 1.0)
        try lattice.add(obj1)
        try await receiveTask?.value
        #expect(lattice2.objects(SimpleSyncObject.self).count >= 1, "Initial sync should work")

        // Step 2: Force compact lattice1's audit log (nuclear — no replication slots in WSS-only)
        let compactedEntries = lattice.forceCompactHistory()
        #expect(compactedEntries >= 1, "Should create snapshot entries")

        // Step 3: Write NEW data after compaction and wait for it on lattice2.
        // After compaction, lattice1 has fresh INSERT snapshot entries (isSynchronized=0).
        // Adding obj2 triggers upload_pending_changes which sends BOTH the compacted
        // snapshot AND obj2. The C++ fix in apply_remote_changes resolves local rowId
        // and operation so flush_changes can correlate them with the update_hook.
        var receiveTask2: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            receiveTask2 = Task.detached {
                let l2 = try await Lattice(SimpleSyncObject.self, configuration: self.localLattice2Configuration)
                let changeStream = l2.changeStream
                continuation.resume()
                for try await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(isolation: nil, on: l2) })
                    if resolved.contains(where: { $0.tableName == "SimpleSyncObject" }),
                       l2.objects(SimpleSyncObject.self).contains(where: { $0.value == 200 }) {
                        break
                    }
                }
            }
        }

        let obj2 = SimpleSyncObject(value: 200, floatValue: 2.0)
        try lattice.add(obj2)
        try await receiveTask2?.value

        #expect(lattice2.objects(SimpleSyncObject.self).count >= 2,
                "Lattice2 should have both objects after compaction sync")
        #expect(lattice2.objects(SimpleSyncObject.self).contains(where: { $0.value == 200 }),
                "New data written after client compaction should sync")
    }

    /// Test that closing the lattice instance that owns the synchronizer
    /// hands off sync responsibility to a surviving sibling instance.
    @Test(.timeLimit(.minutes(5))) func test_SyncHandoff() async throws {
        let lattice2 = localLattice2!

        // Fresh path so we control which instance gets the synchronizer
        let handoffURL = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 30)).sqlite")
        let handoffConfig = Lattice.Configuration(
            fileURL: handoffURL,
            authorizationToken: "hi",
            wssEndpoint: URL(string: "http://localhost:\(port)/test"))

        // Instance A from actor context — gets the synchronizer
        let instanceA = try Lattice(SimpleSyncObject.self, configuration: handoffConfig)

        // Wait for A to connect
        var attempts = 0
        while !instanceA.isSyncConnected && attempts < 50 {
            try await Task.sleep(for: .milliseconds(100))
            attempts += 1
        }
        #expect(instanceA.isSyncConnected, "Instance A should be sync-connected")

        // Set up lattice2 listener before the handoff
        let localLattice2Configuration = self.localLattice2Configuration
        var receiveTask: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            receiveTask = Task.detached {
                let l2 = try Lattice(SimpleSyncObject.self, configuration: localLattice2Configuration)
                let changeStream = l2.changeStream
                continuation.resume()
                for try await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(isolation: nil, on: l2) })
                    if resolved.contains(where: { $0.operation == .insert && $0.tableName == "SimpleSyncObject" }) {
                        break
                    }
                }
            }
        }

        // Instance B lives entirely in a detached task (different isolation → different scheduler)
        // Use streams to coordinate: B signals ready, we close A, then signal B to write
        let bReady = AsyncStream.makeStream(of: Void.self)
        let proceed = AsyncStream.makeStream(of: Void.self)

        let writeTask = Task.detached {
            let instanceB = try Lattice(SimpleSyncObject.self, configuration: handoffConfig)

            // Signal that B is alive and registered in the instance_registry
            bReady.continuation.yield()

            // Wait for A to be closed (handoff happens during close)
            for await _ in proceed.stream { break }

            // B should now have inherited sync responsibility
            var attempts = 0
            while !instanceB.isSyncConnected && attempts < 50 {
                try await Task.sleep(for: .milliseconds(100))
                attempts += 1
            }
            guard instanceB.isSyncConnected else {
                throw NSError(domain: "SyncHandoff", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Instance B did not pick up sync after handoff"])
            }

            // Write through B — should sync to lattice2
            try instanceB.add(SimpleSyncObject(value: 777, floatValue: 7.7))
        }

        // Wait for B to exist
        for await _ in bReady.stream { break }

        // Close A — teardown_sync hands off to B
        instanceA.close()

        // Tell B to proceed
        proceed.continuation.yield()
        proceed.continuation.finish()

        try await writeTask.value
        try await receiveTask?.value

        #expect(lattice2.objects(SimpleSyncObject.self).contains(where: { $0.value == 777 }),
                "Data written through instance B (after handoff) should sync to lattice2")

        try? Lattice.delete(for: handoffConfig)
    }

    /// Test that a bulk insert in a transaction syncs correctly.
    @Test(.timeLimit(.minutes(5))) func test_BulkInsertSync() async throws {
        let lattice = localLattice1!
        let lattice2 = localLattice2!

        let count = 100

        var task: Task<Void, any Error>?
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let lattice2 = try await Lattice(SimpleSyncObject.self, configuration: self.localLattice2Configuration)
                let changeStream = lattice2.changeStream
                continuation.resume()
                var insertCount = 0
                for try await changes in changeStream {
                    let resolved = changes.compactMap({ $0.resolve(isolation: nil, on: lattice2) })
                    insertCount += resolved.count(where: { $0.tableName == "SimpleSyncObject" && $0.operation == .insert })
                    if insertCount >= count {
                        break
                    }
                }
            }
        }

        let objects = (0..<count).map { SimpleSyncObject(value: $0, floatValue: Float($0)) }
        try lattice.transaction {
            try lattice.add(contentsOf: objects)
        }

        try await task?.value

        #expect(lattice2.objects(SimpleSyncObject.self).count == count, "All \(count) objects should sync")
    }
}
