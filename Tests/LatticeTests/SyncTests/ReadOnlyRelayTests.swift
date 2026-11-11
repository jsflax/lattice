import Foundation
import Testing
import Vapor
import WebSocketKit
import NIOConcurrencyHelpers
@testable import Lattice
@testable import LatticeServerKit

private final class ReadOnlyRelayCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [[String: Any]] = []
    private var didClose = false
    private var attached: WebSocket?
    var socket: WebSocket? { lock.withLock { attached } }
    var closed: Bool { lock.withLock { didClose } }
    var rejections: Int { lock.withLock { messages.filter { $0["kind"] as? String == "rejected" }.count } }
    func contains(_ id: UUID) -> Bool {
        lock.withLock {
            messages.contains { root in
                (root["auditLog"] as? [[String: Any]])?.contains { ($0["globalId"] as? String).flatMap(UUID.init(uuidString:)) == id } ?? false
            }
        }
    }
    func attach(_ socket: WebSocket) {
        lock.withLock { attached = socket }
        socket.onBinary { [weak self] _, bytes in
            guard let self, let root = (try? JSONSerialization.jsonObject(with: Data(buffer: bytes))) as? [String: Any] else { return }
            self.lock.withLock { self.messages.append(root) }
        }
        socket.onClose.whenComplete { [weak self] _ in
            guard let self else { return }; self.lock.withLock { self.didClose = true }
        }
    }
}

extension RelayApplyFaultScope {
@Suite("Read-only relay acknowledgements", .serialized, .timeLimit(.minutes(1))) @MainActor
struct ReadOnlyRelayTests {
    private func until(_ predicate: @escaping @Sendable () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    @Test func acknowledgementFastPathCannotContainAnUploadOrInvalidIdentity() throws {
        let valid = try JSONEncoder().encode(ServerSentEvent.ack([UUID()]))
        #expect(RelayFrame(valid).isPureAcknowledgement)
        let empty = try JSONEncoder().encode(ServerSentEvent.ack([]))
        #expect(RelayFrame(empty).isPureAcknowledgement)
        for json in [
            "{\"kind\":\"ack\",\"ack\":[\"invalid\"]}",
            "{\"kind\":\"ack\",\"ack\":[],\"auditLog\":[]}",
            "{\"kind\":\"auditLog\",\"ack\":[]}",
            "{\"kind\":\"ack\",\"ack\":{}}"
        ] { #expect(!RelayFrame(Data(json.utf8)).isPureAcknowledgement) }
    }

    @Test func realReadOnlySourceConsumesAcksWithoutApplyAndKeepsLivePushAndRevocation() async throws {
        let root = testTemporaryDirectory.appending(path: "readonly-relay-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "source.sqlite")
        let source = try Lattice(for: [SimpleSyncObject.self], configuration: .init(fileURL: file))
        let first = SimpleSyncObject(value: 17, floatValue: 1.25)
        try source.add(first)
        let firstAudit = try #require(source.objects(AuditLog.self).first?.globalId)
        var environment = Environment.testing; environment.arguments = ["readonly-relay"]
        let app = try await Application.make(environment)
        app.http.server.configuration.hostname = "127.0.0.1"; app.http.server.configuration.port = 0
        let channel = "readonly-" + UUID().uuidString.lowercased(), user = UUID()
        let allowed = NIOLockedValueBox(true), applyAttempts = NIOLockedValueBox(0)
        let handle = Lattice.configureSyncRelay(on: app.routes, path: ["sync"], for: [SimpleSyncObject.self], storageURL: root,
            writePolicy: .init(allowedOperations: [:], unlistedTables: .deny),
            storeConfiguration: { url in
                var config = Lattice.Configuration(fileURL: url)
                config.isReadOnly = true; config.uploadsEnabled = false
                return config
            }, observerPush: SyncObserverPush(), revalidateAfterRegistration: true,
            channelExtractor: { _ in
                guard allowed.withLockedValue({ $0 }) else { throw Abort(.forbidden) }
                return SyncChannel(id: channel, userId: user, databaseFileName: "source.sqlite")
            })
        // A processed valid ACK must not reach receive/retry at all. Counting
        // here catches the old SQL write attempt even if it was merely logged.
        _applyFaultForTesting.withLockedValue { $0 = { id, _ in
            if id == channel { applyAttempts.withLockedValue { $0 += 1 } }
        } }
        defer { _applyFaultForTesting.withLockedValue { $0 = nil } }
        let capture = ReadOnlyRelayCapture()
        do {
            try await app.startup()
            let port = try #require(app.http.server.shared.localAddress?.port)
            let once = AtomicOnce()
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                WebSocket.connect(to: "ws://127.0.0.1:\(port)/sync", on: app.eventLoopGroup) { socket in
                    capture.attach(socket); if once.tryFire() { done.resume() }
                }.whenFailure { error in if once.tryFire() { done.resume(throwing: error) } }
            }
            #expect(try await until { capture.contains(firstAudit) })
            let socket = try #require(capture.socket)
            try await socket.send(Array(try JSONEncoder().encode(ServerSentEvent.ack([firstAudit]))))
            let malformed = Array(Data("{\"kind\":\"ack\",\"ack\":[\"invalid\"]}".utf8))
            try await socket.send(malformed)
            // This rejected later frame is a deterministic processing barrier
            // for the valid ACK, not a sleep-based absence assertion.
            #expect(try await until { capture.rejections == 1 })
            #expect(applyAttempts.withLockedValue { $0 } == 0)
            #expect(source.objects(AuditLog.self).allSatisfy { !$0.isSynchronized })
            #expect(source.objects(SimpleSyncObject.self).count == 1)
            #expect(first.value == 17 && first.floatValue == 1.25)
            let later = SimpleSyncObject(value: 23, floatValue: 2.5)
            try source.add(later)
            let laterAudit = try #require(source.objects(AuditLog.self).sortedBy(\.primaryKey, order: .reverse).first?.globalId)
            #expect(try await until { capture.contains(laterAudit) })
            try await socket.send(Array(try JSONEncoder().encode(ServerSentEvent.ack([laterAudit]))))
            try await socket.send(malformed)
            #expect(try await until { capture.rejections == 2 })
            #expect(applyAttempts.withLockedValue { $0 } == 0)
            #expect(source.objects(AuditLog.self).allSatisfy { !$0.isSynchronized })
            allowed.withLockedValue { $0 = false }
            await handle.disconnect(channelId: channel, userId: user)
            #expect(try await until { capture.closed })
        } catch {
            await handle.disconnectAll(channelId: channel); try? await app.asyncShutdown()
            source.close(); try? FileManager.default.removeItem(at: root); throw error
        }
        await handle.disconnectAll(channelId: channel); try await app.asyncShutdown()
        source.close(); try FileManager.default.removeItem(at: root)
    }
}
}
