import Foundation
import NIOCore
import NIOConcurrencyHelpers

/// Binary application storage only: transport backing, parsed/native objects,
/// allocator overhead and outbound buffers have separate lifetimes and limits.
struct RelayIngressLimits: Sendable {
    let connectionFrames: Int
    let connectionBytes: Int
    let processFrames: Int
    let processBytes: Int
    let frameBytes: Int

    init(connectionFrames: Int = 256, connectionBytes: Int = 64 << 20,
         processFrames: Int = 4096, processBytes: Int = 256 << 20,
         frameBytes: Int = 64 << 20) {
        precondition(connectionFrames > 0 && processFrames > 0)
        precondition(connectionBytes >= 0 && processBytes >= 0 && frameBytes >= 0)
        precondition(frameBytes <= connectionBytes && frameBytes <= processBytes)
        self.connectionFrames = connectionFrames; self.connectionBytes = connectionBytes
        self.processFrames = processFrames; self.processBytes = processBytes; self.frameBytes = frameBytes
    }
}

enum RelayIngressStopReason: Error, Sendable, Equatable {
    case frameBytes, connectionFrames, connectionBytes, processFrames, processBytes
    case closed, revoked, setupRefused, applyRefused, consumerCancelled, streamInvariant
}

struct RelayIngressSnapshot: Sendable {
    let frames: Int
    let inputBytes: Int
    let firstReason: RelayIngressStopReason?
}

/// Fields are protected by the owning admission service's single lock. No
/// socket, continuation, task or frame is retained by this account.
final class RelayIngressAccount: @unchecked Sendable {
    fileprivate let service: RelayIngressAdmission
    fileprivate var frames = 0
    fileprivate var inputBytes = 0
    fileprivate var firstReason: RelayIngressStopReason?
    fileprivate init(service: RelayIngressAdmission) { self.service = service }
    var snapshot: RelayIngressSnapshot { service.snapshot(for: self) }
    var streamCapacity: Int { service.limits.connectionFrames }
    func seal(_ reason: RelayIngressStopReason) { service.seal(self, reason: reason) }
    func copyFrame(_ buffer: ByteBuffer) throws -> RelayIngressFrame {
        try service.copyFrame(buffer, for: self)
    }
}

/// Its final reference, rather than close/dequeue, releases exactly one charge.
fileprivate final class RelayIngressCharge: Sendable {
    let account: RelayIngressAccount
    let bytes: Int
    init(account: RelayIngressAccount, bytes: Int) { self.account = account; self.bytes = bytes }
    deinit { account.service.release(account, bytes: bytes) }
}

/// Immutable private bytes until exclusive deinit; copies never expose aliases.
/// Explicit storage release precedes charge destruction. Read methods retain
/// self, so deinit cannot race their access to the private storage.
final class RelayIngressFrame: @unchecked Sendable {
    let byteCount: Int
    private var storage: Data?
    private let charge: RelayIngressCharge
    private let didReleasePayloadForTesting: (@Sendable () -> Void)?

    fileprivate init(buffer: ByteBuffer, charge: RelayIngressCharge,
                     didReleasePayloadForTesting: (@Sendable () -> Void)?) {
        byteCount = buffer.readableBytes
        self.charge = charge
        self.didReleasePayloadForTesting = didReleasePayloadForTesting
        storage = buffer.withUnsafeReadableBytes { bytes in
            bytes.isEmpty ? Data() : Data(bytes: bytes.baseAddress!, count: bytes.count)
        }
    }

    deinit {
        storage = nil
        didReleasePayloadForTesting?() // Outside admission locks, before capacity returns.
    }

    func copyForApply() -> Data {
        storage!.withUnsafeBytes { bytes in
            bytes.isEmpty ? Data() : Data(bytes: bytes.baseAddress!, count: bytes.count)
        }
    }

