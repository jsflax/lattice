import Foundation
import os
import LatticeSwiftCppBridge

// ============================================================================
// C++ to Swift Type Conversions via JSON
// ============================================================================

extension AuditLog {
    /// JSON representation that matches C++ audit_log_entry::to_json() format
    private struct CxxAuditLogJSON: Codable {
        let id: Int64
        let globalId: String
        let tableName: String
        let operation: String
        let rowId: Int64
        let globalRowId: String
        let changedFields: [String: AnyProperty]
        let changedFieldsNames: [String]
        let timestamp: String
        let isFromRemote: Bool
        let isSynchronized: Bool
    }

    /// Create a Swift AuditLog from C++ audit_log_entry JSON
    /// Uses JSON serialization to bridge the complex C++ types
    static func fromCxxJSON(_ jsonString: String) throws -> AuditLog {
        guard let data = jsonString.data(using: .utf8) else {
            throw NSError(domain: "AuditLog", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON string"])
        }

        let decoder = JSONDecoder()
        let json = try decoder.decode(CxxAuditLogJSON.self, from: data)

        let auditLog = AuditLog()

        auditLog.tableName = json.tableName

        // Parse operation
        switch json.operation {
        case "INSERT": auditLog.operation = .insert
        case "UPDATE": auditLog.operation = .update
        case "DELETE": auditLog.operation = .delete
        default: auditLog.operation = .insert
        }

        auditLog.rowId = json.rowId
        auditLog.globalRowId = UUID(uuidString: json.globalRowId)
        auditLog.changedFields = json.changedFields
        auditLog.changedFieldsNames = json.changedFieldsNames

        // Parse timestamp
        if let ts = Double(json.timestamp) {
            auditLog.timestamp = Date(timeIntervalSince1970: ts)
        } else if let date = ISO8601DateFormatter().date(from: json.timestamp) {
            auditLog.timestamp = date
        } else {
            auditLog.timestamp = Date()
        }

        auditLog.isFromRemote = json.isFromRemote
        auditLog.isSynchronized = json.isSynchronized

        return auditLog
    }

    /// Create a Swift AuditLog from a C++ audit_log_entry
    /// Uses to_json() on the C++ side and JSON decoding on Swift side
    convenience init(from cxx: lattice.audit_log_entry) {
        let jsonString = String(cxx.to_json())

        do {
            let parsed = try AuditLog.fromCxxJSON(jsonString)
            self.init()
            self.tableName = parsed.tableName
            self.operation = parsed.operation
            self.rowId = parsed.rowId
            self.globalRowId = parsed.globalRowId
            self.changedFields = parsed.changedFields
            self.changedFieldsNames = parsed.changedFieldsNames
            self.timestamp = parsed.timestamp
            self.isFromRemote = parsed.isFromRemote
            self.isSynchronized = parsed.isSynchronized
        } catch {
            // Fallback to empty audit log on parse failure
            self.init()
            self.tableName = ""
            self.rowId = 0
            self.changedFields = [:]
            self.timestamp = Date()
            self.isFromRemote = false
        }
    }

    /// Convert Swift AuditLog to JSON bytes for C++ consumption
    func toCxxJSONBytes() throws -> Data {
        return try JSONEncoder().encode(self)
    }
}

// ============================================================================
// ServerSentEvent
// ============================================================================

public enum ServerSentEvent: Codable {
    case auditLog([AuditLog])
    case ack([UUID])

    private enum CodingKeys: String, CodingKey {
        case kind, auditLog, ack
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)

