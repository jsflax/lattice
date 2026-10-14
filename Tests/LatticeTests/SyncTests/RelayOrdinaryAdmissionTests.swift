import Foundation
import Testing
import NIOCore
import NIOConcurrencyHelpers
@testable import LatticeServerKit

private final class AdmissionRetirementWitness: @unchecked Sendable {
    let admission: RelayOrdinaryAdmission
    let retired: NIOLockedValueBox<Int>
    init(_ admission: RelayOrdinaryAdmission, _ retired: NIOLockedValueBox<Int>) {
        self.admission = admission; self.retired = retired
    }
    deinit {
        // Real destructor reenters the same production service lock.
        _ = admission.snapshot
        retired.withLockedValue { $0 += 1 }
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct RelayOrdinaryAdmissionTests {
    @Test func realChargedIngressAndCopiedPayloadSurviveWaitingUntilCancellationSettlement() throws {
        let budget = RelayOrdinaryBudget(), ingress = RelayIngressAdmission()
        let account = ingress.makeAccount()
        let buffer = ByteBuffer(string: "retained-input")
        var held: [RelayOrdinaryBudget.Charge] = []
        for _ in 0..<4 { held.append(try budget.reserve(.staging)) }
        var frame: RelayIngressFrame? = try account.copyFrame(buffer)
        weak var weakFrame = frame
        let observed = NIOLockedValueBox<(calls: Int, bytes: Int, refused: Bool)>((0,0,false))
        do {
        let request: RelayOrdinaryAdmission.Request
        do {
            let ownedFrame = try #require(frame)
            request = budget.request(.staging) { result in
                let copy = ownedFrame.copyForApply()
                observed.withLockedValue {
                    $0.calls += 1; $0.bytes = copy.count
                    if case .failure(.cancelled) = result { $0.refused = true }
                }
            }
        }
        request.begin(); frame = nil
        #expect(weakFrame != nil && account.snapshot.inputBytes == buffer.readableBytes)
        #expect(budget.waiting.queuedStaging == 1 && observed.withLockedValue { $0.calls } == 0)
        request.cancel()
        #expect(observed.withLockedValue { $0.calls == 1 && $0.bytes == buffer.readableBytes && $0.refused })
        #expect(budget.waiting.queuedStaging == 0 && budget.snapshot.staging == 4)
        // The retained Request still owns its real callback/frame here. Mere
        // cancellation deliberately cannot report those bytes already gone.
        #expect(weakFrame != nil && account.snapshot.inputBytes == buffer.readableBytes)
        withExtendedLifetime(request) {}
        }
        #expect(weakFrame == nil && account.snapshot.inputBytes == 0)
        held.removeAll()
        #expect(budget.snapshot.staging == 0)
    }

    @Test func finalRequestCaptureAndCancelledOwnerAreDestroyedOutsideAdmissionLock() throws {
        let service = RelayOrdinaryAdmission(cuts: 1, staging: 1)
        let held = try service.reserve(.cut)
        let retired = NIOLockedValueBox(0)
        var request: RelayOrdinaryAdmission.Request?
        do {
            let owner = AdmissionRetirementWitness(service, retired)
            request = service.request(.cut) { [owner] _ in withExtendedLifetime(owner) {} }
        }
        request?.begin(); request?.cancel(); request = nil
        #expect(retired.withLockedValue { $0 } == 1)
        #expect(service.snapshot.queuedCuts == 0 && service.snapshot.activeCuts == 1)
        withExtendedLifetime(held) {}
    }

    @Test func fifoTransferCannotBeStolenBySynchronousReserveDuringActualLeaseRelease() throws {
        let service = RelayOrdinaryAdmission(cuts: 1, staging: 1)
        var held: RelayOrdinaryAdmission.Lease? = try service.reserve(.cut)
        let admitted = NIOLockedValueBox<[Int]>([])
        let leases = NIOLockedValueBox<[RelayOrdinaryAdmission.Lease]>([])
        var requests: [RelayOrdinaryAdmission.Request] = []
        for index in 0..<8 {
            let request = service.request(.cut) { result in
                if case .success(let lease) = result {
                    admitted.withLockedValue { $0.append(index) }
                    leases.withLockedValue { $0.append(lease) }
                }
            }
            requests.append(request); request.begin()
        }
        #expect(service.snapshot.queuedCuts == 8)
        #expect(throws: RelayOrdinaryError.self) { try service.reserve(.cut) }
        held = nil
        for index in 0..<8 {
            #expect(admitted.withLockedValue { $0 } == Array(0...index))
            // Retain the removed lease across this lock before its actual final
            // release can synchronously grant another callback that reenters it.
            var lease: RelayOrdinaryAdmission.Lease? = leases.withLockedValue { $0.removeFirst() }
            lease = nil
            withExtendedLifetime(lease) {}
        }
        #expect(service.snapshot.activeCuts == 0 && service.snapshot.queuedCuts == 0)
        withExtendedLifetime((held,requests)) {}
    }
}
