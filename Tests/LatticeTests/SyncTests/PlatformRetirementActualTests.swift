import Foundation
import Dispatch
import Testing
import Vapor
import CxxStdlib
import NIOConcurrencyHelpers
import LatticeServerExportTestSupport
@testable import Lattice

#if os(Linux)
private typealias RetirementActualClient = NIOWebsocketClient
#else
private typealias RetirementActualClient = Lattice.WebsocketClient
#endif
private enum RetirementActualError: Error { case timeout, missingPort }

private enum RetirementActualFailurePhase: String, Sendable {
    case connect, open, send, echo, request, adapterCleanup, nativeCollection, clientRelease, serverClose, assertions
}
private final class RetirementActualFailureObservation: Sendable {
    private let current = NIOLockedValueBox(RetirementActualFailurePhase.connect)
    func phase(_ value: RetirementActualFailurePhase) { current.withLockedValue { $0 = value } }
    func record(_ fixture: RetirementActualFixture, _ probe: RetirementActualProbe, _ serverCloses: NIOLockedValueBox<Int>) {
        let facts = fixture.native.facts()
        // Sequential copied facts, not an atomic cross-platform snapshot.
        // No endpoint, callback, receipt, error text or source payload is saved.
        let value: [String: Any] = [
            "schema": "platform-retirement-failure-v1", "phase": current.withLockedValue { $0.rawValue },
            "snapshot": "sequentialFailureOnly", "issued": facts.issued, "requested": facts.requested,
            "adapterComplete": facts.adapter_complete, "nativeComplete": facts.native_complete,
            "quarantined": facts.quarantined, "closing": facts.closing, "collected": facts.collected,
            "firstError": facts.first_error, "bridgeUses": facts.bridge_uses, "callbackUses": facts.callback_uses,
            "opens": facts.opens, "messages": facts.messages, "errors": facts.errors, "closes": facts.closes,
            "chargedOwners": facts.charged_owners, "nativeSafetyRelease": facts.safety_release,
            "clientReleased": fixture.client == nil, "serverCloses": serverCloses.withLockedValue { $0 },
            "probeSafetyRelease": probe.safetyReleased, "probeOverflow": probe.overflowed,
            "appleInvalidatedOK": probe.count(.appleSessionInvalidated(0)),
            "appleInvalidatedError": probe.count(.appleSessionInvalidated(2)),
            "appleFenceOK": probe.count(.appleInvalidationFence(0)),
            "appleFenceError": probe.count(.appleInvalidationFence(2)),
            "dnsReturned": probe.count(.dnsWorkReturned), "dnsPublished": probe.count(.dnsQueriesPublished),
            "dnsNotify": probe.count(.dnsNotifyEnqueued), "nioJoinedOK": probe.count(.nioGroupShutdown(0)),
            "nioJoinError": probe.count(.nioGroupShutdown(1))
        ]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           data.count <= 4096, let line = String(data: data, encoding: .utf8) {
            print("PLATFORM_RETIREMENT_FAILURE " + line)
        } else { print("PLATFORM_RETIREMENT_FAILURE snapshot_unavailable") }
    }
}

// Holds only a real lifecycle callback, never a synthetic cleanup completion.
// Its fixed safety release is an explicit failing observation, not success.
private final class RetirementActualProbe: @unchecked Sendable {
    private struct State {
        var events: [PlatformRetirementLifecycleEvent] = []
        var held = false
        var safetyRelease = false
        var overflow = false
    }
    private let state = NIOLockedValueBox(State())
    private let hold: PlatformRetirementLifecycleEvent?
    private let releaseGate = DispatchSemaphore(value: 0)
    init(hold: PlatformRetirementLifecycleEvent? = nil) { self.hold = hold }
    func observe(_ event: PlatformRetirementLifecycleEvent) {
        let shouldHold = state.withLockedValue { state in
            // Exactly six named lifecycle boundaries, each occurs at most once
            // for this single dial. Refuse unbounded diagnostic accumulation.
            if state.events.count < 16 { state.events.append(event) }
            else { state.overflow = true }
            guard event == hold, !state.held else { return false }
            state.held = true
            return true
        }
        if shouldHold, releaseGate.wait(timeout: .now() + .seconds(10)) == .timedOut {
            state.withLockedValue { $0.safetyRelease = true }
        }
    }
    var isHeld: Bool { state.withLockedValue { $0.held } }
    var safetyReleased: Bool { state.withLockedValue { $0.safetyRelease } }
    var overflowed: Bool { state.withLockedValue { $0.overflow } }
    func count(_ event: PlatformRetirementLifecycleEvent) -> Int { state.withLockedValue { $0.events.filter { $0 == event }.count } }
    func saw(_ event: PlatformRetirementLifecycleEvent) -> Bool { state.withLockedValue { $0.events.contains(event) } }
    func precedes(_ first: PlatformRetirementLifecycleEvent, _ second: PlatformRetirementLifecycleEvent) -> Bool {
        state.withLockedValue { state in
            guard let a = state.events.firstIndex(of: first), let b = state.events.firstIndex(of: second) else { return false }
            return a < b
        }
    }
    func release() { releaseGate.signal() }
}

