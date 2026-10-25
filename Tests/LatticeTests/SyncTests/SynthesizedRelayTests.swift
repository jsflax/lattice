import Foundation
import Lattice
@testable import LatticeServerKit
import NIOCore
import Testing
import Vapor

@Model private final class SynthesizedRelayRecord {
    var content: String = ""
    var tombstone: Bool = false

    init(content: String) { self.content = content }
}

/// Retains the actual socket bytes. Assertions and native apply never rebuild
/// the relay's frames, so both outbound encoders are part of the regression.
private final class SnapshotFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [Data] = []
    private var connection: WebSocket?

    func attach(_ socket: WebSocket) {
        lock.withLock { connection = socket }
        socket.onBinary { [weak self] _, buffer in
            guard let self else { return }
            self.lock.withLock { self.received.append(Data(buffer: buffer)) }
        }
    }

    var frames: [Data] { lock.withLock { received } }
    var isOpen: Bool { lock.withLock { connection?.isClosed == false } }

    func close() async { try? await lock.withLock { connection }?.close().get() }
}

private final class SnapshotPipeline: @unchecked Sendable {
    private let lock = NSLock()
    private var activated = false
    private var drained = false
    private var pushed: Set<UUID> = []
    private var caughtUp: Set<UUID> = []

    func record(_ event: ObserverSendBoundaryProbe.Pipeline.Event) {
        lock.withLock {
            if event.stage == .activated { activated = true }
            if activated, event.stage == .pageReadEnd, event.count == 0 { drained = true }
        }
    }

    func record(_ route: ObserverSendBoundaryProbe.Route, ids: [UUID?]) {
        lock.withLock {
            if route == .push { pushed.formUnion(ids.compactMap { $0 }) }
            if route == .catchup { caughtUp.formUnion(ids.compactMap { $0 }) }
        }
    }

    var activatedAndDrained: Bool { lock.withLock { activated && drained } }
    func contains(_ ids: Set<UUID>, route: ObserverSendBoundaryProbe.Route) -> Bool {
        lock.withLock { ids.isSubset(of: route == .push ? pushed : caughtUp) }
    }
}

