import Foundation
#if canImport(Combine)
import Combine
#endif
import NIOConcurrencyHelpers
import NIOCore
import Testing
import Lattice
import Observation
import Vapor

// MARK: - Filtered Sync Models

@Model class FilteredNote {
    var title: String
    var isPublic: Bool

    init(title: String = "", isPublic: Bool = false) {
        self.title = title
        self.isPublic = isPublic
    }
}

@Model class FilteredTag {
    var name: String

    init(name: String = "") {
        self.name = name
    }
}

// MARK: - SyncFilter Unit Tests

@Suite("SyncFilter Tests")
struct SyncFilterTests {
    @Test func include_withoutPredicate_addsEntry() {
        var filter = Lattice.SyncFilter()
        filter.include(FilteredNote.self)
        // The entry should exist with nil predicate (all rows).
        // Regression: `entries[key] = nil` removes the key in [String: String?] dictionaries.
        #expect(filter != Lattice.SyncFilter()) // must not be empty
    }

    @Test func include_withPredicate_addsEntry() {
        var filter = Lattice.SyncFilter()
        filter.include(FilteredNote.self, where: { $0.isPublic == true })
        #expect(filter != Lattice.SyncFilter())
    }

    @Test func exclude_removesEntry() {
        var filter = Lattice.SyncFilter()
        filter.include(FilteredNote.self)
        filter.include(FilteredTag.self)
        filter.exclude(FilteredNote.self)
        // Should still have FilteredTag
        #expect(filter != Lattice.SyncFilter())
        // Exclude the last one
        filter.exclude(FilteredTag.self)
        #expect(filter == Lattice.SyncFilter())
    }

    @Test func emptyFilter_notEqualToFilterWithEntries() {
        let empty = Lattice.SyncFilter()
        var withEntry = Lattice.SyncFilter()
        withEntry.include(FilteredNote.self)
        #expect(empty != withEntry)
    }

    @Test func include_sameTable_twice_isIdempotent() {
        var filter1 = Lattice.SyncFilter()
        filter1.include(FilteredNote.self)

        var filter2 = Lattice.SyncFilter()
        filter2.include(FilteredNote.self)
        filter2.include(FilteredNote.self)

        #expect(filter1 == filter2)
    }
}

// MARK: - Filtered Sync Tests