private final class RetirementActualRequestReceiver: @unchecked Sendable {
    let client: RetirementActualClient
    let deliveries: NIOLockedValueBox<(count: Int, accepted: Bool)>
    init(_ client: RetirementActualClient, deliveries: NIOLockedValueBox<(count: Int, accepted: Bool)>) {
        self.client = client; self.deliveries = deliveries
    }
    func request(_ receipt: lattice.platform_retirement_receipt) {
        let accepted = client.requestRetirement(receipt)
        deliveries.withLockedValue { $0.count += 1; $0.accepted = accepted }
    }
}

private final class RetirementActualFixture: @unchecked Sendable {
    var native: lattice.platform_retirement_test_driver
    weak var client: RetirementActualClient?
    let deliveries = NIOLockedValueBox((count: 0, accepted: false))
    let originalReceipt: lattice.platform_retirement_receipt
    private let probe: RetirementActualProbe?
    init(probe: RetirementActualProbe? = nil) throws {
        // This receipt is issued by a real registry reservation before client
        // construction starts a NIO group or any platform resource.
        let native = lattice.platform_retirement_test_driver()
        self.native = native
        self.probe = probe
        originalReceipt = native.issued_receipt()
        let retirement = try #require(PlatformTransportRetirement(originalReceipt))
        let observation: PlatformRetirementLifecycleObserver?
        if let probe { observation = { event in probe.observe(event) } }
        else { observation = nil }
        let client = RetirementActualClient(retirement: retirement, retirementObservation: observation)
        self.client = client
        let transport = try #require(client.createCxxClient())
        try #require(native.install(transport))
        let receiver = RetirementActualRequestReceiver(client, deliveries: deliveries)
        let userdata = Unmanaged.passRetained(receiver).toOpaque()
        // The native holder consumes userdata even on refusal and keeps it
        // alive through actual once-only request delivery before dereferencing.
        let requestBound = native.bind_request(userdata, { pointer, receipt in
            guard let pointer, let receipt else { return }
            let receiver = Unmanaged<RetirementActualRequestReceiver>.fromOpaque(pointer).takeUnretainedValue()
            receiver.request(receipt.assumingMemoryBound(to: lattice.platform_retirement_receipt.self).pointee)
        }, { pointer in
            guard let pointer else { return }
            _ = Unmanaged<RetirementActualRequestReceiver>.fromOpaque(pointer).takeRetainedValue()
        })
        try #require(requestBound)
    }
    func wait(_ predicate: () -> Bool) async throws {
        let until = ContinuousClock.now.advanced(by: .seconds(10))
        while !predicate() {
            guard ContinuousClock.now < until else { throw RetirementActualError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func request() throws {
        try #require(native.request_retirement())
        #expect(deliveries.withLockedValue { $0.count } == 1)
        #expect(deliveries.withLockedValue { $0.accepted })
        #expect(!native.request_retirement())
        #expect(deliveries.withLockedValue { $0.count } == 1)
    }
    func collectActualCompletion(observation: RetirementActualFailureObservation? = nil) async throws {
        observation?.phase(.adapterCleanup)
        try await wait { native.facts().adapter_complete || native.facts().first_error != 0 }
        let before = native.facts()
        try #require(before.adapter_complete)
        try #require(before.first_error == 0)
        #expect(!before.native_complete)
        #expect(before.bridge_uses == 0)
        #expect(before.callback_uses == 0)
        #expect(!before.safety_release)
        // Native settlement cannot precede this actual adapter result. The
        // driver drops its final transport alias before explicit collection.
        observation?.phase(.nativeCollection)
        try #require(native.collect_if_settled())
        #expect(!originalReceipt.valid())
        #expect(native.facts().collected)
        observation?.phase(.clientRelease)
        try await wait { client == nil }
        #expect(probe?.safetyReleased != true)
        #expect(probe?.overflowed != true)
    }
    deinit {
        native.release_message_hold()
        _ = native.request_retirement()
        // Never synthesize adapter/native success in error cleanup. The real
        // process-lived registry retains any unfinished attempt and its debt.
    }
}

private func withRetirementActualPeer(_ body: (String, NIOLockedValueBox<Int>) async throws -> Void) async throws {
    var environment = try Environment.detect(); environment.arguments = ["vapor"]
    let app = try await Application.make(environment)
    app.http.server.configuration.hostname = "127.0.0.1"
    app.http.server.configuration.port = 0
    let closes = NIOLockedValueBox(0)
    app.webSocket("retirement-actual") { _, socket in
        socket.onText { socket, text in socket.send(text) }
        socket.onClose.whenComplete { _ in closes.withLockedValue { $0 += 1 } }
    }
    do {
        try await app.startup()
        guard let port = app.http.server.shared.localAddress?.port else { throw RetirementActualError.missingPort }
        // A hostname deliberately exercises actual getaddrinfo on Linux.
        try await body("ws://localhost:\(port)/retirement-actual", closes)
        try await app.asyncShutdown()
    } catch {
        do { try await app.asyncShutdown() }
        catch { Issue.record("Actual retirement peer shutdown failed: \(error)") }
        throw error
    }
}

@Suite(.serialized) struct PlatformRetirementActualTests {
    @Test func nativeIssuedNeverDialedOwnerRequiresActualAdapterCompletion() async throws {
        let probe = RetirementActualProbe()
        let fixture = try RetirementActualFixture(probe: probe)
        #expect(fixture.originalReceipt.valid())
        #expect(!fixture.native.collect_if_settled())
        try fixture.request()
        try await fixture.collectActualCompletion()
        #if os(Linux)
        #expect(probe.saw(.nioGroupShutdown(0)))
        #expect(!probe.saw(.dnsWorkReturned))
        #else
        // No URLSession existed; this case does not qualify session cleanup.
        #expect(!probe.saw(.appleSessionInvalidated(0)))
        #endif
    }

    @Test func actualHostnameEchoRetiresSocketSessionAndNativeCustody() async throws {
        try await withRetirementActualPeer { url, closes in
            let probe = RetirementActualProbe()
            let fixture = try RetirementActualFixture(probe: probe)
            let observation = RetirementActualFailureObservation()
            do {
                try #require(fixture.native.connect(std.string(url)))
                observation.phase(.open)
                try await fixture.wait { fixture.native.facts().opens == 1 || fixture.native.facts().errors > 0 }
                try #require(fixture.native.facts().opens == 1)
                #expect(fixture.native.facts().errors == 0)
                observation.phase(.send)
                try #require(fixture.native.send_text(std.string("actual-retirement-echo")))
                observation.phase(.echo)
                try await fixture.wait { fixture.native.facts().messages == 1 }
                observation.phase(.request)
                try fixture.request()
                try await fixture.collectActualCompletion(observation: observation)
                observation.phase(.serverClose)
                try await fixture.wait { closes.withLockedValue { $0 } == 1 }
                observation.phase(.assertions)
                #if os(Linux)
                #expect(probe.saw(.dnsWorkReturned))
                #expect(probe.precedes(.dnsWorkReturned, .dnsQueriesPublished))
                #expect(probe.saw(.nioGroupShutdown(0)))
                #else
                #expect(probe.precedes(.appleSessionInvalidated(0), .appleInvalidationFence(0)))
                #endif
                #expect(!probe.safetyReleased)
            } catch {
                observation.record(fixture, probe, closes)
                throw error
            }
        }
    }

    @Test func actualReceiveCallbackCannotBeCollectedWhileItIsStillRunning() async throws {
        try await withRetirementActualPeer { url, _ in
            let fixture = try RetirementActualFixture()
            defer { fixture.native.release_message_hold() }
            try #require(fixture.native.arm_message_hold())
            try #require(fixture.native.connect(std.string(url)))
            try await fixture.wait { fixture.native.facts().opens == 1 || fixture.native.facts().errors > 0 }
            try #require(fixture.native.facts().opens == 1)
            try #require(fixture.native.send_text(std.string("hold-real-receive")))
            try await fixture.wait { fixture.native.facts().hold_entered }
            #expect(fixture.native.facts().callback_uses == 1)
            try fixture.request()
            #expect(!fixture.native.facts().adapter_complete)
            #expect(!fixture.native.collect_if_settled())
            #expect(fixture.originalReceipt.valid())
            fixture.native.release_message_hold()
            try await fixture.collectActualCompletion()
            #expect(!fixture.native.facts().safety_release)
        }
    }

    #if os(Linux)
    @Test func actualDNSNotificationOutlivesJoinedGroupAndStillBlocksReceipt() async throws {
        try await withRetirementActualPeer { url, _ in
            let probe = RetirementActualProbe(hold: .dnsNotifyEnqueued)
            defer { probe.release() }
            let fixture = try RetirementActualFixture(probe: probe)
            try #require(fixture.native.connect(std.string(url)))
            try await fixture.wait { probe.isHeld }
            #expect(probe.saw(.dnsWorkReturned))
            try fixture.request()
            try await fixture.wait { probe.saw(.nioGroupShutdown(0)) }
            #expect(probe.saw(.dnsQueriesPublished))
            // The group is truly joined. The independently scheduled real
            // notify callback still owns the admitted Pending until released.
            #expect(!fixture.native.facts().adapter_complete)
            #expect(!fixture.native.collect_if_settled())
            #expect(fixture.originalReceipt.valid())
            probe.release()
            try await fixture.collectActualCompletion()
            #expect(!probe.safetyReleased)
        }
    }
    #else
    @Test func actualDisconnectedSessionWaitsForItsInvalidationFence() async throws {
        try await withRetirementActualPeer { url, _ in
            let probe = RetirementActualProbe(hold: .appleInvalidationFence(0))
            defer { probe.release() }
            let fixture = try RetirementActualFixture(probe: probe)
            try #require(fixture.native.connect(std.string(url)))
            try await fixture.wait { fixture.native.facts().opens == 1 || fixture.native.facts().errors > 0 }
            try #require(fixture.native.facts().opens == 1)
            try #require(fixture.native.disconnect())
            try await fixture.wait { probe.isHeld }
            #expect(probe.saw(.appleSessionInvalidated(0)))
            try fixture.request()
            #expect(!fixture.native.facts().adapter_complete)
            #expect(!fixture.native.collect_if_settled())
            probe.release()
            try await fixture.collectActualCompletion()
            #expect(!probe.safetyReleased)
        }
    }
    #endif

    #if os(Linux)
    @Test func invalidPortDoesNotStartDNSButStillRequiresActualGroupCleanup() async throws {
        let probe = RetirementActualProbe()
        let fixture = try RetirementActualFixture(probe: probe)
        try #require(fixture.native.connect(std.string("ws://localhost:0/retirement-actual")))
        try await fixture.wait { fixture.native.facts().errors > 0 }
        #expect(fixture.native.facts().opens == 0)
        try fixture.request()
        try await fixture.collectActualCompletion()
        #expect(!probe.saw(.dnsWorkReturned))
        #expect(probe.saw(.nioGroupShutdown(0)))
    }
    #endif

    @Test func protectedSecondConnectCannotCreateASecondPhysicalDial() async throws {
        try await withRetirementActualPeer { url, closes in
            let probe = RetirementActualProbe()
            let fixture = try RetirementActualFixture(probe: probe)
            try #require(fixture.native.connect(std.string(url)))
            try await fixture.wait { fixture.native.facts().opens == 1 || fixture.native.facts().errors > 0 }
            try #require(fixture.native.facts().opens == 1)
            // The native bridge can be entered, but protected adapter admission
            // refuses a second physical dial and retains the original custody.
            try #require(fixture.native.connect(std.string(url)))
            try fixture.request()
            try await fixture.collectActualCompletion()
            try await fixture.wait { closes.withLockedValue { $0 } == 1 }
            #expect(fixture.native.facts().opens == 1)
            #if os(Linux)
            #expect(probe.count(.dnsWorkReturned) == 1)
            #expect(probe.count(.nioGroupShutdown(0)) == 1)
            #else
            #expect(probe.count(.appleSessionInvalidated(0)) == 1)
            #expect(probe.count(.appleInvalidationFence(0)) == 1)
            #endif
        }
    }
}
