import Foundation
import Dispatch
import Testing
import Vapor
import CxxStdlib
import NIOConcurrencyHelpers
import LatticeServerExportTestSupport
@testable import Lattice

private enum ConfiguredActualFailure: Error { case deadline, missingPort }

// An observation can pause only a boundary the actual constructor reached.
// It supplies neither an adapter cleanup result nor a native settlement flag.
private final class ConfiguredActualProbe: @unchecked Sendable {
    private struct State {
        var construction: [ConfiguredPlatformConstructionEvent] = []
        var platform: [PlatformRetirementLifecycleEvent] = []
        var held = false
        var safetyRelease = false
        var overflow = false
    }
    private let state = NIOLockedValueBox(State())
    private let heldEvent: ConfiguredPlatformConstructionEvent?
    private let heldPlatform: PlatformRetirementLifecycleEvent?
    private let releaseGate = DispatchSemaphore(value: 0)
    init(hold: ConfiguredPlatformConstructionEvent? = nil,
         platformHold: PlatformRetirementLifecycleEvent? = nil) {
        heldEvent = hold; heldPlatform = platformHold
    }
    func construction(_ event: ConfiguredPlatformConstructionEvent) {
        let hold = state.withLockedValue { state in
            if state.construction.count < 16 { state.construction.append(event) }
            else { state.overflow = true }
            guard event == heldEvent, !state.held else { return false }
            state.held = true
            return true
        }
        if hold, releaseGate.wait(timeout: .now() + .seconds(10)) == .timedOut {
            state.withLockedValue { $0.safetyRelease = true }
        }
    }
    func platform(_ event: PlatformRetirementLifecycleEvent) {
        let hold = state.withLockedValue { state in
            if state.platform.count < 16 { state.platform.append(event) }
            else { state.overflow = true }
            guard event == heldPlatform, !state.held else { return false }
            state.held = true
            return true
        }
        if hold, releaseGate.wait(timeout: .now() + .seconds(10)) == .timedOut {
            state.withLockedValue { $0.safetyRelease = true }
        }
    }
    func count(_ event: ConfiguredPlatformConstructionEvent) -> Int {
        state.withLockedValue { $0.construction.filter { $0 == event }.count }
    }
    func count(_ event: PlatformRetirementLifecycleEvent) -> Int {
        state.withLockedValue { $0.platform.filter { $0 == event }.count }
    }
    var isHeld: Bool { state.withLockedValue { $0.held } }
    var safetyReleased: Bool { state.withLockedValue { $0.safetyRelease } }
    var overflowed: Bool { state.withLockedValue { $0.overflow } }
    func release() { releaseGate.signal() }
}

private final class ConfiguredActualConstructionContext: @unchecked Sendable {
    let probe: ConfiguredActualProbe
    init(_ probe: ConfiguredActualProbe) { self.probe = probe }
}

private final class ConfiguredActualDriver: @unchecked Sendable {
    var native = lattice.configured_platform_test_driver()
    func construct(_ probe: ConfiguredActualProbe) -> Bool {
        let context = ConfiguredActualConstructionContext(probe)
        defer { withExtendedLifetime(context) {} }
        return native.construct(Unmanaged.passUnretained(context).toOpaque(), { pointer, scheduler, receipt in
            guard let pointer, scheduler != nil, let receipt else { return nil }
            let context = Unmanaged<ConfiguredActualConstructionContext>.fromOpaque(pointer).takeUnretainedValue()
            return makeConfiguredPlatformTransport(
                receipt.assumingMemoryBound(to: lattice.platform_retirement_receipt.self).pointee,
                constructionObservation: { context.probe.construction($0) },
                retirementObservation: { context.probe.platform($0) })
        })
    }
    func wait(_ predicate: () -> Bool) async throws {
        let until = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < until {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ConfiguredActualFailure.deadline
    }
    func collectActualCompletion(_ probe: ConfiguredActualProbe) async throws {
        try await wait { native.facts().adapter_complete || native.facts().first_error != 0 }
        let before = native.facts()
        try #require(before.adapter_complete)
        try #require(before.first_error == 0)
        try #require(before.fixture_error == 0)
        #expect(before.construction_returned)
        #expect(before.calls == 0)
        #expect(before.callbacks == 0)
        #expect(before.native_commands == 0)
        #expect(before.native_payloads == 0)
        #expect(before.native_workers == 0)
        #expect(!before.native_complete)
        #expect(!before.safety_release)
        try #require(native.collect_if_settled())
        #expect(native.facts().collected)
        #expect(!native.issued_receipt().valid())
        #expect(!probe.safetyReleased)
        #expect(!probe.overflowed)
    }
    deinit {
        native.release_construction_hold()
        native.release_pre_pointer_hold()
        _ = native.request_retirement()
        // No synthetic completion on a failed fixture. Its real issued debt
        // remains charged if construction/resource/native cleanup is unproved.
    }
}

private func withHeldConfiguredConstruction(
    _ driver: ConfiguredActualDriver, _ probe: ConfiguredActualProbe,
    body: () async throws -> Void
) async throws -> Bool {
    let construction = Task.detached { driver.construct(probe) }
    do {
        try await body()
        probe.release()
        return await construction.value
    } catch {
        driver.native.release_construction_hold()
        probe.release()
        _ = await construction.value
        throw error
    }
}

private final class ConfiguredFactoryChildBundleAnchor: NSObject {}

@Suite(.serialized) struct ConfiguredPlatformFactoryActualTests {
    @Test(.timeLimit(.minutes(1)))
    func retirementBeforeRegistrationAllocatesNothingAndStillWaitsForConstruction() async throws {
        let driver = ConfiguredActualDriver()
        let probe = ConfiguredActualProbe(hold: .constructionFinished)
        try #require(driver.native.issued_receipt().valid())
        try #require(driver.native.arm_construction_hold())
        let constructed = try await withHeldConfiguredConstruction(driver, probe) {
            // The actual native factory call was admitted before retirement;
            // the SDK callback and registration have not started yet.
            try await driver.wait { driver.native.facts().construction_hold_entered }
            #expect(driver.native.facts().construction_admitted)
            #expect(driver.native.facts().native_commands == 1)
            #expect(probe.count(.registrationFinished(true)) == 0)
            try #require(driver.native.request_retirement())
            #expect(!driver.native.request_retirement())
            #expect(!driver.native.collect_if_settled())
            driver.native.release_construction_hold()
            try await driver.wait { probe.isHeld }
            let held = driver.native.facts()
            #expect(held.requested)
            #expect(held.construction_entered)
            #expect(!held.construction_returned)
            #expect(held.calls == 1)
            #expect(held.native_commands == 1)
            #expect(!held.adapter_complete)
            #expect(!held.native_complete)
            #expect(!driver.native.collect_if_settled())
            #expect(probe.count(.registrationFinished(true)) == 1)
            #expect(probe.count(.constructionAdmitted) == 0)
            #expect(probe.count(.clientCreated) == 0)
            #expect(probe.count(.nioGroupShutdown(0)) == 0)
            #expect(probe.count(.appleSessionInvalidated(0)) == 0)
        }
        #expect(!constructed)
        try await driver.collectActualCompletion(probe)
    }