@Suite("Filtered Sync Tests", .serialized)
actor FilteredSyncTests {
    let server: TestSyncServer
    let serverLatticeURL = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    let senderURL = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    let receiverURL = FileManager.default.temporaryDirectory
        .appending(path: "\(String.random(length: 30)).sqlite")
    var port: Int = 0
    var sender: Lattice!
    var receiver: Lattice!
    var serverLatticeConfig: Lattice.Configuration
    var senderConfig: Lattice.Configuration
    var receiverConfig: Lattice.Configuration

    deinit {
        server.shutdown()
        try? Lattice.delete(for: senderConfig)
        try? Lattice.delete(for: receiverConfig)
        try? Lattice.delete(for: serverLatticeConfig)
    }

    init() async throws {
        lattice_set_log_level(lattice.log_level.warn)
        self.serverLatticeConfig = .init(fileURL: serverLatticeURL)
        self.senderConfig = .init(fileURL: senderURL)
        self.receiverConfig = .init(fileURL: receiverURL)

        // D1b: shared TestSyncServer (one server-lifetime lattice, ordered persistence).
        self.server = try await TestSyncServer(
            models: [FilteredNote.self, FilteredTag.self],
            configuration: serverLatticeConfig,
            label: "FilteredSync")
        self.port = server.port

        // Receiver: no sync filter (accepts everything the server sends)
        receiverConfig = Lattice.Configuration(
            fileURL: receiverURL,
            authorizationToken: "recv",
            wssEndpoint: URL(string: "http://localhost:\(port)/test"))
        receiver = try Lattice(FilteredNote.self, FilteredTag.self, configuration: receiverConfig)
    }

    /// Helper: create a sender with a given sync filter
    private func makeSender(syncFilter: Lattice.SyncFilter?) throws -> Lattice {
        senderConfig = Lattice.Configuration(
            fileURL: senderURL,
            authorizationToken: "send",
            wssEndpoint: URL(string: "http://localhost:\(port)/test"),
            syncFilter: syncFilter)
        let s = try Lattice(FilteredNote.self, FilteredTag.self, configuration: senderConfig)
        return s
    }

    /// Start listening for a specific table+operation on receiver BEFORE performing the action.
    /// Returns a task — await its value AFTER performing the action.
    private func startListeningForReceiver(
        table: String, operation: AuditLog.Operation
    ) async -> Task<Void, any Error> {
        var task: Task<Void, any Error>!
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let r = try await Lattice(FilteredNote.self, FilteredTag.self, configuration: self.receiverConfig)
                let changeStream = r.changeStream
                continuation.resume()
                for try await changes in changeStream {
                    let resolved = changes.compactMap { $0.resolve(isolation: nil, on: r) }
                    if resolved.contains(where: { $0.tableName == table && $0.operation == operation }) {
                        return
                    }
                }
            }
        }
        return task
    }

    /// Helper: ensure nothing arrives on receiver for a given duration
    private func assertNothingReceived(
        table: String, duration: Duration = .seconds(2)
    ) async throws {
        let received = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            Task.detached {
                let r = try await Lattice(FilteredNote.self, FilteredTag.self, configuration: self.receiverConfig)
                let changeStream = r.changeStream
                let innerTask = Task {
                    for try await changes in changeStream {
                        let resolved = changes.compactMap { $0.resolve(isolation: nil, on: r) }
                        if resolved.contains(where: { $0.tableName == table }) {
                            return true
                        }
                    }
                    return false
                }
                try? await Task.sleep(for: duration)
                innerTask.cancel()
                let result = (try? await innerTask.value) ?? false
                continuation.resume(returning: result)
            }
        }
        if received {
            Issue.record("Unexpected sync of table \(table)")
        }
    }

    // =========================================================================
    // Test 1: Only configured tables sync
    // =========================================================================
    @Test(.disabled(if: isMacOSCI, "Darwin CI hang class — await never resumes and .timeLimit cannot interrupt on macOS; runs locally and on Linux CI. Owner: 1.0 item D1b/D2"), .timeLimit(.minutes(5)))
    func test_FilteredSync_TableWhitelist() async throws {
        var filter = Lattice.SyncFilter()
        filter.include(FilteredNote.self)
        sender = try makeSender(syncFilter: filter)
        try await Task.sleep(for: .milliseconds(500))

        let task = await startListeningForReceiver(table: "FilteredNote", operation: .insert)

        let note = FilteredNote(title: "public note", isPublic: true)
        let tag = FilteredTag(name: "private-tag")
        try sender.add(note)
        try sender.add(tag)

        try await task.value

        // Tag should NOT have synced
        try await assertNothingReceived(table: "FilteredTag")

        // Only note should be on receiver
        #expect(receiver.objects(FilteredNote.self).count == 1)
        #expect(receiver.objects(FilteredTag.self).count == 0)
    }

    // =========================================================================
    // Test 2: Only matching rows sync
    // =========================================================================
    @Test(.timeLimit(.minutes(5)))
    func test_FilteredSync_PredicateFilter() async throws {
        var filter = Lattice.SyncFilter()
        filter.include(FilteredNote.self, where: { $0.isPublic == true })
        sender = try makeSender(syncFilter: filter)
        try await Task.sleep(for: .milliseconds(500))

        let task = await startListeningForReceiver(table: "FilteredNote", operation: .insert)

        let publicNote = FilteredNote(title: "visible", isPublic: true)
        let privateNote = FilteredNote(title: "hidden", isPublic: false)
        try sender.add(publicNote)
        try sender.add(privateNote)

        try await task.value

        #expect(receiver.objects(FilteredNote.self).count == 1)
        #expect(receiver.objects(FilteredNote.self).first?.title == "visible")
    }

    // =========================================================================
    // Test 3: Object leaves sync set (update makes row fail predicate → DELETE)
    // =========================================================================
    @Test(.timeLimit(.minutes(5)))
    func test_FilteredSync_ObjectLeavesSet() async throws {
        var filter = Lattice.SyncFilter()
        filter.include(FilteredNote.self, where: { $0.isPublic == true })
        sender = try makeSender(syncFilter: filter)
        try await Task.sleep(for: .milliseconds(500))

        // Phase 1: add public note → syncs
        let insertTask = await startListeningForReceiver(table: "FilteredNote", operation: .insert)
        let note = FilteredNote(title: "was-public", isPublic: true)
        try sender.add(note)
        try await insertTask.value
        #expect(receiver.objects(FilteredNote.self).count == 1)

        // Phase 2: make private → synthetic DELETE
        let deleteTask = await startListeningForReceiver(table: "FilteredNote", operation: .delete)
        note.isPublic = false
        try await deleteTask.value
        #expect(receiver.objects(FilteredNote.self).count == 0)
    }

    // =========================================================================
    // Test 4: Object enters sync set (update makes row pass predicate → INSERT)
    // =========================================================================
    @Test(.timeLimit(.minutes(5)))
    func test_FilteredSync_ObjectEntersSet() async throws {
        var filter = Lattice.SyncFilter()
        filter.include(FilteredNote.self, where: { $0.isPublic == true })
        sender = try makeSender(syncFilter: filter)
        try await Task.sleep(for: .milliseconds(500))

        // Add a private note → should NOT sync
        let note = FilteredNote(title: "was-private", isPublic: false)
        try sender.add(note)
        try await Task.sleep(for: .seconds(1))
        #expect(receiver.objects(FilteredNote.self).count == 0)

        // Make public → should trigger full INSERT
        let insertTask = await startListeningForReceiver(table: "FilteredNote", operation: .insert)
        note.isPublic = true
        try await insertTask.value
        #expect(receiver.objects(FilteredNote.self).count == 1)
        #expect(receiver.objects(FilteredNote.self).first?.title == "was-private")
    }

    // =========================================================================
    // Test 5: Runtime filter change triggers reconciliation
    // =========================================================================
    @Test(.timeLimit(.minutes(5)))
    func test_FilteredSync_RuntimeFilterChange() async throws {
        var filter = Lattice.SyncFilter()
        filter.include(FilteredNote.self, where: { $0.isPublic == true })
        sender = try makeSender(syncFilter: filter)
        try await Task.sleep(for: .milliseconds(500))

        // Add one public, one private
        let insertTask1 = await startListeningForReceiver(table: "FilteredNote", operation: .insert)
        let pub = FilteredNote(title: "public", isPublic: true)
        let priv = FilteredNote(title: "private", isPublic: false)
        try sender.add(pub)
        try sender.add(priv)
        try await insertTask1.value
        #expect(receiver.objects(FilteredNote.self).count == 1)

        // Change filter to include all notes → reconciliation sends private note
        let insertTask2 = await startListeningForReceiver(table: "FilteredNote", operation: .insert)
        var newFilter = Lattice.SyncFilter()
        newFilter.include(FilteredNote.self)
        sender.updateSyncFilter(newFilter)
        try await insertTask2.value
        #expect(receiver.objects(FilteredNote.self).count == 2)
    }

    // =========================================================================
    // Test 5b: Narrowing filter triggers reconciliation DELETE
    // =========================================================================
    // QUARANTINED (Jul 8 2026): pre-existing hang — see the note on
    // test_UpdatesSyncCorrectly (EngramTests.swift); verified at bb34cad
    // against remote LatticeCore 0.10.3.
    @Test(.disabled("non-INSERT relay delivery defect, NARROWED by D1b (Jul 11): UPDATE delivery through the ordered TestSyncServer now works (test_UpdatesSyncCorrectly un-quarantined), but this test still hangs idle after the runtime filter update — synchronizer sits at pending=0 with the narrowed filter never producing the expected exclusion. Owner: 1.0 item D2 (filter-update path: update_sync_filter → reconcile/classify)"), .timeLimit(.minutes(5)))
    func test_FilteredSync_RuntimeFilterNarrowing() async throws {
        // Start with filter that includes all notes
        var filter = Lattice.SyncFilter()
        filter.include(FilteredNote.self)
        sender = try makeSender(syncFilter: filter)
        try await Task.sleep(for: .milliseconds(500))

        // Add one public, one private — both should sync
        let insertTask1 = await startListeningForReceiver(table: "FilteredNote", operation: .insert)
        let pub = FilteredNote(title: "public", isPublic: true)
        try sender.add(pub)
        try await insertTask1.value

        let insertTask2 = await startListeningForReceiver(table: "FilteredNote", operation: .insert)
        let priv = FilteredNote(title: "private", isPublic: false)
        try sender.add(priv)
        try await insertTask2.value
        #expect(receiver.objects(FilteredNote.self).count == 2)

        // Narrow filter to public-only → reconciliation sends DELETE for private note
        let deleteTask = await startListeningForReceiver(table: "FilteredNote", operation: .delete)
        var narrowFilter = Lattice.SyncFilter()
        narrowFilter.include(FilteredNote.self, where: { $0.isPublic == true })
        sender.updateSyncFilter(narrowFilter)
        try await deleteTask.value
        #expect(receiver.objects(FilteredNote.self).count == 1)
        #expect(receiver.objects(FilteredNote.self).first?.title == "public")
    }

    // =========================================================================
    // Test 6: nil filter syncs everything (backwards compatible)
    // =========================================================================
    @Test(.timeLimit(.minutes(5)))
    func test_FilteredSync_NilFilterSyncsEverything() async throws {
        sender = try makeSender(syncFilter: nil)
        try await Task.sleep(for: .milliseconds(500))

        let task = await startListeningForReceiver(table: "FilteredNote", operation: .insert)
        let note = FilteredNote(title: "unfiltered", isPublic: false)
        let tag = FilteredTag(name: "unfiltered-tag")
        try sender.add(note)
        try sender.add(tag)
        try await task.value

        // Give a moment for tag to sync too
        try await Task.sleep(for: .seconds(1))
        #expect(receiver.objects(FilteredNote.self).count == 1)
        #expect(receiver.objects(FilteredTag.self).count == 1)
    }

    // =========================================================================
    // Test 7: Empty filter syncs nothing
    // =========================================================================
    @Test(.timeLimit(.minutes(5)))
    func test_FilteredSync_EmptyFilterSyncsNothing() async throws {
        let filter = Lattice.SyncFilter()
        sender = try makeSender(syncFilter: filter)
        try await Task.sleep(for: .milliseconds(500))

        let note = FilteredNote(title: "blocked", isPublic: true)
        try sender.add(note)

        try await assertNothingReceived(table: "FilteredNote")
        #expect(receiver.objects(FilteredNote.self).count == 0)
    }

    // =========================================================================
    // Test 8: Download ignores filter (filter is upload-only)
    // =========================================================================
    @Test(.timeLimit(.minutes(5)))
    func test_FilteredSync_DownloadIgnoresFilter() async throws {
        sender = try makeSender(syncFilter: nil)
        try await Task.sleep(for: .milliseconds(500))

        let task = await startListeningForReceiver(table: "FilteredNote", operation: .insert)
        let note = FilteredNote(title: "from-sender", isPublic: false)
        try sender.add(note)
        try await task.value

        #expect(receiver.objects(FilteredNote.self).count == 1)
        #expect(receiver.objects(FilteredNote.self).first?.title == "from-sender")
    }
}