    /// Socket ownership cannot keep ingress backing after its charge ends.
    func makeLegacyFanoutBuffer() -> ByteBuffer {
        var result = ByteBufferAllocator().buffer(capacity: byteCount)
        _ = storage!.withUnsafeBytes { bytes in result.writeBytes(bytes) }
        return result
    }
}

final class RelayIngressAdmission: @unchecked Sendable {
    static let shared = RelayIngressAdmission()
    let limits: RelayIngressLimits
    private let lock = NSLock()
    private var frames = 0
    private var inputBytes = 0
    private let beforeCopyForTesting: (@Sendable () -> Void)?
    private let didReleasePayloadForTesting: (@Sendable () -> Void)?

    init(limits: RelayIngressLimits = .init(),
         beforeCopyForTesting: (@Sendable () -> Void)? = nil,
         didReleasePayloadForTesting: (@Sendable () -> Void)? = nil) {
        self.limits = limits
        self.beforeCopyForTesting = beforeCopyForTesting
        self.didReleasePayloadForTesting = didReleasePayloadForTesting
    }

    func makeAccount() -> RelayIngressAccount { RelayIngressAccount(service: self) }

    private func reserve(_ account: RelayIngressAccount, bytes: Int) throws -> RelayIngressCharge {
        lock.lock(); defer { lock.unlock() }
        precondition(account.service === self && bytes >= 0)
        if let reason = account.firstReason { throw reason }
        let reason: RelayIngressStopReason?
        if bytes > limits.frameBytes { reason = .frameBytes }
        else if account.frames >= limits.connectionFrames { reason = .connectionFrames }
        else if bytes > limits.connectionBytes - account.inputBytes { reason = .connectionBytes }
        else if frames >= limits.processFrames { reason = .processFrames }
        else if bytes > limits.processBytes - inputBytes { reason = .processBytes }
        else { reason = nil }
        if let reason {
            account.firstReason = reason
            throw reason
        }
        frames += 1; inputBytes += bytes
        account.frames += 1; account.inputBytes += bytes
        return RelayIngressCharge(account: account, bytes: bytes)
    }

    fileprivate func copyFrame(_ buffer: ByteBuffer, for account: RelayIngressAccount) throws -> RelayIngressFrame {
        let charge = try reserve(account, bytes: buffer.readableBytes)
        beforeCopyForTesting?()
        return RelayIngressFrame(buffer: buffer, charge: charge,
                                 didReleasePayloadForTesting: didReleasePayloadForTesting)
    }

    fileprivate func seal(_ account: RelayIngressAccount, reason: RelayIngressStopReason) {
        lock.lock(); defer { lock.unlock() }
        if account.firstReason == nil { account.firstReason = reason }
    }

    fileprivate func release(_ account: RelayIngressAccount, bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        precondition(frames > 0 && account.frames > 0 && inputBytes >= bytes && account.inputBytes >= bytes)
        frames -= 1; inputBytes -= bytes
        account.frames -= 1; account.inputBytes -= bytes
    }

    fileprivate func snapshot(for account: RelayIngressAccount) -> RelayIngressSnapshot {
        lock.lock(); defer { lock.unlock() }
        return .init(frames: account.frames, inputBytes: account.inputBytes, firstReason: account.firstReason)
    }

    /// A zero snapshot witnesses actual payload/capture release, not merely a
    /// close request. No process registry or queue of waiting producers exists.
    var snapshot: RelayIngressSnapshot {
        lock.lock(); defer { lock.unlock() }
        return .init(frames: frames, inputBytes: inputBytes, firstReason: nil)
    }
}

enum RelayIngressAdmissionTesting {
    private static let mounts = NIOLockedValueBox<[URL: RelayIngressAdmission]>([:])
    static func install(_ service: RelayIngressAdmission, for url: URL) {
        mounts.withLockedValue { $0[url] = service }
    }
    static func service(for url: URL) -> RelayIngressAdmission? { mounts.withLockedValue { $0[url] } }
    static func remove(_ service: RelayIngressAdmission, for url: URL) {
        mounts.withLockedValue { if $0[url] === service { $0[url] = nil } }
    }
}