    @Test(.timeLimit(.minutes(1)))
    func retirementDuringActualClientConstructionRetainsLateAttachmentUntilRealCleanup() async throws {
        let driver = ConfiguredActualDriver()
        let probe = ConfiguredActualProbe(hold: .clientCreated)
        let constructed = try await withHeldConfiguredConstruction(driver, probe) {
            try await driver.wait { probe.isHeld }
            #expect(probe.count(.constructionAdmitted) == 1)
            #expect(probe.count(.clientCreated) == 1)
            try #require(driver.native.request_retirement())
            let held = driver.native.facts()
            #expect(held.native_commands == 1)
            #expect(!held.adapter_complete)
            #expect(!held.native_complete)
            #expect(!driver.native.collect_if_settled())
            #expect(probe.count(.nioGroupShutdown(0)) == 0)
        }
        #expect(!constructed)
        try await driver.collectActualCompletion(probe)
        #if os(Linux)
        // The constructor really started a group before attachment; only its
        // actual joined shutdown can release the shared retirement drain.
        #expect(probe.count(.nioGroupShutdown(0)) == 1)
        #else
        // An Apple client without a dial owns no session. This establishes the
        // late-client empty case, not positive URLSession cleanup coverage.
        #expect(probe.count(.appleSessionInvalidated(0)) == 0)
        #endif
    }

    @Test(.timeLimit(.minutes(1)))
    func admittedNativeCallBeforeSwiftPointerAccessBlocksRetirementCollection() async throws {
        let driver = ConfiguredActualDriver()
        let probe = ConfiguredActualProbe()
        try #require(driver.construct(probe))
        try #require(driver.native.arm_pre_pointer_hold())
        let call = Task.detached { driver.native.connect(std.string("ws://localhost:9/must-not-dial")) }
        do {
            try await driver.wait { driver.native.facts().pre_pointer_entered }
            #expect(driver.native.facts().native_commands == 1)
            try #require(driver.native.request_retirement())
            try await driver.wait { driver.native.facts().adapter_complete }
            let held = driver.native.facts()
            #expect(held.calls == 1)
            #expect(held.native_commands == 1)
            #expect(!held.native_complete)
            #expect(!driver.native.collect_if_settled())
            #expect(driver.native.issued_receipt().valid())
            #expect(probe.count(.dnsWorkReturned) == 0)
            driver.native.release_pre_pointer_hold()
            let accepted = await call.value
            #expect(!accepted)
        } catch {
            driver.native.release_pre_pointer_hold()
            _ = await call.value
            throw error
        }
        try await driver.collectActualCompletion(probe)
    }

