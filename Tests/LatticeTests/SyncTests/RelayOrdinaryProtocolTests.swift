import Foundation
import Testing
import NIOConcurrencyHelpers
import Lattice
@testable import LatticeServerKit

@Suite(.serialized, .timeLimit(.minutes(1)))
struct RelayOrdinaryProtocolTests {
    private let request = "11111111-1111-4111-8111-111111111111"
    private func control(_ body: [String: Any]) throws -> RelayOrdinaryControl {
        try .decode(JSONSerialization.data(withJSONObject: ["latticeOrdinarySync": body]))
    }
    private func identity(cut: String = "1") throws -> RelayOrdinaryIdentity {
        try .init(["source": "fixture", "epoch": "1", "cut": cut, "contentDigest": String(repeating: "a", count: 64)])
    }
    private func rejects(_ body: () throws -> Void) {
        do { try body(); Issue.record("expected ordinary control refusal") } catch {}
    }

    @Test func requestAndReceiptHaveClosedDistinctShapes() throws {
        let decoded = try control(["version": 2, "kind": "request", "request": request])
        #expect(decoded == .request(request))
        let expected = try identity()
        let receipt = try control(["version": 2, "kind": "receipt", "source": expected.source,
                                   "epoch": expected.epoch, "cut": expected.cut, "contentDigest": expected.contentDigest])
        #expect(receipt == .receipt(expected))
        for kind in ["offer", "cut", "page", "ack"] {
            rejects { _ = try control(["version": 2, "kind": kind, "request": request]) }
        }
        rejects { _ = try control(["version": true, "kind": "request", "request": request]) }
        rejects { _ = try control(["version": 2, "kind": "request", "request": request, "ack": []]) }
    }

    @Test func duplicateEscapedKeysAndMixedUploadCannotSelectAControl() throws {
        let good = #"{"latticeOrdinarySync":{"version":2,"kind":"request","request":"11111111-1111-4111-8111-111111111111"}}"#
        _ = try RelayOrdinaryControl.decode(Data(good.utf8))
        let bad = [
            good.replacingOccurrences(of: #""version":2"#, with: #""version":2,"\u0076ersion":2"#),
            good.replacingOccurrences(of: #""kind":"request""#, with: #""kind":"receipt","kind":"request""#),
            String(good.dropLast()) + #", "auditLog":[]}"#,
            good + " {}",
            good.replacingOccurrences(of: request, with: String(repeating: "x", count: 4_096))
        ]
        for bytes in bad { rejects { _ = try RelayOrdinaryControl.decode(Data(bytes.utf8)) } }
        rejects { _ = try identity(cut: "+1") }
        rejects { _ = try identity(cut: "01") }
        rejects { _ = try identity(cut: "18446744073709551616") }
    }

    @Test func receiptBeforeLastSubmissionAndWrongCurrentCutNeverRelease() throws {
        let first = try identity(), next = try identity(cut: "2")
        var state = RelayOrdinaryReceiptState()
        state.begin(first)
        rejects { try state.receive(first) }
        #expect(!state.received && !state.settled)
        state.finalSubmitted()
        rejects { try state.receive(next) }
        #expect(!state.received && !state.settled)
        try state.receive(first)
        #expect(state.received && !state.settled)
        rejects { try state.receive(first) }
        state.finalCompleted()
        #expect(state.settled)
        state = .init(); state.begin(next); state.finalSubmitted(); state.finalCompleted()
        rejects { try state.receive(first) }
        #expect(!state.settled)
        try state.receive(next)
        #expect(state.settled)
    }

    @Test func globalCaptureAndCopyAdmissionRemainChargedUntilLastOwnerDrops() throws {
        let budget = RelayOrdinaryBudget(endpoints: 1, cuts: 1, staging: 1)
        var endpoint: RelayOrdinaryBudget.Charge? = try budget.reserve(.endpoint)
        var cut: RelayOrdinaryBudget.Charge? = try budget.reserve(.cut)
        var copy: RelayOrdinaryBudget.Charge? = try budget.reserve(.staging)
        var retainedCopy = copy
        let before = budget.snapshot
        rejects { _ = try budget.reserve(.endpoint) }
        rejects { _ = try budget.reserve(.cut) }
        rejects { _ = try budget.reserve(.staging) }
        #expect(budget.snapshot == before)
        #expect(before.stagingBytes == 8_388_608)
        withExtendedLifetime((endpoint, cut, copy, retainedCopy)) {}
        endpoint = nil; cut = nil; copy = nil
        #expect(budget.snapshot == .init(endpoints: 0, cuts: 0, staging: 1, stagingBytes: 8_388_608))
        rejects { _ = try budget.reserve(.staging) }
        retainedCopy = nil
        #expect(budget.snapshot == .init(endpoints: 0, cuts: 0, staging: 0, stagingBytes: 0))
    }

    @Test func concurrentCaptureReservationsCannotExceedSharedBound() throws {
        let budget = RelayOrdinaryBudget(cuts: 4)
        let held = NIOLockedValueBox<[RelayOrdinaryBudget.Charge]>([])
        let refused = NIOLockedValueBox(0)
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            do {
                let charge = try budget.reserve(.cut)
                held.withLockedValue { $0.append(charge) }
            } catch { refused.withLockedValue { $0 += 1 } }
        }
        #expect(budget.snapshot.cuts == 4)
        #expect(refused.withLockedValue { $0 } == 28)
        held.withLockedValue { $0.removeAll() }
        #expect(budget.snapshot.cuts == 0)
    }

    @Test func actualIssuedCutBytesStayImmutableAcrossLaterCommittedWrites() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ordinary-issued-\(UUID().uuidString).sqlite")
        let store = try Lattice(SimpleSyncObject.self, configuration: .init(fileURL: url))
        defer { let close = store.closeChecked(); #expect(!close.failed && !close.cleanupFailed && close.cleanupComplete) }
        try store.add(SimpleSyncObject(value: 1, floatValue: 1))
        let cut = try store.captureOrdinarySyncExport()
        let before = try (0..<cut.frameCount).map { try cut.frame(at: $0) }
        let firstIdentity = try RelayOrdinaryIdentity.header(before[0])
        try store.add(SimpleSyncObject(value: 2, floatValue: 2))
        let after = try (0..<cut.frameCount).map { try cut.frame(at: $0) }
        #expect(before == after)
        let successor = try store.captureOrdinarySyncExport()
        let successorIdentity = try RelayOrdinaryIdentity.header(successor.frame(at: 0))
        #expect(firstIdentity != successorIdentity)
        #expect(firstIdentity.source == successorIdentity.source)
    }
}
