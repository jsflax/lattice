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

/// Thread-safe one-shot flag for guarding continuation resume.
final class AtomicOnce: @unchecked Sendable {
    private let _lock = NSLock()
    private var _fired = false
    func tryFire() -> Bool {
        _lock.lock()
        defer { _lock.unlock() }
        if _fired { return false }
        _fired = true
        return true
    }
}

@Model class SimpleSyncObject {
    var value: Int = 0
    var floatValue: Float

    init(value: Int, floatValue: Float) {
        self.value = value
        self.floatValue = floatValue
    }
}

@Model class SyncParent {
    var name: String
    var children: List<SyncChild>

    init(name: String) {
        self.name = name
    }
}

@Model class SyncChild {
    var name: String

    init(name: String) {
        self.name = name
    }
}

@Model class SyncVectorObject {
    var label: String
    var embedding: FloatVector

    init(label: String = "", embedding: [Float] = []) {
        self.label = label
        self.embedding = FloatVector(embedding)
    }
}

@Model class SyncGeoObject {
    var name: String
    var location: CLLocationCoordinate2D

    init(name: String = "", latitude: Double = 0, longitude: Double = 0) {
        self.name = name
        self.location = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct SyncEmbedded: EmbeddedModel {
    var detail: String = ""
}

@Model class SyncEmbeddedObject {
    var name: String
    var metadata: SyncEmbedded?

    init(name: String = "", metadata: SyncEmbedded? = nil) {
        self.name = name
        self.metadata = metadata
    }
}

@Model class SequenceSyncObject {
    var open: Float = .random(in: 0...1000)
    var high: Float = .random(in: 0...1000)
    var low: Float = .random(in: 0...1000)
    var close: Float = .random(in: 0...1000)
    var volume: Float = .random(in: 0...1000)
}

/// Thread-safe WebSocket store for test server.
final class SocketStore: @unchecked Sendable {
    private var _sockets: [WebSocket] = []
    private let lock = NSLock()
    let label: String
    private var _waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(label: String = "unnamed") {
        self.label = label
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _sockets.count
    }

    /// Suspends until the socket count reaches at least `target`.
    func waitForCount(_ target: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if _sockets.count >= target {
                lock.unlock()
                continuation.resume()
            } else {
                _waiters.append((target: target, continuation: continuation))
                lock.unlock()
            }
        }
    }

    func append(_ ws: WebSocket) {
        lock.lock()
        _sockets.append(ws)
        let total = _sockets.count
        let ready = _waiters.filter { $0.target <= total }
        _waiters.removeAll { $0.target <= total }
        lock.unlock()
        print("[SocketStore:\(label)] append: total=\(total)")
        for waiter in ready {
            waiter.continuation.resume()
        }
        ws.onClose.whenComplete { [weak self] _ in
            self?.remove(ws)
        }
    }

    private func remove(_ ws: WebSocket) {
        lock.lock()
        _sockets.removeAll { $0 === ws }
        let total = _sockets.count
        lock.unlock()
        print("[SocketStore:\(label)] remove (onClose): total=\(total)")
    }

    func others(excluding ws: WebSocket) -> [WebSocket] {
        lock.lock()
        let result = _sockets.filter { $0 !== ws && !$0.isClosed }
        let total = _sockets.count
        lock.unlock()
        print("[SocketStore:\(label)] others: \(result.count) live of \(total) total (excluding sender)")
        return result
    }
}