@Suite("Synthesized relay provenance", .serialized)
struct SynthesizedRelayTests {
    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "The bounded relay condition must complete")
    }

    private func entries(_ frame: Data) throws -> [[String: Any]] {
        let root = try #require(JSONSerialization.jsonObject(with: frame) as? [String: Any])
        return root["auditLog"] as? [[String: Any]] ?? []
    }

    private func ids(_ frames: [Data]) -> Set<UUID> {
        Set(frames.flatMap { (try? entries($0)) ?? [] }.compactMap {
            ($0["globalId"] as? String).flatMap(UUID.init(uuidString:))
        })
    }

    private func connect(_ app: Application, port: Int, checkpoint: UUID) async throws -> SnapshotFrames {
        let collector = SnapshotFrames()
        var configuration = WebSocketClient.Configuration()
        configuration.maxFrameSize = 1 << 20
        try await WebSocket.connect(
            to: "ws://127.0.0.1:\(port)/snapshot?last-event-id=\(checkpoint.uuidString)",
            configuration: configuration, on: app.eventLoopGroup
        ) { collector.attach($0) }.get()
        return collector
    }

    /// Reproduces a stale peer's synthesized full-row upload being recorded
    /// as UPDATE on a relay that already has newer values. The observer pump
    /// and a later catch-up must retain insert-if-absent provenance on onward
    /// hops. A third, absent row still hydrates from its synthesized INSERT.
    @Test(.timeLimit(.minutes(1)))
    func pushAndCatchupPreserveNewerRowsAndTombstones() async throws {
        let parent = ProcessInfo.processInfo.environment["LATTICE_TEST_TMPDIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let root = parent.appendingPathComponent("synthesized-relay-\(UUID().uuidString)", isDirectory: true)
        let storage = root.appendingPathComponent("relay", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let donor = try Lattice(SynthesizedRelayRecord.self,
            configuration: .init(fileURL: root.appendingPathComponent("donor.sqlite")))
        defer { donor.close() }
        for name in ["old edit", "old live row", "newly hydrated"] {
            try donor.add(SynthesizedRelayRecord(content: name))
        }
        let original = Array(donor.eventsAfter(globalId: nil))
        try #require(original.count == 3)
        let rowIDs = try original.map { try #require($0.globalRowId) }
        let initialFrame = try JSONEncoder().encode(ServerSentEvent.auditLog(Array(original.prefix(2))))

        // The fixture is a native snapshot envelope, before the Swift relay
        // has touched it. Adding the true flag directly avoids testing the
        // broken Swift encoder on the upload side as well as the relay side.
        var snapshots = try entries(JSONEncoder().encode(ServerSentEvent.auditLog(original)))
        let snapshotIDs = (0..<3).map { _ in UUID() }
        for index in snapshots.indices {
            snapshots[index]["globalId"] = snapshotIDs[index].uuidString.lowercased()
            snapshots[index]["synthesized"] = true
        }
        let upload = try JSONSerialization.data(withJSONObject: ["kind": "auditLog", "auditLog": snapshots])

        let cloud = try Lattice(SynthesizedRelayRecord.self,
            configuration: .init(fileURL: storage.appendingPathComponent("snapshot.sqlite")))
        defer { cloud.close() }
        _ = try cloud.receive(initialFrame)
        let edit = try #require(cloud.objects(SynthesizedRelayRecord.self).where { $0.globalId == rowIDs[0] }.first)
        edit.content = "newer edit"
        let tombstone = try #require(cloud.objects(SynthesizedRelayRecord.self).where { $0.globalId == rowIDs[1] }.first)
        tombstone.tombstone = true
        let history = Array(cloud.eventsAfter(globalId: nil))
        let checkpoint = try #require(history.last?.globalId)
        let newerState = try JSONEncoder().encode(ServerSentEvent.auditLog(history))

        let pipeline = SnapshotPipeline()
        let probe = ObserverSendBoundaryProbe(channelID: "snapshot",
            pipeline: ObserverSendBoundaryProbe.Pipeline { event, _ in
                pipeline.record(event)
                return nil
            }) { route, ids, _ in pipeline.record(route, ids: ids) }
        var environment = Environment.testing
        environment.arguments = ["vapor"]
        let app = try await Application.make(environment)
        app.http.server.configuration.port = 0
        app.http.server.configuration.shutdownTimeout = .milliseconds(500)
        let options = SyncObserverPush(copying: SyncObserverPush(reconcileInterval: nil), sendBoundaryProbe: probe)
        let handle = Lattice.configureSyncRelay(on: app.routes, path: ["snapshot"],
            for: [SynthesizedRelayRecord.self], storageURL: storage, observerPush: options,
            channelExtractor: { _ in SyncChannel(id: "snapshot", userId: UUID()) })
        var collectors: [SnapshotFrames] = []
        do {
            try #require(handle.pushManager != nil)
            try await app.startup()
            let port = try #require(app.http.server.shared.localAddress?.port)
            let live = try await connect(app, port: port, checkpoint: checkpoint)
            collectors.append(live)
            // Catch-up has no pending entries. Wait for actual activation and
            // its empty pump SELECT before uploading; there is no timer fallback.
            try await eventually { pipeline.activatedAndDrained }
            #expect(live.frames.isEmpty)
            #expect(Set(try cloud.receive(upload)) == Set(snapshotIDs))
            #expect(edit.content == "newer edit")
            #expect(tombstone.tombstone)
            let expected = Set(snapshotIDs)
            try await eventually { expected.isSubset(of: ids(live.frames)) }
            #expect(live.isOpen)
            #expect(pipeline.contains(expected, route: .push))

            // A fresh connection resumes immediately before those same rows,
            // so the second encoder emits only the three snapshot audits.
            let catchup = try await connect(app, port: port, checkpoint: checkpoint)
            collectors.append(catchup)
            try await eventually { expected.isSubset(of: ids(catchup.frames)) }
            #expect(pipeline.contains(expected, route: .catchup))

            for (index, collector) in [live, catchup].enumerated() {
                let frames = collector.frames
                #expect(ids(frames) == expected)
                let wire = try frames.flatMap { try entries($0) }
                #expect(wire.count == 3)
                for entry in wire { #expect(entry["synthesized"] as? Bool == true) }
                #expect(wire.filter { $0["operation"] as? String == "UPDATE" }.count == 2)
                #expect(wire.filter { $0["operation"] as? String == "INSERT" }.count == 1)

                let receiver = try Lattice(SynthesizedRelayRecord.self,
                    configuration: .init(fileURL: root.appendingPathComponent("receiver-\(index).sqlite")))
                defer { receiver.close() }
                _ = try receiver.receive(newerState)
                var acknowledgements: Set<UUID> = []
                for frame in frames { acknowledgements.formUnion(try receiver.receive(frame)) }
                #expect(acknowledgements == expected)
                let receivedEdit = try #require(receiver.objects(SynthesizedRelayRecord.self).where { $0.globalId == rowIDs[0] }.first)
                let receivedTombstone = try #require(receiver.objects(SynthesizedRelayRecord.self).where { $0.globalId == rowIDs[1] }.first)
                let hydrated = try #require(receiver.objects(SynthesizedRelayRecord.self).where { $0.globalId == rowIDs[2] }.first)
                #expect(receivedEdit.content == "newer edit", "A relayed snapshot must not roll back a newer edit")
                #expect(receivedTombstone.tombstone, "A relayed snapshot must not resurrect a tombstone")
                #expect(hydrated.content == "newly hydrated")
                #expect(receiver.objects(SynthesizedRelayRecord.self).count == 3)
            }
        } catch {
            for collector in collectors { await collector.close() }
            try? await app.asyncShutdown()
            throw error
        }
        for collector in collectors { await collector.close() }
        try await app.asyncShutdown()
    }
}
