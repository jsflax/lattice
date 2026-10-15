import Foundation
import Testing
import Vapor
import WebSocketKit
import NIOConcurrencyHelpers
import Lattice
@testable import LatticeServerKit

private enum OrdinaryRouteFailure: Error { case timeout, overflow, connect }

/// Bounded raw client observes actual native-issued frames. Its manually sent
/// receipt is a delivery-protocol test input, not proof of native receiver commit;
/// the separate native/client receiver suite owns that qualification.
private final class OrdinaryRouteClient: @unchecked Sendable {
    struct State {
        var socket: WebSocket?
        var closed = false, connectFailed = false, overflow = false, closing = false
        var frames: [Data] = []
        var bytes = 0
    }
    let state = NIOLockedValueBox(State())
    func attach(_ socket: WebSocket) {
        let closing = state.withLockedValue { $0.socket = socket; return $0.closing }
        socket.onBinary { [self] _, buffer in
            let close = state.withLockedValue { value in
                guard value.frames.count < 64, buffer.readableBytes <= 8_388_608 - value.bytes else {
                    value.overflow = true; return true
                }
                value.bytes += buffer.readableBytes; value.frames.append(Data(buffer: buffer)); return false
            }
            if close { socket.close(code: .policyViolation, promise: nil) }
        }
        socket.onClose.whenComplete { [self] _ in state.withLockedValue { $0.closed = true; $0.socket = nil } }
        if closing { socket.close(promise: nil) }
    }
    var frames: [Data] { state.withLockedValue { $0.frames } }
    func bodies() -> [[String: Any]] {
        frames.compactMap { ((try? JSONSerialization.jsonObject(with: $0)) as? [String: Any])?["latticeOrdinarySync"] as? [String: Any] }
    }
    func headers() -> [[String: Any]] { bodies().filter { $0["kind"] as? String == "cut" } }
    func complete(_ ordinal: Int) -> Bool {
        let all = bodies(), headers = all.filter { $0["kind"] as? String == "cut" }
        guard ordinal < headers.count, let rawPages = headers[ordinal]["pages"] as? String, let pages = Int(rawPages),
              let cut = headers[ordinal]["cut"] as? String else { return false }
        return all.filter { $0["kind"] as? String == "page" && $0["cut"] as? String == cut }.count == pages
    }
    func textValues(_ ordinal: Int, table: String, column: String) -> [String] {
        let all = bodies(), headers = all.filter { $0["kind"] as? String == "cut" }
        guard ordinal < headers.count, let cut = headers[ordinal]["cut"] as? String,
              let tables = headers[ordinal]["tables"] as? [[String: Any]],
              let columns = tables.first(where: { $0["name"] as? String == table })?["columns"] as? [String],
              let position = columns.firstIndex(of: column) else { return [] }
        return all.filter { $0["kind"] as? String == "page" && $0["cut"] as? String == cut }.flatMap { page in
            (page["records"] as? [[String: Any]] ?? []).compactMap { record -> String? in
                guard let row = record["row"] as? [String: Any], row["table"] as? String == table,
                      let values = row["values"] as? [[Any]], position < values.count,
                      values[position].count == 2, values[position][0] as? String == "text" else { return nil }
                return values[position][1] as? String
            }
        }
    }
    func send(_ bytes: Data) throws {
        guard let socket = state.withLockedValue({ $0.socket }) else { throw OrdinaryRouteFailure.connect }
        socket.send(ByteBuffer(data: bytes))
    }
    func request() throws {
        try send(JSONSerialization.data(withJSONObject: ["latticeOrdinarySync": ["version": 2, "kind": "request", "request": UUID().uuidString]]))
    }
    func receipt(_ ordinal: Int, wrong: Bool = false) throws {
        let header = try #require(headers().dropFirst(ordinal).first)
        var body: [String: Any] = ["version": 2, "kind": "receipt"]
        for key in ["source", "epoch", "cut", "contentDigest"] { body[key] = try #require(header[key]) }
        if wrong { body["contentDigest"] = String(repeating: "0", count: 64) }
        try send(JSONSerialization.data(withJSONObject: ["latticeOrdinarySync": body]))
    }
    func close() { state.withLockedValue { $0.closing = true; return $0.socket }?.close(promise: nil) }
}

private func ordinaryRouteWait(_ predicate: @escaping @Sendable () -> Bool) async throws {
    let end = ContinuousClock.now.advanced(by: .seconds(10))
    while ContinuousClock.now < end {
        if predicate() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    guard predicate() else { throw OrdinaryRouteFailure.timeout }
}

private final class OrdinaryRouteHarness: @unchecked Sendable {
    let app: Application
    let directory: URL
    let writer: Lattice
    let setupCount = NIOLockedValueBox(0)
    let clients = NIOLockedValueBox<[OrdinaryRouteClient]>([])
    var port = 0
    init(app: Application, directory: URL, writer: Lattice) {
        self.app = app; self.directory = directory; self.writer = writer
    }
    func connect(path: String = "sync") async throws -> OrdinaryRouteClient {
        let client = OrdinaryRouteClient()
        clients.withLockedValue { $0.append(client) }
        var configuration = WebSocketClient.Configuration(); configuration.maxFrameSize = 4_194_304
        WebSocket.connect(to: "ws://127.0.0.1:\(port)/\(path)", configuration: configuration, on: app.eventLoopGroup) {
            client.attach($0)
        }.whenFailure { _ in client.state.withLockedValue { $0.connectFailed = true } }
        try await ordinaryRouteWait { client.state.withLockedValue { $0.socket != nil || $0.connectFailed || $0.closed } }
        guard !client.state.withLockedValue({ $0.connectFailed || $0.closed }) else { throw OrdinaryRouteFailure.connect }
        return client
    }
}

private func withOrdinaryRoute(push: Bool, secondaryMount: Bool = false, policy: OrdinarySyncPolicy = .orderedRequired,
                               seed: Bool = false, schema: [any Lattice.Model.Type] = [SimpleSyncObject.self], _ body: (OrdinaryRouteHarness) async throws -> Void) async throws {
    // Retain this UUID-owned directory for the process lifetime; teardown never
    // unlinks a live SQLite file beneath a queued IO destructor.
    let directory = FileManager.default.temporaryDirectory.appending(path: "ordinary-relay-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let writer = try Lattice(for: schema, configuration: .init(fileURL: directory.appending(path: "fixture.sqlite")))
    defer { let close = writer.closeChecked(); #expect(!close.failed && !close.cleanupFailed && close.cleanupComplete) }
    if seed { try writer.add(SimpleSyncObject(value: 1, floatValue: 1)) }
    var environment = try Environment.detect(); environment.arguments = ["vapor"]
    let app = try await Application.make(environment)
    let harness = OrdinaryRouteHarness(app: app, directory: directory, writer: writer)
    app.http.server.configuration.port = 0
    app.http.server.configuration.shutdownTimeout = .seconds(1)
    let setupCount = harness.setupCount
    let hooks = RelayIngressTestHooks(beforeAsyncSetup: {}, didBufferFrame: { _ in },
                                     didFinishAsyncSetup: { setupCount.withLockedValue { $0 += 1 } })
    RelayIngressTesting.install(hooks, for: directory)
    let user = UUID()
    _ = Lattice.configureSyncRelay(on: app.routes, path: ["sync"], for: schema, storageURL: directory,
            observerPush: push ? .init(reconcileInterval: nil) : nil, ordinarySyncPolicy: policy,
            channelExtractor: { _ in .init(id: "fixture", userId: user) })
    if secondaryMount {
        _ = Lattice.configureSyncRelay(on: app.routes, path: ["sync-other"], for: schema, storageURL: directory,
            ordinarySyncPolicy: policy, channelExtractor: { _ in .init(id: "fixture", userId: user) })
    }
    RelayIngressTesting.remove(hooks, for: directory)
    var failure: (any Error)?
    do {
        try await app.startup()
        harness.port = try #require(app.http.server.shared.localAddress?.port)
        try await body(harness)
    } catch { failure = error }
    let clients = harness.clients.withLockedValue { $0 }
    clients.forEach { $0.close() }
    do {
        try await ordinaryRouteWait { clients.allSatisfy { $0.state.withLockedValue { $0.closed || $0.connectFailed } } }
    } catch { if failure == nil { failure = error } else { Issue.record("ordinary route client cleanup also failed") } }
    do { try await app.asyncShutdown() }
    catch { if failure == nil { failure = error } else { Issue.record("ordinary route application cleanup also failed") } }
    if let failure { throw failure }
}

@Suite(.serialized, .timeLimit(.minutes(2)))
struct RelayOrdinaryRouteTests {
    @Test func catchupWaitsForNegotiationAndSendsAnActualIssuedCut() async throws {
        try await withOrdinaryRoute(push: false, seed: true) { harness in
            let client = try await harness.connect()
            try await ordinaryRouteWait { harness.setupCount.withLockedValue { $0 } == 1 }
            #expect(client.frames.isEmpty)
            try client.request()
            try await ordinaryRouteWait { client.complete(0) }
            let bodies = client.bodies()
            #expect(bodies.first?["kind"] as? String == "offer")
            #expect(client.headers().count == 1)
            #expect(client.headers().first?["rows"] as? String == "1")
            #expect(client.frames.count == bodies.count, "ordered mount never emits legacy audit/floor frames")
            try client.receipt(0)
        }
    }

    @Test func observerPushRetainsOneCutAndCoalescesCommittedChangesUntilReceipt() async throws {
        try await withOrdinaryRoute(push: true, seed: true) { harness in
            let client = try await harness.connect()
            try await ordinaryRouteWait { harness.setupCount.withLockedValue { $0 } == 1 }
            try client.request()
            try await ordinaryRouteWait { client.complete(0) }
            try harness.writer.add(SimpleSyncObject(value: 2, floatValue: 2))
            try harness.writer.add(SimpleSyncObject(value: 3, floatValue: 3))
            // Actual watcher observer delivery is asynchronous. A native IO lane
            // barrier is not a substitute for the later received row oracle.
            #expect(client.headers().count == 1)
            try client.receipt(0)
            try await ordinaryRouteWait {
                client.complete(1) && client.headers().last?["rows"] as? String == "3"
            }
            #expect(client.frames.count == client.bodies().count)
            try client.receipt(1)
        }
    }

    @Test func negotiatedRequiredModeRefusesUploadWithoutOriginalObservation() async throws {
        try await withOrdinaryRoute(push: false) { harness in
            let peer = try await harness.connect(), uploader = try await harness.connect()
            try await ordinaryRouteWait { harness.setupCount.withLockedValue { $0 } == 2 }
            try peer.request(); try uploader.request()
            try await ordinaryRouteWait { peer.complete(0) && uploader.complete(0) }
            try peer.receipt(0); try uploader.receipt(0)
            let donor = try Lattice(SimpleSyncObject.self, configuration: .init(fileURL: harness.directory.appending(path: "legacy-upload.sqlite")))
            defer { let close = donor.closeChecked(); #expect(!close.failed && !close.cleanupFailed && close.cleanupComplete) }
            try donor.add(SimpleSyncObject(value: 7, floatValue: 7))
            let unobserved = try JSONEncoder().encode(ServerSentEvent.auditLog(Array(donor.eventsAfter(globalId: nil))))
            let previous = uploader.frames.count
            try uploader.send(unobserved)
            try await ordinaryRouteWait { uploader.state.withLockedValue { $0.closed } }
            #expect(harness.writer.count(SimpleSyncObject.self) == 0)
            #expect(peer.headers().count == 1)
            #expect(uploader.frames.count == previous, "refused input earns neither ACK nor canonical cut")
        }
    }

    @Test func noHistoryUpdatePublishesActualCurrentValueThroughOrderedPush() async throws {
        try await withOrdinaryRoute(push: true, schema: [StreamedMessage.self]) { harness in
            let message = StreamedMessage(); message.author = "fixture"; message.text = "first"
            try harness.writer.add(message)
            let client = try await harness.connect()
            try await ordinaryRouteWait { harness.setupCount.withLockedValue { $0 } == 1 }
            try client.request()
            try await ordinaryRouteWait { client.complete(0) }
            #expect(client.textValues(0, table: "StreamedMessage", column: "text") == ["first"])
            harness.writer.transaction { message.text = "current text omitted from historical payload" }
            let update = try #require(harness.writer.objects(AuditLog.self).snapshot().last {
                $0.tableName == "StreamedMessage" && $0.operation == .update
            })
            #expect(update.changedFieldsNames?.contains("text") == true)
            if let historicalValue = update.changedFields["text"] {
                if case .null = historicalValue {} else { Issue.record("NoHistory update unexpectedly retained a value") }
            }
            try client.receipt(0)
            try await ordinaryRouteWait {
                client.complete(1) && client.textValues(1, table: "StreamedMessage", column: "text") == ["current text omitted from historical payload"]
            }
            #expect(client.frames.count == client.bodies().count)
            try client.receipt(1)
        }
    }

    @Test func generatedListMutationPublishesNewLogicalRowsWithoutChangingRootCount() async throws {
        try await withOrdinaryRoute(push: true, schema: [SyncParent.self]) { harness in
            let parent = SyncParent(name: "parent"), child = SyncChild(name: "child")
            try harness.writer.add(parent); try harness.writer.add(child)
            let client = try await harness.connect()
            try await ordinaryRouteWait { harness.setupCount.withLockedValue { $0 } == 1 }
            try client.request()
            try await ordinaryRouteWait { client.complete(0) }
            #expect(client.headers().first?["rows"] as? String == "2")
            #expect(parent.children.count == 0)
            harness.writer.transaction { parent.children.append(child) }
            #expect(harness.writer.count(SyncParent.self) == 1 && harness.writer.count(SyncChild.self) == 1)
            #expect(parent.children.count == 1)
            try client.receipt(0)
            try await ordinaryRouteWait { client.complete(1) && client.headers().last?["rows"] as? String == "3" }
            #expect(client.textValues(1, table: "SyncParent", column: "name") == ["parent"])
            #expect(client.textValues(1, table: "SyncChild", column: "name") == ["child"])
            #expect(client.frames.count == client.bodies().count)
            try client.receipt(1)
        }
    }

    @Test func requiredUploadBeforeNegotiationRefusesWithoutApplyingOrAcknowledging() async throws {
        try await withOrdinaryRoute(push: false) { harness in
            let donor = try Lattice(SimpleSyncObject.self, configuration: .init(fileURL: harness.directory.appending(path: "early-donor.sqlite")))
            defer { let close = donor.closeChecked(); #expect(!close.failed && !close.cleanupFailed && close.cleanupComplete) }
            try donor.add(SimpleSyncObject(value: 9, floatValue: 9))
            let upload = try JSONEncoder().encode(ServerSentEvent.auditLog(Array(donor.eventsAfter(globalId: nil))))
            let client = try await harness.connect()
            try await ordinaryRouteWait { harness.setupCount.withLockedValue { $0 } == 1 }
            try client.send(upload)
            try await ordinaryRouteWait { client.state.withLockedValue { $0.closed } }
            #expect(harness.writer.count(SimpleSyncObject.self) == 0)
            #expect(client.frames.isEmpty, "an upload cannot implicitly negotiate or earn an ACK before admission")
        }
    }

    @Test func legacyMountRefusesReservedRequestAndWrongReceiptClosesOrderedMount() async throws {
        try await withOrdinaryRoute(push: false, policy: .legacyProvisional) { harness in
            let client = try await harness.connect(); try client.request()
            try await ordinaryRouteWait { client.state.withLockedValue { $0.closed } }
            #expect(client.headers().isEmpty)
        }
        try await withOrdinaryRoute(push: false, seed: true) { harness in
            let client = try await harness.connect(); try client.request()
            try await ordinaryRouteWait { client.complete(0) }
            try client.receipt(0, wrong: true)
            try await ordinaryRouteWait { client.state.withLockedValue { $0.closed } }
            #expect(client.headers().count == 1)
        }
    }
}


extension RelayOrdinaryRouteTests {
    @Test func exactObservedUploadCrossesRealSocketBridgeAndProducesCommittedSourceOriginal() async throws {
        try await withOrdinaryRoute(push: false) { harness in
            let peer = try await harness.connect(), uploader = try await harness.connect()
            try await ordinaryRouteWait { harness.setupCount.withLockedValue { $0 } == 2 }
            try peer.request(); try uploader.request()
            try await ordinaryRouteWait { peer.complete(0) && uploader.complete(0) }
            let offer = try #require(uploader.bodies().first { $0["kind"] as? String == "offer" })
            #expect((offer["uploadObservation"] as? NSNumber)?.intValue == 1)
            try peer.receipt(0); try uploader.receipt(0)
            let donor = try Lattice(SimpleSyncObject.self, configuration: .init(fileURL: harness.directory.appending(path: "exact-uploader.sqlite")))
            defer { let close = donor.closeChecked(); #expect(!close.failed && !close.cleanupFailed && close.cleanupComplete) }
            try donor.add(SimpleSyncObject(value: 17, floatValue: 1.25))
            // The real local capture provides observed pre-late-binding names.
            // The upload keeps only passive membership: none of its canonical
            // source/epoch/cut/digest fields crosses the upload boundary.
            let local = try donor.captureOrdinarySyncExport(); var originals: [[String: Any]] = []
            for page in 1..<local.frameCount {
                let root = try #require(JSONSerialization.jsonObject(with: local.frame(at: page)) as? [String: Any])
                let body = try #require(root["latticeOrdinarySync"] as? [String: Any])
                for record in body["records"] as? [[String: Any]] ?? [] {
                    guard var entry = record["original"] as? [String: Any], let observed = record["originalDescriptor"] as? [String: Any] else { continue }
                    entry["uploadOriginal"] = ["version": 1, "fields": try #require(observed["fields"]), "names": try #require(observed["names"])]
                    entry["deliveryVersion"] = "0"
                    originals.append(entry)
                }
            }
            #expect(originals.count == 1)
            let expectedID = try #require(originals.first?["globalId"] as? String)
            let expectedTimestamp = try #require(originals.first?["timestamp"] as? String)
            let bytes = try JSONSerialization.data(withJSONObject: ["latticeOrdinarySync": ["version": 2, "kind": "upload", "auditLog": originals]])
            try uploader.send(bytes)
            try await ordinaryRouteWait { peer.complete(1) }
            try await ordinaryRouteWait {
                uploader.bodies().contains { body in
                    body["kind"] as? String == "uploadAck" && (body["accepted"] as? [[String: String]]) == [["globalId": expectedID, "deliveryVersion": "0"]]
                }
            }
            #expect(harness.writer.count(SimpleSyncObject.self) == 1)
            #expect(peer.headers().last?["rows"] as? String == "1")
            let records = peer.bodies().filter { $0["kind"] as? String == "page" }.flatMap { $0["records"] as? [[String: Any]] ?? [] }
            let retained = try #require(records.first { ($0["original"] as? [String: Any])?["globalId"] as? String == expectedID })
            #expect((retained["original"] as? [String: Any])?["timestamp"] as? String == expectedTimestamp)
            #expect(retained["originalDescriptor"] != nil)
            #expect(peer.frames.count == peer.bodies().count)
            try peer.receipt(1)
        }
    }
}


extension RelayOrdinaryRouteTests {
    private func duplicateRepair(push: Bool, secondMount: Bool) async throws {
        try await withOrdinaryRoute(push: push, secondaryMount: secondMount) { harness in
            let id = UUID().uuidString
            let original: [String: Any] = ["id": 0, "globalId": id, "tableName": "SimpleSyncObject", "operation": "INSERT",
                "rowId": 0, "globalRowId": UUID().uuidString, "timestamp": "2026-09-30T12:00:00.123Z",
                "changedFields": ["value": ["kind": 0, "value": 73], "floatValue": ["kind": 5, "value": 1.25]],
                "changedFieldsNames": ["value", "floatValue"], "isFromRemote": false, "isSynchronized": false,
                "uploadOriginal": ["version": 1, "fields": ["floatValue", "value"], "names": ["value", "floatValue"]],
                "deliveryVersion": "0"]
            let data = try JSONSerialization.data(withJSONObject: ["latticeOrdinarySync": ["version": 2, "kind": "upload", "auditLog": [original]]])
            let first = try harness.writer.receiveOrdinarySyncUploadWithAcknowledgment(data)
            #expect(first.ids == [UUID(uuidString: id)!])
            let uploader = try await harness.connect(), peer = try await harness.connect(path: secondMount ? "sync-other" : "sync")
            try await ordinaryRouteWait { harness.setupCount.withLockedValue { $0 } == 2 }
            try uploader.request(); try peer.request()
            try await ordinaryRouteWait { uploader.complete(0) && peer.complete(0) }
            for client in [uploader, peer] {
                let offer = try #require(client.bodies().first { $0["kind"] as? String == "offer" })
                #expect((offer["uploadAcknowledgment"] as? NSNumber)?.intValue == 1)
                try client.receipt(0)
            }
            try uploader.send(data)
            try await ordinaryRouteWait { uploader.complete(1) && peer.complete(1) }
            let auditCount = harness.writer.count(AuditLog.self)
            #expect(harness.writer.count(SimpleSyncObject.self) == 1)
            for client in [uploader, peer] { try client.receipt(1) }
            // Exact retry performs no new logical mutation. Both the uploader
            // and another mount/push peer still need an authoritative current
            // cut; a row observer event cannot supply this wake.
            try uploader.send(data)
            try await ordinaryRouteWait { uploader.complete(2) && peer.complete(2) }
            try await ordinaryRouteWait { uploader.bodies().filter { $0["kind"] as? String == "uploadAck" }.count == 2 }
            let acks = uploader.bodies().filter { $0["kind"] as? String == "uploadAck" }
            #expect(acks.allSatisfy { ($0["accepted"] as? [[String: String]]) == [["globalId": id, "deliveryVersion": "0"]] })
            #expect(harness.writer.count(SimpleSyncObject.self) == 1 && harness.writer.count(AuditLog.self) == auditCount)
            for client in [uploader, peer] {
                #expect(client.headers().count == 3)
                #expect(client.headers().last?["rows"] as? String == "1")
                #expect(client.frames.count == client.bodies().count, "no legacy ACK substitutes for version acceptance")
                try client.receipt(2)
            }
        }
    }
    @Test func duplicateOriginalRepairsUploaderAndPeerWithoutPush() async throws { try await duplicateRepair(push: false, secondMount: false) }
    @Test func duplicateOriginalRepairsUploaderAndPeerWithPush() async throws { try await duplicateRepair(push: true, secondMount: false) }
    @Test func duplicateOriginalRepairsAnotherSameFileMountWithoutObserver() async throws { try await duplicateRepair(push: false, secondMount: true) }

    @Test func requiredModeRefusesLegacyAcknowledgmentWithoutSettlingSourceOriginal() async throws {
        try await withOrdinaryRoute(push: false, seed: true) { harness in
            let original = try #require(harness.writer.objects(AuditLog.self).snapshot().first)
            #expect(!original.isSynchronized)
            let client = try await harness.connect(); try client.request()
            try await ordinaryRouteWait { client.complete(0) }; try client.receipt(0)
            let originalID = try #require(original.globalId)
            try client.send(JSONEncoder().encode(ServerSentEvent.ack([originalID])))
            try await ordinaryRouteWait { client.state.withLockedValue { $0.closed } }
            let current = try #require(harness.writer.objects(AuditLog.self).snapshot().first { $0.globalId == original.globalId })
            #expect(!current.isSynchronized)
            #expect(harness.writer.count(SimpleSyncObject.self) == 1)
        }
    }
}


extension RelayOrdinaryRouteTests {
    @Test func eightActualSocketsQueueCutsInFIFOOrderAndRetainCommittedValues() async throws {
        try await withOrdinaryRoute(push: true, seed: true) { harness in
            let budget = RelayOrdinaryBudget()
            let key = FileWatchManager.canonicalKey(for: harness.directory.appending(path: "fixture.sqlite"))
            try RelayOrdinaryBudgetTesting.install(budget, for: key)
            defer { RelayOrdinaryBudgetTesting.remove(budget, for: key) }
            var clients: [OrdinaryRouteClient] = []
            for index in 0..<8 {
                let client = try await harness.connect(); clients.append(client)
                try client.request()
                if index < 4 { try await ordinaryRouteWait { client.complete(0) } }
                else { try await ordinaryRouteWait { budget.waiting.queuedCuts == index - 3 } }
            }
            let peers = clients
            #expect(budget.snapshot.cuts == 4 && budget.waiting.queuedCuts == 4)
            #expect(peers.dropFirst(4).allSatisfy { $0.headers().isEmpty && !$0.state.withLockedValue { $0.closed } })
            try harness.writer.add(SimpleSyncObject(value: 2, floatValue: 2))
            // Every old holder is dirty, but its next cut must queue behind the
            // four real waiting sockets instead of reacquiring ahead of them.
            for index in 0..<4 {
                try peers[index].receipt(0)
                let recipient = peers[index + 4]
                try await ordinaryRouteWait { recipient.complete(0) }
                #expect(recipient.headers().last?["rows"] as? String == "2")
                #expect(peers[index].headers().count == 1)
                #expect(!recipient.state.withLockedValue { $0.closed || $0.overflow })
                #expect(budget.snapshot.cuts <= 4 && budget.snapshot.stagingBytes <= 33_554_432)
            }
            for client in peers { client.close() }
            try await ordinaryRouteWait {
                peers.allSatisfy { $0.state.withLockedValue { $0.closed } } && budget.snapshot.endpoints == 0
                    && budget.snapshot.cuts == 0 && budget.snapshot.staging == 0
                    && budget.waiting.queuedCuts == 0 && budget.waiting.queuedStaging == 0
            }
        }
    }

    @Test func closingActualWaitingAndHoldingSocketsSettlesWithoutAdmittingTheClosedOwner() async throws {
        try await withOrdinaryRoute(push: false, seed: true) { harness in
            let budget = RelayOrdinaryBudget()
            let key = FileWatchManager.canonicalKey(for: harness.directory.appending(path: "fixture.sqlite"))
            try RelayOrdinaryBudgetTesting.install(budget, for: key)
            defer { RelayOrdinaryBudgetTesting.remove(budget, for: key) }
            var clients: [OrdinaryRouteClient] = []
            for index in 0..<8 {
                let client = try await harness.connect(); clients.append(client); try client.request()
                if index < 4 { try await ordinaryRouteWait { client.complete(0) } }
                else { try await ordinaryRouteWait { budget.waiting.queuedCuts == index - 3 } }
            }
            let peers = clients
            peers[4].close()
            try await ordinaryRouteWait { peers[4].state.withLockedValue { $0.closed } && budget.waiting.queuedCuts == 3 }
            peers[0].close() // Actual connection retirement drops its issued native cut.
            try await ordinaryRouteWait { peers[0].state.withLockedValue { $0.closed } && peers[5].complete(0) }
            #expect(peers[4].headers().isEmpty)
            #expect(peers[6].headers().isEmpty && peers[7].headers().isEmpty)
            #expect(budget.snapshot.cuts == 4)
            for client in peers { client.close() }
            try await ordinaryRouteWait {
                peers.allSatisfy { $0.state.withLockedValue { $0.closed } } && budget.snapshot.endpoints == 0
                    && budget.snapshot.cuts == 0 && budget.snapshot.staging == 0
                    && budget.waiting.queuedCuts == 0 && budget.waiting.queuedStaging == 0
            }
        }
    }

    @Test func eightActualUploadersWaitBehindHeldStagingThenReceiveNativeVersionAcknowledgments() async throws {
        try await withOrdinaryRoute(push: false) { harness in
            let budget = RelayOrdinaryBudget()
            let key = FileWatchManager.canonicalKey(for: harness.directory.appending(path: "fixture.sqlite"))
            try RelayOrdinaryBudgetTesting.install(budget, for: key)
            defer { RelayOrdinaryBudgetTesting.remove(budget, for: key) }
            var clients: [OrdinaryRouteClient] = [], identities: [String] = []
            // Negotiate and settle each real initial cut; later uploads contend
            // together while each socket remains an actual admitted endpoint.
            for _ in 0..<8 {
                let client = try await harness.connect(); clients.append(client); try client.request()
                try await ordinaryRouteWait { client.complete(0) }; try client.receipt(0)
                try await ordinaryRouteWait { budget.snapshot.cuts == 0 }
            }
            var held: [RelayOrdinaryBudget.Charge] = []
            for _ in 0..<4 { held.append(try budget.reserve(.staging)) }
            for index in 0..<8 {
                let id = UUID().uuidString; identities.append(id)
                let original: [String: Any] = ["id": 0, "globalId": id, "tableName": "SimpleSyncObject", "operation": "INSERT",
                    "rowId": 0, "globalRowId": UUID().uuidString, "timestamp": "2026-09-30T12:00:00.123Z",
                    "changedFields": ["value": ["kind": 0, "value": index], "floatValue": ["kind": 5, "value": Double(index)]],
                    "changedFieldsNames": ["value", "floatValue"], "isFromRemote": false, "isSynchronized": false,
                    "uploadOriginal": ["version": 1, "fields": ["floatValue", "value"], "names": ["value", "floatValue"]], "deliveryVersion": "0"]
                try clients[index].send(JSONSerialization.data(withJSONObject: ["latticeOrdinarySync": ["version": 2, "kind": "upload", "auditLog": [original]]]))
                try await ordinaryRouteWait { budget.waiting.queuedStaging == index + 1 }
            }
            #expect(harness.writer.count(SimpleSyncObject.self) == 0)
            #expect(budget.snapshot.staging == 4 && budget.waiting.queuedStaging == 8)
            // One real slot services eight actual socket uploads; each next
            // grant follows the preceding ACK's actual transport completion.
            // The other three physical charges remain retained throughout.
            held.removeLast()
            let peers = clients
            let expected = identities
            try await ordinaryRouteWait {
                peers.enumerated().allSatisfy { index, client in
                    client.bodies().contains { ($0["kind"] as? String) == "uploadAck" && ($0["accepted"] as? [[String:String]]) == [["globalId": expected[index], "deliveryVersion": "0"]] }
                }
            }
            #expect(harness.writer.count(SimpleSyncObject.self) == 8)
            #expect(harness.writer.count(AuditLog.self) == 8)
            held.removeAll()
            #expect(peers.allSatisfy { !$0.state.withLockedValue { $0.closed || $0.overflow } })
            #expect(budget.snapshot.cuts <= 4 && budget.snapshot.stagingBytes <= 33_554_432)
            for client in peers { client.close() }
            try await ordinaryRouteWait {
                peers.allSatisfy { $0.state.withLockedValue { $0.closed } } && budget.snapshot.endpoints == 0
                    && budget.snapshot.cuts == 0 && budget.snapshot.staging == 0
            }
        }
    }
}


extension RelayOrdinaryRouteTests {
    @Test func actualExternalNativeCapacityWakesOnlyAfterItsLastExportOwnerReleases() async throws {
        try await withOrdinaryRoute(push: false, seed: true) { harness in
            let budget = RelayOrdinaryBudget()
            let key = FileWatchManager.canonicalKey(for: harness.directory.appending(path: "fixture.sqlite"))
            try RelayOrdinaryBudgetTesting.install(budget, for: key)
            defer { RelayOrdinaryBudgetTesting.remove(budget, for: key) }
            var held: [OwnedOrdinarySyncExport] = []
            for _ in 0..<4 { held.append(try harness.writer.captureOrdinarySyncExport()) }
            var alias: OwnedOrdinarySyncExport? = held.last
            let client = try await harness.connect(); try client.request()
            try await ordinaryRouteWait {
                client.bodies().contains { $0["kind"] as? String == "offer" } && budget.snapshot.cuts == 1
            }
            #expect(client.headers().isEmpty && !client.state.withLockedValue { $0.closed })
            held.removeLast()
            #expect(throws: OrdinarySyncExportError.self) { try harness.writer.captureOrdinarySyncExport() }
            #expect(client.headers().isEmpty)
            alias = nil // Actual final native lease release emits the retry hint.
            try await ordinaryRouteWait { client.complete(0) }
            #expect(client.headers().last?["rows"] as? String == "1")
            try client.receipt(0); client.close(); held.removeAll()
            try await ordinaryRouteWait { client.state.withLockedValue { $0.closed } && budget.snapshot.endpoints == 0 && budget.snapshot.cuts == 0 && budget.snapshot.staging == 0 }
            withExtendedLifetime(alias) {}
        }
    }
}