    @Test(.timeLimit(.minutes(1)))
    func invalidAndDuplicateTypedConstructionNeverAllocateASecondActualClient() async throws {
        let invalidProbe = ConfiguredActualProbe()
        let invalid = makeConfiguredPlatformTransport(lattice.platform_retirement_receipt(),
            constructionObservation: { invalidProbe.construction($0) },
            retirementObservation: { invalidProbe.platform($0) })
        #expect(invalid == nil)
        #expect(invalidProbe.count(.clientCreated) == 0)
        let driver = ConfiguredActualDriver()
        let originalProbe = ConfiguredActualProbe()
        try #require(driver.construct(originalProbe))
        let duplicateProbe = ConfiguredActualProbe()
        let duplicate = makeConfiguredPlatformTransport(driver.native.issued_receipt(),
            constructionObservation: { duplicateProbe.construction($0) },
            retirementObservation: { duplicateProbe.platform($0) })
        #expect(duplicate == nil)
        #expect(duplicateProbe.count(.registrationFinished(false)) == 1)
        #expect(duplicateProbe.count(.clientCreated) == 0)
        #expect(!driver.construct(duplicateProbe))
        #expect(originalProbe.count(.clientCreated) == 1)
        #expect(!driver.native.facts().adapter_complete)
        try #require(driver.native.request_retirement())
        try await driver.collectActualCompletion(originalProbe)
    }

    @Test(.timeLimit(.minutes(1)))
    func actualTypedPeerRetirementWaitsForItsRealPlatformCleanupBoundary() async throws {
        var environment = try Environment.detect(); environment.arguments = ["vapor"]
        let app = try await Application.make(environment)
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0
        let closes = NIOLockedValueBox(0)
        app.webSocket("configured-retirement") { _, socket in
            socket.onClose.whenComplete { _ in closes.withLockedValue { $0 += 1 } }
        }
        #if os(Linux)
        let probe = ConfiguredActualProbe(platformHold: .nioGroupShutdown(0))
        #else
        let probe = ConfiguredActualProbe(platformHold: .appleInvalidationFence(0))
        #endif
        let driver = ConfiguredActualDriver()
        do {
            try await app.startup()
            guard let port = app.http.server.shared.localAddress?.port else { throw ConfiguredActualFailure.missingPort }
            try #require(driver.construct(probe))
            try #require(driver.native.connect(std.string("ws://localhost:\(port)/configured-retirement")))
            try await driver.wait { driver.native.facts().opens == 1 || driver.native.facts().errors != 0 }
            try #require(driver.native.facts().opens == 1)
            #expect(driver.native.facts().errors == 0)
            try #require(driver.native.request_retirement())
            try await driver.wait { probe.isHeld }
            #expect(!driver.native.facts().adapter_complete)
            #expect(!driver.native.facts().native_complete)
            #expect(!driver.native.collect_if_settled())
            #expect(driver.native.issued_receipt().valid())
            probe.release()
            try await driver.collectActualCompletion(probe)
            try await driver.wait { closes.withLockedValue { $0 } == 1 }
            #if os(Linux)
            #expect(probe.count(.dnsWorkReturned) == 1)
            #expect(probe.count(.dnsQueriesPublished) == 1)
            #expect(probe.count(.nioGroupShutdown(0)) == 1)
            #else
            #expect(probe.count(.appleSessionInvalidated(0)) == 1)
            #expect(probe.count(.appleInvalidationFence(0)) == 1)
            #endif
            try await app.asyncShutdown()
        } catch {
            probe.release()
            _ = driver.native.request_retirement()
            do { try await app.asyncShutdown() }
            catch { Issue.record("Configured actual peer shutdown failed: \(error)") }
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func actualPairedPublicationPrecedesGlobalFactoryDestructorReentryInDedicatedChild() throws {
        let bundle = Bundle(for: ConfiguredFactoryChildBundleAnchor.self).bundleURL
        let products = bundle.pathExtension == "xctest" ? bundle.deletingLastPathComponent() : bundle
        let executable = products.appendingPathComponent("ConfiguredPlatformFactoryChild")
        try #require(FileManager.default.isExecutableFile(atPath: executable.path),
            "Dedicated helper must be built; absence is not a skip or qualification")
        let nonce = UUID().uuidString
        let result = lattice.run_configured_factory_child(std.string(executable.path), std.string(nonce))
        let output = String(result.output)
        print("CONFIGURED_FACTORY_CHILD_CAPTURE \(nonce)\n\(output)")
        #expect(result.launched)
        #expect(!result.timed_out)
        #expect(!result.custody_lost)
        #expect(!result.cleanup_unproved)
        #expect(!result.output_overflow)
        #expect(!result.io_error)
        #expect(!result.child_slot_unavailable)
        #expect(result.child_pid > 0)
        #expect(result.reaped)
        #expect(result.normal_exit)
        #expect(result.wait_status == 0)
        #expect(output == [
            "CONFIGURED_FACTORY_ENTRY \(nonce)",
            "CONFIGURED_FACTORY_PUBLICATION_REENTRY_READY \(nonce)",
            "CONFIGURED_FACTORY_OUTER_READY \(nonce)",
            "CONFIGURED_FACTORY_FAILED_PUBLICATION_BEFORE_RELEASE \(nonce)",
            "CONFIGURED_FACTORY_EXIT \(nonce)",
            ""
        ].joined(separator: "\n"))
    }
}
