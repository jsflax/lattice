import Foundation
import os

public enum ServerSentEvent: Codable {
    case auditLog([AuditLog])
    case ack([UUID])
}

extension Array {
    /// Returns this array split into subarrays of at most `size` elements.
    public func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        var chunks: [[Element]] = []
        var idx = 0
        while idx < count {
            let end = Swift.min(idx + size, count)
            chunks.append(Array(self[idx..<end]))
            idx += size
        }
        return chunks
    }
}

struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    
    init(_ value: T) {
        self.value = value
    }
}

actor Synchronizer: NSObject, URLSessionWebSocketDelegate {
    private var webSocketTask: URLSessionWebSocketTask!
    private var lattice: Lattice!
    private var isConnected = false
    private let logger = Logger.sync
    
    init?(modelTypes: UncheckedSendable<[any Model.Type]>, configuration: Lattice.Configuration) {
        super.init()
        guard let url = configuration.wssEndpoint,
              let authorizationToken = configuration.authorizationToken else {
            return nil
        }
        Task { [modelTypes] in
            await _isolatedInit(modelTypes: modelTypes.value,
                                configuration: configuration,
                                url: url,
                                authorizationToken: authorizationToken)
        }
    }
    

    private func _isolatedInit(modelTypes: [any Model.Type],
                               configuration: Lattice.Configuration,
                               url: URL,
                               authorizationToken: String) {
        self.lattice = try! Lattice(for: modelTypes, configuration: configuration, isSynchronizing: true)
        // TODO: Add last sent event id table

        reset()
    }
    
    deinit {
        isConnected = false
        webSocketTask?.cancel()
        logger.error("❌ >>> Synchronizer deinitialized")
    }
    
    private func set(isConnected: Bool) {
        self.isConnected = isConnected
        if isConnected {
            reconnectAttempts = 0
        }
    }
    
    nonisolated func urlSession(_ session: URLSession,
                                webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {
        logger.debug("✅ Web Socket Opened")
        Task {
            await set(isConnected: true)
            do {
                try await start()
            } catch {
                logger.error("❌ WebSocket Error: \(error)")
            }
        }
    }
 
    private func start() async throws {
        try await Task {
            let events = lattice.objects(AuditLog.self).where({
                !$0.isSynchronized
            }).sortedBy(.init(\.primaryKey, order: .forward)).snapshot()
                .chunked(into: 1000)
            for events in events {
                if events.count > 0 {
                    let encoded = try JSONEncoder().encode(ServerSentEvent.auditLog(events))
                    let byteCount = encoded.count
                    // Human‑readable formatting
                    let formatter = ByteCountFormatter()
                    formatter.allowedUnits = [.useBytes, .useKB, .useMB]
                    formatter.countStyle    = .file
                    let humanSize = formatter.string(fromByteCount: Int64(byteCount))
                    
                    logger.debug("🧦 Sending \(events.count) (\(humanSize)) events.")
                    try await webSocketTask.send(.data(encoded))
                }
            }
        }.value
        
        let token = lattice.observe { events in
            guard !events.isEmpty else {
                return
            }
            var eventsToEncode = [AuditLog]()
            for event in events {
                if event.tableName == "" || event.isSynchronized || event.isFromRemote {
                    continue
                }
//                self.logger.debug("🧦: \(self.lattice.configuration.fileURL) Sending instruction: \(event.operation) for \(event.tableName)")
                eventsToEncode.append(event)
            }
            guard eventsToEncode.count > 0 else {
                return
            }
            Task {
                for events in eventsToEncode.chunked(into: 1000) {
                    let eventData = try! JSONEncoder().encode(ServerSentEvent.auditLog(events))
                    let byteCount = eventData.count
                    // Human‑readable formatting
                    let formatter = ByteCountFormatter()
                    formatter.allowedUnits = [.useBytes, .useKB, .useMB]
                    formatter.countStyle    = .file
                    let humanSize = formatter.string(fromByteCount: Int64(byteCount))

                    self.logger.debug("🧦 Sending \(events.count) (\(humanSize)) events.")
                    do {
                        try await self.webSocketTask.send(.data(eventData))
                    } catch {
                        self.logger.error("\(error)")
                    }
                }
            }
        }
        defer {
            token.cancel()
        }

        while isConnected {
            do {
                switch try await webSocketTask.receive() {
                case .string(_):
                    break
                case .data(let data):
                    _ = try lattice.receive(data)
                @unknown default: fatalError()
                }
            } catch {
                self.logger.error("\(error)")
                if webSocketTask.state == .canceling || webSocketTask.state == .suspended {
                    isConnected = false
                }
                webSocketTask.sendPing { error in
                    self.logger.error("\(error)")
                }
                isConnected = false
                reset()
                break
            }
        }
    }
    
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 6   // give up after 64 s back-off
    private let baseDelay: TimeInterval = 1
    
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        // 2^0, 2^1, 2^2, … * baseDelay
      
        Task {
            try await reconnect()
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        logger.error("❌ WebSocket Closed becoming invalid")
        Task {
            await set(isConnected: false)
            await reset()
        }
    }
    
    nonisolated func urlSession(_ session: URLSession,
                                webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                                reason: Data?) {
        logger.error("❌ WebSocket Closed")
        Task {
            try await reconnect()
        }
    }
    
    private func reconnect() async throws {
        set(isConnected: false)
        
        let seconds = pow(2.0, Double(reconnectAttempts)) * baseDelay
        logger.info("⏳ Reconnecting in \(seconds)s (attempt \(self.reconnectAttempts + 1))")
        reconnectAttempts += 1
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        
        reset()
        
        // if you have an `isConnected` flag you can break out early:
        if isConnected {
            logger.info("✅ Reconnected on attempt \(self.reconnectAttempts)")
            return
        }
    }
    
    private func reset() {
        guard var url = lattice.configuration.wssEndpoint,
              let authorizationToken = lattice.configuration.authorizationToken else {
            return
        }
        let lastReceivedEvent = lattice.objects(AuditLog.self).where({
            $0.isFromRemote
        }).sortedBy(.init(\.primaryKey, order: .forward)).last
        if let lastReceivedEvent {
            url.append(queryItems: [
                .init(name: "last-event-id", value: lastReceivedEvent.__globalId.uuidString.lowercased())
            ])
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")
        self.webSocketTask = URLSession.shared.webSocketTask(with: req)
        webSocketTask.maximumMessageSize = 500 * 1024 * 1024
        webSocketTask.delegate = self
        webSocketTask.resume()
    }
}

extension Lattice {
    public func receive(_ data: Data) throws -> [UUID] {
        let sse = try JSONDecoder().decode(ServerSentEvent.self, from: data)
        switch sse {
        case .auditLog(let log):
            Logger.sync.debug("🧦: \(configuration.fileURL) Received \(log.count) events")
//            applyInstructions(from: log)
            return log.map(\.__globalId)
        case .ack(let acked):
            Logger.sync.debug("🧦: \(configuration.fileURL) Acknowledging \(acked.count) events")
            transaction {
                for id in acked {
                    object(AuditLog.self, globalKey: id)?.isSynchronized = true
                }
            }
            return acked
        }
    }
    
    public func eventsAfter(globalId: UUID?) throws -> [AuditLog] {
        if let globalId {
            // if this user has synced before and is sending up their checkpoint
            // check if we have any events to sync
            let events = [AuditLog]()
            if let lastSentEvent = objects(AuditLog.self).where({
                $0.__globalId == globalId
            }).first {
                let primaryKey = lastSentEvent.primaryKey
                
                var events: [AuditLog] = []
                return objects(AuditLog.self).where({ [lastPrimaryKey = primaryKey ?? 0] in
                    $0.primaryKey > lastPrimaryKey
                }).sortedBy(.init(\.primaryKey, order: .forward)).snapshot()
            }
            return events
        } else {
            // if they have not synced before, start bringing them up to date
            return objects(AuditLog.self).sortedBy(.init(\.primaryKey, order: .forward)).snapshot()
        }
    }
}
