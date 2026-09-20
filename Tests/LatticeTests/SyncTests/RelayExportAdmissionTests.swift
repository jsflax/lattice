import Foundation
import Testing
import NIOConcurrencyHelpers
@testable import LatticeServerKit

@Suite(.timeLimit(.minutes(1)))
struct RelayExportAdmissionTests {
    private func service(endpoints: Int = 2, pages: Int = 2,
                         nativeBytes: Int = 16, outputBytes: Int = 24) throws -> RelayExportAdmission {
        try .init(limits: .init(endpoints: endpoints, pages: pages,
                               nativeBytes: nativeBytes, outputBytes: outputBytes))
    }

    private func refuse<T>(_ reason: RelayExportAdmissionError, _ body: () throws -> T) {
        do { _ = try body(); Issue.record("expected export admission refusal") }
        catch { #expect(error as? RelayExportAdmissionError == reason) }
    }

    private func retire(_ endpoint: RelayExportAdmission.Endpoint) {
        endpoint.beginRetirement(); endpoint.confirmNativeRelease()
    }

    @Test func stoppedEndpointsRemainChargedAcrossRepeatedReconnectAttempts() throws {
        let ledger = try service(endpoints: 1)
        let endpoint = try ledger.reserveEndpoint()
        #expect(!endpoint.confirmNativeRelease(), "a live endpoint is not retired")
        #expect(endpoint.beginRetirement())
        for _ in 0..<64 {
            #expect(!endpoint.beginRetirement(), "only one caller submits retirement")
            refuse(.endpoints) { try ledger.reserveEndpoint() }
        }
        #expect(ledger.snapshot.endpoints == 1)
        #expect(endpoint.confirmNativeRelease())
        #expect(!endpoint.confirmNativeRelease())
        #expect(ledger.snapshot.endpoints == 0)
        let successor = try ledger.reserveEndpoint()
        refuse(.endpointStopped) { try endpoint.reservePage(nativeBytes: 1, outputBytes: 1) }
        retire(successor)
        #expect(ledger.snapshot.endpoints == 0)
    }

    @Test func inlineTransportSettlementCannotReleaseAnActiveNativeTurn() throws {
        let ledger = try service(endpoints: 1, pages: 1)
        let endpoint = try ledger.reserveEndpoint()
        let page = try endpoint.reservePage(nativeBytes: 16, outputBytes: 24)
        #expect(page.confirmTransportSettlement())
        #expect(ledger.snapshot == .init(closed: false, endpoints: 1, pages: 1,
                                        nativeBytes: 16, outputBytes: 0))
        refuse(.pageBusy) { try endpoint.reservePage(nativeBytes: 1, outputBytes: 1) }
        retire(endpoint)
        refuse(.endpoints) { try ledger.reserveEndpoint() }
        #expect(page.confirmNativeRelease())
        #expect(ledger.snapshot == .init(closed: false, endpoints: 0, pages: 0,
                                        nativeBytes: 0, outputBytes: 0))
    }

    @Test func nativeRetirementCannotReleaseAnUnsettledPromiseOrItsEndpoint() throws {
        let ledger = try service(endpoints: 1, pages: 1)
        let endpoint = try ledger.reserveEndpoint()
        let page = try endpoint.reservePage(nativeBytes: 16, outputBytes: 24)
        #expect(page.confirmNativeRelease())
        retire(endpoint)
        #expect(ledger.snapshot == .init(closed: false, endpoints: 1, pages: 1,
                                        nativeBytes: 0, outputBytes: 24))
        for _ in 0..<64 { refuse(.endpoints) { try ledger.reserveEndpoint() } }
        #expect(page.confirmTransportSettlement())
        #expect(ledger.snapshot.endpoints == 0 && ledger.snapshot.pages == 0)
        #expect(ledger.snapshot.outputBytes == 0)
    }

    @Test func capsAreSharedAcrossEndpointsAndRefusalDoesNotPartiallyCharge() throws {
        let ledger = try service(endpoints: 3, pages: 2)
        let one = try ledger.reserveEndpoint(), two = try ledger.reserveEndpoint(), three = try ledger.reserveEndpoint()
        let first = try one.reservePage(nativeBytes: 9, outputBytes: 10)
        let before = ledger.snapshot
        refuse(.nativeBytes) { try two.reservePage(nativeBytes: 8, outputBytes: 1) }
        refuse(.outputBytes) { try two.reservePage(nativeBytes: 7, outputBytes: 15) }
        refuse(.invalidCharge) { try two.reservePage(nativeBytes: -1, outputBytes: 1) }
        refuse(.invalidCharge) { try two.reservePage(nativeBytes: 1, outputBytes: 0) }
        #expect(ledger.snapshot == before)
        let second = try two.reservePage(nativeBytes: 7, outputBytes: 14)
        refuse(.pages) { try three.reservePage(nativeBytes: 1, outputBytes: 1) }
        #expect(ledger.snapshot.nativeBytes == 16 && ledger.snapshot.outputBytes == 24)
        first.confirmNativeRelease(); first.confirmTransportSettlement()
        let third = try three.reservePage(nativeBytes: 9, outputBytes: 10)
        second.confirmTransportSettlement(); second.confirmNativeRelease()
        third.confirmNativeRelease(); third.confirmTransportSettlement()
        [one, two, three].forEach(retire)
        #expect(ledger.snapshot.endpoints == 0 && ledger.snapshot.pages == 0)
    }

    @Test func staleAndDuplicateWitnessesCannotReleaseASuccessorPage() throws {
        let ledger = try service(endpoints: 1)
        let endpoint = try ledger.reserveEndpoint()
        let first = try endpoint.reservePage(nativeBytes: 8, outputBytes: 12)
        first.confirmNativeRelease(); first.confirmTransportSettlement()
        let next = try endpoint.reservePage(nativeBytes: 16, outputBytes: 24)
        let held = ledger.snapshot
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            #expect(!first.confirmNativeRelease())
            #expect(!first.confirmTransportSettlement())
        }
        #expect(ledger.snapshot == held)
        next.confirmTransportSettlement(); next.confirmNativeRelease(); retire(endpoint)
        #expect(ledger.snapshot.endpoints == 0 && ledger.snapshot.nativeBytes == 0)
    }

    @Test func concurrentReservationsAndReleaseCopiesKeepExactGlobalCaps() throws {
        let ledger = try service(endpoints: 4, pages: 4, nativeBytes: 4, outputBytes: 4)
        let held = NIOLockedValueBox<[RelayExportAdmission.Endpoint]>([])
        let refusals = NIOLockedValueBox(0)
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            do { let endpoint = try ledger.reserveEndpoint(); held.withLockedValue { $0.append(endpoint) } }
            catch {
                #expect(error as? RelayExportAdmissionError == .endpoints)
                refusals.withLockedValue { $0 += 1 }
            }
        }
        let endpoints = held.withLockedValue { $0 }
        #expect(endpoints.count == 4 && refusals.withLockedValue { $0 } == 60)
        let pages = try endpoints.map { try $0.reservePage(nativeBytes: 1, outputBytes: 1) }
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            let selected = index % 4
            endpoints[selected].beginRetirement()
            endpoints[selected].confirmNativeRelease()
            if index.isMultiple(of: 2) {
                pages[selected].confirmNativeRelease(); pages[selected].confirmTransportSettlement()
            } else {
                pages[selected].confirmTransportSettlement(); pages[selected].confirmNativeRelease()
            }
        }
        #expect(ledger.snapshot == .init(closed: false, endpoints: 0, pages: 0,
                                        nativeBytes: 0, outputBytes: 0))
    }

    @Test func closeFencesNewAdmissionAndPreservesOutstandingReleaseObligations() throws {
        let ledger = try service()
        let active = try ledger.reserveEndpoint(), idle = try ledger.reserveEndpoint()
        let page = try active.reservePage(nativeBytes: 8, outputBytes: 12)
        let before = ledger.snapshot
        ledger.closeAdmission(); ledger.closeAdmission()
        #expect(ledger.snapshot == .init(closed: true, endpoints: before.endpoints, pages: before.pages,
                                        nativeBytes: before.nativeBytes, outputBytes: before.outputBytes))
        refuse(.closed) { try ledger.reserveEndpoint() }
        refuse(.closed) { try idle.reservePage(nativeBytes: 1, outputBytes: 1) }
        retire(active); retire(idle)
        #expect(ledger.snapshot.endpoints == 1)
        page.confirmTransportSettlement(); page.confirmNativeRelease()
        #expect(ledger.snapshot == .init(closed: true, endpoints: 0, pages: 0,
                                        nativeBytes: 0, outputBytes: 0))
    }

    @Test func handleDestructionIsNotEvidenceThatForeignPayloadsWereReleased() throws {
        let ledger = try service(endpoints: 1)
        var endpoint: RelayExportAdmission.Endpoint? = try ledger.reserveEndpoint()
        var page: RelayExportAdmission.Page? = try endpoint?.reservePage(nativeBytes: 8, outputBytes: 12)
        weak var droppedEndpoint = endpoint
        weak var droppedPage = page
        endpoint?.beginRetirement()
        page = nil; endpoint = nil
        #expect(droppedPage == nil && droppedEndpoint == nil)
        #expect(ledger.snapshot == .init(closed: false, endpoints: 1, pages: 1,
                                        nativeBytes: 8, outputBytes: 12))
        refuse(.endpoints) { try ledger.reserveEndpoint() }
        // The IO wrapper is required to retain these witnesses through actual
        // cleanup. This component cannot invent a release after misuse.
    }

    @Test func maximumIntegerChargesRefuseOverflowAndRequirePositiveBudgets() throws {
        refuse(.invalidLimits) { try service(endpoints: 0) }
        refuse(.invalidLimits) { try service(pages: 0) }
        refuse(.invalidLimits) { try service(nativeBytes: 0) }
        refuse(.invalidLimits) { try service(outputBytes: -1) }
        let ledger = try service(nativeBytes: .max, outputBytes: .max)
        let one = try ledger.reserveEndpoint(), two = try ledger.reserveEndpoint()
        let first = try one.reservePage(nativeBytes: .max, outputBytes: .max)
        refuse(.nativeBytes) { try two.reservePage(nativeBytes: 1, outputBytes: 1) }
        first.confirmNativeRelease()
        refuse(.outputBytes) { try two.reservePage(nativeBytes: .max, outputBytes: 1) }
        first.confirmTransportSettlement()
        let next = try two.reservePage(nativeBytes: .max, outputBytes: .max)
        next.confirmTransportSettlement(); next.confirmNativeRelease()
        retire(one); retire(two)
        #expect(ledger.snapshot.endpoints == 0 && ledger.snapshot.nativeBytes == 0 && ledger.snapshot.outputBytes == 0)
    }
}
