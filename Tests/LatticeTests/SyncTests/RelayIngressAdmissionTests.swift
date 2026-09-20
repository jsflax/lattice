import Foundation
import Testing
import NIOCore
import NIOConcurrencyHelpers
@testable import LatticeServerKit

private final class IngressCopyGate: Sendable {
    let entered = NIOLockedValueBox(false)
    let expired = NIOLockedValueBox(false)
    let release = DispatchSemaphore(value: 0)
    func block() {
        entered.withLockedValue { $0 = true }
        expired.withLockedValue { $0 = release.wait(timeout: .now() + 5) != .success }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct RelayIngressAdmissionTests {
    private func rejected(_ account: RelayIngressAccount, count: Int,
                          reason: RelayIngressStopReason) {
        do {
            _ = try account.copyFrame(ByteBuffer(bytes: Array(repeating: UInt8(7), count: count)))
            Issue.record("expected ingress refusal")
        } catch { #expect(error as? RelayIngressStopReason == reason) }
    }

    private func until(_ predicate: @escaping @Sendable () -> Bool) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while !predicate() {
            try #require(DispatchTime.now().uptimeNanoseconds < deadline, "bounded state wait expired")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    @Test func exactByteCapsAreInclusiveAndFirstRefusalSurvivesLaterStops() throws {
        let copies = NIOLockedValueBox(0)
        let service = RelayIngressAdmission(limits: .init(connectionFrames: 4, connectionBytes: 6,
            processFrames: 8, processBytes: 12, frameBytes: 4),
            beforeCopyForTesting: { copies.withLockedValue { $0 += 1 } })
        let account = service.makeAccount()
        var frames = [try account.copyFrame(ByteBuffer(bytes: [1, 1, 1, 1])),
                      try account.copyFrame(ByteBuffer(bytes: [2, 2]))]
        #expect(account.snapshot.inputBytes == 6 && service.snapshot.frames == 2)
        rejected(account, count: 1, reason: .connectionBytes)
        account.seal(.closed); account.seal(.applyRefused)
        #expect(account.snapshot.firstReason == .connectionBytes)
        #expect(account.snapshot.inputBytes == 6, "seal cannot release owned bytes")
        rejected(account, count: 0, reason: .connectionBytes)
        frames.removeAll()
        #expect(service.snapshot.frames == 0 && service.snapshot.inputBytes == 0)
        let oversized = service.makeAccount()
        rejected(oversized, count: 5, reason: .frameBytes)
        #expect(service.snapshot.frames == 0)
        #expect(copies.withLockedValue { $0 } == 2, "refused frames never enter owned copying")
    }

    @Test func emptyFramesConsumePerConnectionCount() throws {
        let service = RelayIngressAdmission(limits: .init(connectionFrames: 2, connectionBytes: 0,
            processFrames: 4, processBytes: 0, frameBytes: 0))
        let account = service.makeAccount()
        var frames = [try account.copyFrame(ByteBuffer()), try account.copyFrame(ByteBuffer())]
        #expect(account.snapshot.frames == 2 && account.snapshot.inputBytes == 0)
        rejected(account, count: 0, reason: .connectionFrames)
        frames.removeAll()
        #expect(service.snapshot.frames == 0)
    }

    @Test func processCapsSpanAccountsAndReleaseAllowsANewAccount() throws {
        let service = RelayIngressAdmission(limits: .init(connectionFrames: 3, connectionBytes: 4,
            processFrames: 2, processBytes: 4, frameBytes: 4))
        let first = service.makeAccount(), second = service.makeAccount()
        var frames = [try first.copyFrame(ByteBuffer(bytes: [1, 1])),
                      try second.copyFrame(ByteBuffer(bytes: [2, 2]))]
        #expect(service.snapshot.frames == 2 && service.snapshot.inputBytes == 4)
        rejected(service.makeAccount(), count: 0, reason: .processFrames)
        frames.removeLast()
        rejected(service.makeAccount(), count: 3, reason: .processBytes)
        let replacement = try service.makeAccount().copyFrame(ByteBuffer(bytes: [3, 3]))
        #expect(service.snapshot.frames == 2 && service.snapshot.inputBytes == 4)
        withExtendedLifetime(replacement) {}
        frames.removeAll()
    }

    @Test func sealDuringCopyKeepsReservationUntilLastCaptureAndPayloadRelease() async throws {
        let gate = IngressCopyGate()
        let probe = NIOLockedValueBox<RelayIngressAccount?>(nil)
        let releaseSnapshot = NIOLockedValueBox<RelayIngressSnapshot?>(nil)
        let service = RelayIngressAdmission(beforeCopyForTesting: { gate.block() },
            didReleasePayloadForTesting: {
                // Reentering snapshot also proves destruction callbacks are off-lock.
                releaseSnapshot.withLockedValue { $0 = probe.withLockedValue { $0?.snapshot } }
            })
        let account = service.makeAccount()
        probe.withLockedValue { $0 = account }
        defer { gate.release.signal(); probe.withLockedValue { $0 = nil } }
        let retained = NIOLockedValueBox<RelayIngressFrame?>(nil)
        let copy = Task.detached {
            let frame = try account.copyFrame(ByteBuffer(bytes: Array(repeating: UInt8(4), count: 32)))
            retained.withLockedValue { $0 = frame }
        }
        try await until { gate.entered.withLockedValue { $0 } }
        #expect(account.snapshot.frames == 1 && account.snapshot.inputBytes == 32)
        account.seal(.closed)
        #expect(account.snapshot.frames == 1 && account.snapshot.inputBytes == 32)
        gate.release.signal()
        try await copy.value
        #expect(!gate.expired.withLockedValue { $0 })
        #expect(account.snapshot.frames == 1)
        retained.withLockedValue { $0 = nil }
        let atDestruction = try #require(releaseSnapshot.withLockedValue { $0 })
        #expect(atDestruction.frames == 1 && atDestruction.inputBytes == 32)
        #expect(atDestruction.firstReason == .closed)
        #expect(service.snapshot.frames == 0 && service.snapshot.inputBytes == 0)
    }

    @Test func smallSliceAndDetachedOutputsDoNotKeepAnIngressCharge() throws {
        let service = RelayIngressAdmission()
        let account = service.makeAccount()
        var backing = ByteBufferAllocator().buffer(capacity: 1 << 20)
        backing.writeRepeatingByte(42, count: 1 << 20)
        let slice = try #require(backing.getSlice(at: 512, length: 32))
        let sourceAddress = slice.withUnsafeReadableBytes { UInt(bitPattern: $0.baseAddress!) }
        var frame: RelayIngressFrame? = try account.copyFrame(slice)
        weak var releasedFrame = frame
        let apply = try #require(frame).copyForApply()
        let outbound = try #require(frame).makeLegacyFanoutBuffer()
        #expect(apply == Data(repeating: 42, count: 32))
        #expect(Array(buffer: outbound) == Array(repeating: UInt8(42), count: 32))
        // These comparisons cover detached consumers, not private ingress
        // backing size or transport/allocator memory release.
        #expect(apply.withUnsafeBytes { UInt(bitPattern: $0.baseAddress!) } != sourceAddress)
        #expect(outbound.withUnsafeReadableBytes { UInt(bitPattern: $0.baseAddress!) } != sourceAddress)
        #expect(account.snapshot.inputBytes == 32)
        frame = nil
        #expect(releasedFrame == nil)
        #expect(service.snapshot.frames == 0 && service.snapshot.inputBytes == 0)
        // Both consumers remain alive after ingress capacity returns.
        withExtendedLifetime((apply, outbound, backing, slice)) {}
    }

    @Test func finishingStreamPreservesAcceptedEnvelopeOrderAndCharges() async throws {
        let service = RelayIngressAdmission(limits: .init(connectionFrames: 2))
        let account = service.makeAccount()
        let (stream, continuation) = AsyncStream<RelayIngressFrame>.makeStream(
            bufferingPolicy: .bufferingOldest(account.streamCapacity))
        for byte in [UInt8(1), UInt8(2)] {
            let result = continuation.yield(try account.copyFrame(ByteBuffer(bytes: [byte])))
            guard case .enqueued = result else { Issue.record("accepted frame was dropped"); return }
        }
        account.seal(.closed)
        continuation.finish()
        #expect(account.snapshot.frames == 2, "finish is not a storage-release fence")
        var order: [UInt8] = []
        for await frame in stream { order.append(contentsOf: frame.copyForApply()) }
        #expect(order == [1, 2])
        #expect(account.snapshot.frames == 0 && account.snapshot.inputBytes == 0)
    }
}
