import Foundation
import Testing
@testable import Lattice

@Suite("Test relay command ordering")
actor TestSyncServerOrderingTests {
    private enum Order: Sendable, Equatable { case frameFirst, connectFirst }

    @Test(.timeLimit(.minutes(1)))
    func frameBeforeConnectPersistsBeforeCatchUp() async throws {
        try await check(.frameFirst)
    }

    @Test(.timeLimit(.minutes(1)))
    func connectBeforeFrameRegistersBeforeFanout() async throws {
        try await check(.connectFirst)
    }

    private func check(_ order: Order) async throws {
        let stages = SyncTestStageLog(label: "ordering-\(order)", store: "ordering-fixture")
        stages.record("case_entered")
        do {
            try await withTaskCancellationHandler {
                try await check(order, stages: stages)
            } onCancel: {
                stages.record("case_cancelled")
                stages.emit(reason: "ordering_case_cancelled")
            }
        } catch {
            stages.record("case_threw")
            stages.emit(reason: "ordering_case_failed")
            throw error
        }
        // This is a control-flow boundary, not an assertion/pass verdict.
        stages.emit(reason: "ordering_case_finished")
    }

    private func check(_ order: Order, stages: SyncTestStageLog) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stages.record("fixture_created", detail: "directory=\(directory.lastPathComponent)")
        let serverConfig = Lattice.Configuration(fileURL: directory.appendingPathComponent("server.sqlite"))
        let senderPath = directory.appendingPathComponent("sender.sqlite")
        let peerPath = directory.appendingPathComponent("peer.sqlite")
        let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let connects = AsyncStream<Void>.makeStream()
        let frames = AsyncStream<Void>.makeStream()
        let firstFrame = AtomicOnce()
        let pause: @Sendable () async -> Void = {
            stages.record("hook_pause_entered")
            entered.continuation.yield(())
            for await _ in release.stream { break }
            stages.record("hook_pause_returned")
        }
        let hooks = TestSyncServer.Hooks(
            beforePersistence: {
                stages.record("before_persistence")
                if order == .frameFirst && firstFrame.tryFire() { await pause() }
            },
            beforeCatchUp: { count in
                stages.record("before_catchup", count: count)
                if order == .connectFirst && count == 2 { await pause() }
            },
            connectEnqueued: {
                stages.record("connect_enqueued")
                connects.continuation.yield(())
            },
            frameEnqueued: {
                stages.record("frame_enqueued")
                frames.continuation.yield(())
            })
        stages.record("server_open_begin")
        let server = try await TestSyncServer(models: [SimpleSyncObject.self], configuration: serverConfig,
                                              label: "ordered-\(order)", hooks: hooks)
        stages.record("server_open_end", detail: "server_fixture=\(server.diagnostic.id)")
        var testFailure: (any Error)?
        do {
            try await withTaskCancellationHandler {
                stages.record("sender_open_begin")
                let sender = try Lattice(SimpleSyncObject.self, configuration: .init(fileURL: senderPath,
                                        authorizationToken: "sender", wssEndpoint: server.endpoint))
                stages.record("sender_open_end")
                defer {
                    stages.record("sender_close_begin")
                    sender.close()
                    stages.record("sender_close_end")
                }
                stages.record("sender_socket_wait_begin")
                try await server.sockets.waitForCountOrCancellation(1)
                stages.record("sender_socket_wait_end")
                var connectIterator = connects.stream.makeAsyncIterator()
                stages.record("sender_connect_wait_begin")
                try #require(await connectIterator.next() != nil)
                stages.record("sender_connect_wait_end")
                stages.record("peer_open_begin")
                let peer = try Lattice(SimpleSyncObject.self, configuration: .init(fileURL: peerPath))
                stages.record("peer_open_end")
                defer {
                    stages.record("peer_close_begin")
                    peer.close()
                    stages.record("peer_close_end")
                }
                // Retain only scalar phases/counts from the existing seam.
                // The event's original clock joins callback/buffering/query
                // admission to the consumer without retaining row/model data.
                let observer = PayloadObserverDiagnostic(observer: "ordering") { event in
                    stages.record("observer_\(event.stage)", count: event.count,
                                  detail: "event_uptime_ns=\(event.uptime)")
                }
                stages.record("observer_registration_begin")
                let changes = peer._changeStream(diagnostic: observer)
                stages.record("observer_registration_end")
                let object = SimpleSyncObject(value: 731, floatValue: 7.31)
                if order == .frameFirst {
                    stages.record("sender_add_begin")
                    try sender.add(object)
                    stages.record("sender_add_end")
                    var iterator = entered.stream.makeAsyncIterator()
                    stages.record("hook_entered_wait_begin")
                    try #require(await iterator.next() != nil)
                    stages.record("hook_entered_wait_end")
                }
                // Register the observer above before connecting its sync sibling.
                stages.record("connected_peer_open_begin")
                let connectedPeer = try Lattice(SimpleSyncObject.self, configuration: .init(fileURL: peerPath,
                                                 authorizationToken: "peer", wssEndpoint: server.endpoint))
                stages.record("connected_peer_open_end")
                defer {
                    stages.record("connected_peer_close_begin")
                    connectedPeer.close()
                    stages.record("connected_peer_close_end")
                }
                stages.record("peer_connect_wait_begin")
                try #require(await connectIterator.next() != nil)
                stages.record("peer_connect_wait_end")
                if order == .connectFirst {
                    var iterator = entered.stream.makeAsyncIterator()
                    stages.record("hook_entered_wait_begin")
                    try #require(await iterator.next() != nil)
                    stages.record("hook_entered_wait_end")
                    stages.record("sender_add_begin")
                    try sender.add(object)
                    stages.record("sender_add_end")
                    var frameIterator = frames.stream.makeAsyncIterator()
                    stages.record("frame_wait_begin")
                    try #require(await frameIterator.next() != nil)
                    stages.record("frame_wait_end")
                }
                let target = try #require(object.globalId)
                stages.record("hook_release")
                release.continuation.yield(())
                release.continuation.finish()
                stages.record("consumer_wait_begin")
                for try await batch in changes {
                    stages.record("consumer_resumed", count: batch.count)
                    let resolved = batch.compactMap { $0.resolve(isolation: nil, on: peer) }
                    stages.record("consumer_resolved", count: resolved.count)
                    if resolved.contains(where: { $0.globalRowId == target && $0.tableName == "SimpleSyncObject" }) {
                        stages.record("consumer_matched")
                        break
                    }
                    stages.record("consumer_wait_begin")
                }
                stages.record("consumer_loop_end")
                try Task.checkCancellation()
                stages.record("peer_assertions_begin")
                #expect(peer.objects(SimpleSyncObject.self).count == 1)
                #expect(peer.objects(SimpleSyncObject.self).first?.globalId == target)
                #expect(peer.objects(SimpleSyncObject.self).first?.value == 731)
                stages.record("peer_assertions_end")
                // Complete command processing, rather than racing peer fanout
                // against the server's still-running persistence step.
                stages.record("command_join_begin")
                try await server.waitForCommandsForTesting()
                stages.record("command_join_end")
                #expect(server.lattice.objects(SimpleSyncObject.self).count == 1)
                #expect(server.lattice.objects(SimpleSyncObject.self).first?.globalId == target)
                stages.record("body_end")
            } onCancel: {
                // Release the owned async hooks before the explicit join.
                release.continuation.finish()
                entered.continuation.finish()
                connects.continuation.finish()
                frames.continuation.finish()
                server.diagnostic.emit(reason: "ordering_case_cancelled")
            }
        } catch {
            stages.record("body_threw")
            stages.emit(reason: "ordering_case_failed")
            testFailure = error
        }
        release.continuation.finish()
        entered.continuation.finish()
        connects.continuation.finish()
        frames.continuation.finish()
        // Also joins on assertion failure/cancellation. If shutdown itself
        // throws, retain this unique fixture directory for diagnosis.
        stages.record("shutdown_begin")
        try await server.shutdownAndWaitForTesting()
        stages.record("shutdown_end")
        server.diagnostic.emit(reason: "ordering_case_finished")
        stages.record("directory_remove_begin")
        try FileManager.default.removeItem(at: directory)
        stages.record("directory_remove_end")
        if let testFailure { throw testFailure }

    }
}
