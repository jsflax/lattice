import Foundation
import Testing
import Lattice

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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let serverConfig = Lattice.Configuration(fileURL: directory.appendingPathComponent("server.sqlite"))
        let senderPath = directory.appendingPathComponent("sender.sqlite")
        let peerPath = directory.appendingPathComponent("peer.sqlite")
        let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let connects = AsyncStream<Void>.makeStream()
        let frames = AsyncStream<Void>.makeStream()
        let firstFrame = AtomicOnce()
        let pause: @Sendable () async -> Void = {
            entered.continuation.yield(())
            for await _ in release.stream { break }
        }
        let hooks = TestSyncServer.Hooks(
            beforePersistence: {
                if order == .frameFirst && firstFrame.tryFire() { await pause() }
            },
            beforeCatchUp: { count in
                if order == .connectFirst && count == 2 { await pause() }
            },
            connectEnqueued: { connects.continuation.yield(()) },
            frameEnqueued: { frames.continuation.yield(()) })
        let server = try await TestSyncServer(models: [SimpleSyncObject.self], configuration: serverConfig,
                                              label: "ordered-\(order)", hooks: hooks)
        var testFailure: (any Error)?
        do {
            try await withTaskCancellationHandler {
                let sender = try Lattice(SimpleSyncObject.self, configuration: .init(fileURL: senderPath,
                                        authorizationToken: "sender", wssEndpoint: server.endpoint))
                defer { sender.close() }
                try await server.sockets.waitForCountOrCancellation(1)
                var connectIterator = connects.stream.makeAsyncIterator()
                try #require(await connectIterator.next() != nil)
                let peer = try Lattice(SimpleSyncObject.self, configuration: .init(fileURL: peerPath))
                defer { peer.close() }
                let changes = peer.changeStream
                let object = SimpleSyncObject(value: 731, floatValue: 7.31)
                if order == .frameFirst {
                    try sender.add(object)
                    var iterator = entered.stream.makeAsyncIterator()
                    try #require(await iterator.next() != nil)
                }
                // Register the observer above before connecting its sync sibling.
                let connectedPeer = try Lattice(SimpleSyncObject.self, configuration: .init(fileURL: peerPath,
                                                 authorizationToken: "peer", wssEndpoint: server.endpoint))
                defer { connectedPeer.close() }
                try #require(await connectIterator.next() != nil)
                if order == .connectFirst {
                    var iterator = entered.stream.makeAsyncIterator()
                    try #require(await iterator.next() != nil)
                    try sender.add(object)
                    var frameIterator = frames.stream.makeAsyncIterator()
                    try #require(await frameIterator.next() != nil)
                }
                let target = try #require(object.globalId)
                release.continuation.yield(())
                release.continuation.finish()
                for try await batch in changes {
                    let resolved = batch.compactMap { $0.resolve(isolation: nil, on: peer) }
                    if resolved.contains(where: { $0.globalRowId == target && $0.tableName == "SimpleSyncObject" }) { break }
                }
                try Task.checkCancellation()
                #expect(peer.objects(SimpleSyncObject.self).count == 1)
                #expect(peer.objects(SimpleSyncObject.self).first?.globalId == target)
                #expect(peer.objects(SimpleSyncObject.self).first?.value == 731)
                // Complete command processing, rather than racing peer fanout
                // against the server's still-running persistence step.
                try await server.waitForCommandsForTesting()
                #expect(server.lattice.objects(SimpleSyncObject.self).count == 1)
                #expect(server.lattice.objects(SimpleSyncObject.self).first?.globalId == target)
            } onCancel: {
                // Release the owned async hooks before the explicit join.
                release.continuation.finish()
                entered.continuation.finish()
                connects.continuation.finish()
                frames.continuation.finish()
                server.diagnostic.emit(reason: "ordering_case_cancelled")
            }
        } catch {
            testFailure = error
        }
        release.continuation.finish()
        entered.continuation.finish()
        connects.continuation.finish()
        frames.continuation.finish()
        // Also joins on assertion failure/cancellation. If shutdown itself
        // throws, retain this unique fixture directory for diagnosis.
        try await server.shutdownAndWaitForTesting()
        server.diagnostic.emit(reason: "ordering_case_finished")
        try FileManager.default.removeItem(at: directory)
        if let testFailure { throw testFailure }

    }
}