        switch kind {
        case "auditLog":
            let logs = try container.decode([AuditLog].self, forKey: .auditLog)
            self = .auditLog(logs)
        case "ack":
            let ids = try container.decode([UUID].self, forKey: .ack)
            self = .ack(ids)
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown kind: \(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .auditLog(let logs):
            try container.encode("auditLog", forKey: .kind)
            try container.encode(logs, forKey: .auditLog)
        case .ack(let ids):
            try container.encode("ack", forKey: .kind)
            try container.encode(ids, forKey: .ack)
        }
    }
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
//
//actor Synchronizer: NSObject, URLSessionWebSocketDelegate {
//    private var webSocketTask: URLSessionWebSocketTask!
//    private var lattice: Lattice!
//    private var isConnected = false
//    private let logger = Logger.sync
//    
//    init?(modelTypes: UncheckedSendable<[any Model.Type]>, configuration: Lattice.Configuration) {
//        super.init()
//        guard let url = configuration.wssEndpoint,
//              let authorizationToken = configuration.authorizationToken else {
//            return nil
//        }
//        Task { [modelTypes] in
//            await _isolatedInit(modelTypes: modelTypes.value,
//                                configuration: configuration,
//                                url: url,
//                                authorizationToken: authorizationToken)
//        }
//    }
//    
//
//    private func _isolatedInit(modelTypes: [any Model.Type],
//                               configuration: Lattice.Configuration,
//                               url: URL,
//                               authorizationToken: String) {
//        self.lattice = try! Lattice(for: modelTypes, configuration: configuration, isSynchronizing: true)
//        // TODO: Add last sent event id table
//
//        reset()
//    }
//    
//    deinit {
//        isConnected = false
//        webSocketTask?.cancel()
//        logger.error("❌ >>> Synchronizer deinitialized")
//    }
//    
//    private func set(isConnected: Bool) {
//        self.isConnected = isConnected
//        if isConnected {
//            reconnectAttempts = 0
//        }
//    }
//    
//    nonisolated func urlSession(_ session: URLSession,
//                                webSocketTask: URLSessionWebSocketTask,
//                                didOpenWithProtocol protocol: String?) {
//        logger.debug("✅ Web Socket Opened")
//        Task {
//            await set(isConnected: true)
//            do {
//                try await start()
//            } catch {
//                logger.error("❌ WebSocket Error: \(error)")
//            }
//        }
//    }
// 
//    private func start() async throws {
//        try await Task {
//            let events = lattice.objects(AuditLog.self).where({
//                !$0.isSynchronized
//            }).sortedBy(.init(\.primaryKey, order: .forward)).snapshot()
//                .chunked(into: 1000)
//            for events in events {
//                if events.count > 0 {
//                    let encoded = try JSONEncoder().encode(ServerSentEvent.auditLog(events))
//                    let byteCount = encoded.count
//                    // Human‑readable formatting
//                    let formatter = ByteCountFormatter()
//                    formatter.allowedUnits = [.useBytes, .useKB, .useMB]
//                    formatter.countStyle    = .file
//                    let humanSize = formatter.string(fromByteCount: Int64(byteCount))
//                    
//                    logger.debug("🧦 Sending \(events.count) (\(humanSize)) events.")
//                    try await webSocketTask.send(.data(encoded))
//                }
//            }
//        }.value
//        
//        let token = lattice.observe { events in
//            guard !events.isEmpty else {
//                return
//            }
//            var eventsToEncode = [AuditLog]()
//            for event in events {
//                if event.tableName == "" || event.isSynchronized || event.isFromRemote {
//                    continue
//                }
////                self.logger.debug("🧦: \(self.lattice.configuration.fileURL) Sending instruction: \(event.operation) for \(event.tableName)")
//                eventsToEncode.append(event)
//            }
//            guard eventsToEncode.count > 0 else {
//                return
//            }
//            Task {
//                for events in eventsToEncode.chunked(into: 1000) {
//                    let eventData = try! JSONEncoder().encode(ServerSentEvent.auditLog(events))
//                    let byteCount = eventData.count
//                    // Human‑readable formatting
//                    let formatter = ByteCountFormatter()
//                    formatter.allowedUnits = [.useBytes, .useKB, .useMB]
//                    formatter.countStyle    = .file
//                    let humanSize = formatter.string(fromByteCount: Int64(byteCount))
//
//                    self.logger.debug("🧦 Sending \(events.count) (\(humanSize)) events.")
//                    do {
//                        try await self.webSocketTask.send(.data(eventData))
//                    } catch {
//                        self.logger.error("\(error)")
//                    }
//                }
//            }
//        }
//        defer {
//            token.cancel()
//        }
//
//        while isConnected {
//            do {
//                switch try await webSocketTask.receive() {
//                case .string(_):
//                    break
//                case .data(let data):
//                    _ = try lattice.receive(data)
//                @unknown default: fatalError()
//                }
//            } catch {
//                self.logger.error("\(error)")
//                if webSocketTask.state == .canceling || webSocketTask.state == .suspended {
//                    isConnected = false
//                }
//                webSocketTask.sendPing { error in
//                    self.logger.error("\(error)")
//                }
//                isConnected = false
//                reset()
//                break
//            }
//        }
//    }
//    
//    private var reconnectAttempts = 0
//    private let maxReconnectAttempts = 6   // give up after 64 s back-off
//    private let baseDelay: TimeInterval = 1
//    
//    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
//        // 2^0, 2^1, 2^2, … * baseDelay
//      
//        Task {
//            try await reconnect()
//        }
//    }
//    
//    nonisolated func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
//        logger.error("❌ WebSocket Closed becoming invalid")
//        Task {
//            await set(isConnected: false)
//            await reset()
//        }
//    }
//    
//    nonisolated func urlSession(_ session: URLSession,
//                                webSocketTask: URLSessionWebSocketTask,
//                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
//                                reason: Data?) {
//        logger.error("❌ WebSocket Closed")
//        Task {
//            try await reconnect()
//        }
//    }
//    
//    private func reconnect() async throws {
//        set(isConnected: false)
//        
//        let seconds = pow(2.0, Double(reconnectAttempts)) * baseDelay
//        logger.info("⏳ Reconnecting in \(seconds)s (attempt \(self.reconnectAttempts + 1))")
//        reconnectAttempts += 1
//        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
//        
//        reset()
//        
//        // if you have an `isConnected` flag you can break out early:
//        if isConnected {
//            logger.info("✅ Reconnected on attempt \(self.reconnectAttempts)")
//            return
//        }
//    }
//    
//    private func reset() {
//        guard var url = lattice.configuration.wssEndpoint,
//              let authorizationToken = lattice.configuration.authorizationToken else {
//            return
//        }
//        let lastReceivedEvent = lattice.objects(AuditLog.self).where({
//            $0.isFromRemote
//        }).sortedBy(.init(\.primaryKey, order: .forward)).last
//        if let lastReceivedEvent {
//            url.append(queryItems: [
//                .init(name: "last-event-id", value: lastReceivedEvent.__globalId!.uuidString.lowercased())
//            ])
//        }
//        var req = URLRequest(url: url)
//        req.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")
//        self.webSocketTask = URLSession.shared.webSocketTask(with: req)
//        webSocketTask.maximumMessageSize = 500 * 1024 * 1024
//        webSocketTask.delegate = self
//        webSocketTask.resume()
//    }
//}

extension Lattice {
    public func receive(_ data: Data) throws -> [UUID] {
        cxxLattice.receive_sync_data(data.toCxxValue()).map {
            UUID(uuidString: String($0))!
        }
    }
    
    /// Get audit log events after a checkpoint (for server-side sync)
    public func eventsAfter(globalId: UUID?) throws -> [AuditLog] {
        let cxxEntries: lattice.AuditLogEntryVector
        if let globalId {
            cxxEntries = cxxLattice.events_after(.init(std.string(globalId.uuidString.lowercased())))
        } else {
            cxxEntries = cxxLattice.events_after(.init())
        }

        // Convert C++ entries to Swift AuditLog
        var results: [AuditLog] = []
        for entry in cxxEntries {
            results.append(AuditLog(from: entry))
        }
        return results
    }
}
