import Foundation
import Testing
import NIOCore
import NIOPosix
import NIOConcurrencyHelpers
import CxxStdlib
import LatticeServerExportTestSupport
@testable import Lattice
@testable import LatticeServerKit

@Model private final class RelayExportFixtureItem {
    var name: String = ""
}
private enum ExportFixtureError: Error { case refused, injected }

/// Publish setup failure as well as success before the controller waits on an
/// IO rendezvous. Only a scalar fixture error crosses to the event loop; the
/// original error unwinds on the IO call stack.
private func exportFixturePrepare<T>(_ entered: EventLoopPromise<Void>,
                                     _ body: () throws -> T) throws -> T {
    do {
        let value = try body()
        entered.succeed(())
        return value
    } catch {
        entered.fail(ExportFixtureError.refused)
        throw error
    }
}
private struct ExportFacts: Sendable, Equatable {
    let originals: Int64, claimed: Int64, stamps: Int64
}
private final class ExportWeakEndpoint: @unchecked Sendable {
    weak var value: RelayProtectedExport?
    init(_ value: RelayProtectedExport) { self.value = value }
}
/// No C++/Swift owner crosses this test cell's IO access boundary.
private final class ExportWeakPage: @unchecked Sendable {
    weak var value: RelayExportPage?
    init(_ value: RelayExportPage) { self.value = value }
}
private final class ExportInputLifetime: @unchecked Sendable {
    private let disposed: @Sendable () -> Void
    init(_ disposed: @escaping @Sendable () -> Void) { self.disposed = disposed }
    deinit { disposed() }
}
private actor ExportActorOwner {
    let endpoint: RelayProtectedExport
    init(_ endpoint: RelayProtectedExport) { self.endpoint = endpoint }
}
private final class ExportStoreCell: @unchecked Sendable {
    var store: Lattice?
    deinit { precondition(store == nil) }
}
private final class ExportFixture: @unchecked Sendable {
    enum Mode: Sendable, Equatable { case manual, immediateSuccess, throwAfterEnqueue }
    let pool = RelayExecutionPool(workerCount: 1, name: "relay.protected-export.test")
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let key = "one-physical-fixture"
    let cell = ExportStoreCell()
    let outputs = NIOLockedValueBox<[ByteBuffer]>([])
    let pending = NIOLockedValueBox<[EventLoopPromise<Void>]>([])
    let endpoints = NIOLockedValueBox<[ExportWeakEndpoint]>([])
    let pages = NIOLockedValueBox<[ExportWeakPage]>([])
    let mode = NIOLockedValueBox(Mode.manual)
    let closed = NIOLockedValueBox(false)
    let created = NIOLockedValueBox(0)
    let contextReleases = NIOLockedValueBox(0)
    let closeCalls = NIOLockedValueBox(0)
    let writeHook = NIOLockedValueBox<(@Sendable () -> Void)?>(nil)
    var loop: any EventLoop { group.next() }

    func io<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        let done = loop.makePromise(of: T.self)
        pool.submitRequired(for: key) { done.completeWith(Result(catching: body)) }
        return try await done.futureResult.get()
    }
    func fence() async throws { try await io {} }
    func sink() -> RelayExportSink {
        .init(eventLoop: loop, isClosed: { self.closed.withLockedValue { $0 } }, write: { buffer, promise in
            #expect(self.pool.isCurrentWorker)
            self.outputs.withLockedValue { values in
                #expect(values.count < 4, "finite fixture output retention"); values.append(buffer)
            }
            let mode = self.mode.withLockedValue { $0 }
            if mode != .immediateSuccess { self.pending.withLockedValue { $0.append(promise) } }
            self.writeHook.withLockedValue { $0 }?()
            if mode == .immediateSuccess { promise.succeed(()) }
            if mode == .throwAfterEnqueue { throw ExportFixtureError.injected }
        }, close: {
            #expect(self.pool.isCurrentWorker)
            self.closeCalls.withLockedValue { $0 += 1 }; self.closed.withLockedValue { $0 = true }
            // Deliberately DOES NOT complete writes: socket death is not their witness.
        })
    }
    func makeStore(file: Bool, protected: Bool, names: [String]) throws -> Lattice {
        precondition(pool.isCurrentWorker)
        created.withLockedValue { $0 += 1 }
        let configuration: Lattice.Configuration
        if file {
            let environment = ProcessInfo.processInfo.environment
            let directory: URL
            if environment["LATTICE_QUALIFICATION_ROOT"] != nil {
                directory = try latticeTestTemporaryDirectory()
            } else {
                directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("localdev/lattice-export-sdk-tests")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            // Retain fixture files for failure inspection; no unlink-as-drain claim.
            configuration = .init(fileURL: directory.appendingPathComponent("\(UUID().uuidString).sqlite"))
        } else { configuration = .init(storage: .memory()) }
        let store = try Lattice(isolation: nil, RelayExportFixtureItem.self, configuration: configuration)
        cell.store = store
        if protected {
            guard lattice.server_export_test_support.enroll(store.cxxLatticeRef, std.string("RelayExportFixtureItem")) == 0 else {
                // The wrapper deliberately erases arbitrary factory errors.
                // Record the native setup diagnostic here, on the owning IO
                // lane, before another bridge call can clear it.
                let message = String(lattice.last_bridge_error().pointee)
                Issue.record("export fixture enrollment failed: \(String(decoding: message.utf8.prefix(768), as: UTF8.self))")
                throw ExportFixtureError.refused
            }
        }
        try store.withTransaction(isolation: nil) {
            for name in names { let row = RelayExportFixtureItem(); row.name = name; try store.add(row) }
        }
        return store
    }
    func open(service: RelayExportAdmission, limits: RecoveryExportNativeLimits,
              file: Bool = false, protected: Bool = true, names: [String] = ["before\0after"]) throws -> RelayProtectedExport {
        let value = try RelayProtectedExport(forQualification: service, limits: limits, pool: pool, key: key, sink: sink(),
            contextReleased: {
                #expect(self.pool.isCurrentWorker); self.contextReleases.withLockedValue { $0 += 1 }
            }, makeLattice: { try self.makeStore(file: file, protected: protected, names: names) })
        endpoints.withLockedValue { $0.append(ExportWeakEndpoint(value)) }
        return value
    }
    func page(_ endpoint: RelayProtectedExport, after: Int64 = 0) async throws -> RelayExportPage {
        let prepared = try await endpoint.prepare(after: after, count: 8).get()
        guard case .page(let page) = prepared else { throw ExportFixtureError.refused }
        pages.withLockedValue { $0.append(ExportWeakPage(page)) }
        return page
    }
    func facts() async throws -> ExportFacts {
        try await io {
            guard let store = self.cell.store else { throw ExportFixtureError.refused }
            let result = lattice.server_export_test_support.facts(store.cxxLatticeRef)
            guard result.status == 0 else { throw ExportFixtureError.refused }
            return .init(originals: result.originals, claimed: result.claimed, stamps: result.stamps)
        }
    }
    func freeze() async throws {
        try await io {
            guard let store = self.cell.store,
                  lattice.server_export_test_support.freeze(store.cxxLatticeRef) == 0 else { throw ExportFixtureError.refused }
        }
    }
    func settle(success: Bool) async throws {
        let values = pending.withLockedValue { current in let result = current; current.removeAll(); return result }
        for value in values {
            if success { value.succeed(()) } else { value.fail(ExportFixtureError.injected) }
        }
        // Positive FIFO event-loop fence follows the actual promise callbacks.
        try await loop.submit {}.get()
    }
    func shutdown() async {
        pages.withLockedValue { $0.compactMap(\.value) }.forEach { $0.close() }
        endpoints.withLockedValue { $0.compactMap(\.value) }.forEach { $0.close() }
        do {
            try await fence() // every admitted consume has now exposed its exact promise
            try await settle(success: false) // includes the event-loop callback fence
            try await fence() // callbacks may have submitted endpoint retirement
            try await io { self.cell.store?.close(); self.cell.store = nil }
        } catch { Issue.record("export fixture cleanup failed: \(error)") }
        await pool.shutdown()
        do { try await group.shutdownGracefully() } catch { Issue.record("event-loop shutdown failed: \(error)") }
    }
}

@Suite("Protected relay export wrapper", .serialized, .timeLimit(.minutes(1)))
struct RelayProtectedExportTests {
    private func limits(raw: Int = 8192, wire: Int = 16384) throws -> RecoveryExportNativeLimits {
        try .init(entries: 8, fieldBytes: min(raw, 4096), rawBytes: raw, wireBytes: wire)
    }
    private func service(_ limits: RecoveryExportNativeLimits, endpoints: Int = 1) throws -> RelayExportAdmission {
        try .init(limits: .init(endpoints: endpoints, pages: endpoints,
            nativeBytes: endpoints * RelayProtectedExport.nativeCharge(limits), outputBytes: endpoints * limits.wireBytes))
    }
    private func run(_ body: (ExportFixture) async throws -> Void) async throws {
        let fixture = ExportFixture()
        do { try await body(fixture) }
        catch { await fixture.shutdown(); throw error }
        await fixture.shutdown()
    }
    private func failed<T: Sendable>(_ future: EventLoopFuture<T>) async {
        do { _ = try await future.get(); Issue.record("expected actual export refusal") } catch {}
    }

    @Test(arguments: [false, true])
    func actualProtectedPageCopiesNULAndClaimsBeforeExactPromise(file: Bool) async throws {
        try await run { fixture in
            let limits = try limits(), service = try service(limits)
            let endpoint = try fixture.open(service: service, limits: limits, file: file)
            try await endpoint.waitUntilReady()
            #expect(try await fixture.facts() == .init(originals: 1, claimed: 0, stamps: 1))
            let page = try await fixture.page(endpoint)
            #expect(try await fixture.facts() == .init(originals: 1, claimed: 1, stamps: 1))
            #expect(fixture.outputs.withLockedValue { $0.isEmpty })
            let delivery = try page.consume()
            try await fixture.fence()
            #expect(service.snapshot.nativeBytes == 0 && service.snapshot.outputBytes == limits.wireBytes)
            #expect(service.snapshot.pages == 1)
            let bytes = try #require(fixture.outputs.withLockedValue { $0.first })
            let json = try #require(JSONSerialization.jsonObject(with: Data(bytes.readableBytesView)) as? [String: Any])
            let entries = try #require(json["auditLog"] as? [[String: Any]])
            #expect(entries.count == 1)
            let fields = try #require(entries[0]["changedFields"] as? [String: Any])
            let name = try #require(fields["name"] as? [String: Any])
            #expect(name["value"] as? String == "before\0after")
            try await fixture.settle(success: true)
            let receipt = try await delivery.get()
            #expect(receipt.count == 1 && receipt.lastID > 0 && receipt.serial > 0)
            #expect(service.snapshot.pages == 0 && service.snapshot.outputBytes == 0)
            let empty = try await endpoint.prepare(after: receipt.lastID, count: 8).get()
            if case .empty = empty {} else { Issue.record("addressed history should now be empty") }
            #expect(try await fixture.facts() == .init(originals: 1, claimed: 1, stamps: 1), "history does not ACK/settle obligations")
            endpoint.close(); try await fixture.fence()
            #expect(fixture.contextReleases.withLockedValue { $0 } == 1)
            #expect(service.snapshot.endpoints == 0)
        }
    }

    @Test func oneUseAndInlineCompletionCannotReuseCreditInsideNativeCallback() async throws {
        try await run { fixture in
            let limits = try limits(), service = try service(limits)
            fixture.mode.withLockedValue { $0 = .immediateSuccess }
            let endpoint = try fixture.open(service: service, limits: limits)
            try await endpoint.waitUntilReady()
            let weakEndpoint = ExportWeakEndpoint(endpoint)
            fixture.writeHook.withLockedValue { $0 = {
                #expect(service.snapshot.pages == 1 && service.snapshot.nativeBytes > 0)
                do { _ = try weakEndpoint.value?.prepare(after: 0, count: 1); Issue.record("active native page must retain one-page credit") }
                catch { #expect(error as? RelayExportAdmissionError == .pageBusy) }
            } }
            let page = try await fixture.page(endpoint)
            let first = try page.consume()
            do { _ = try page.consume(); Issue.record("second consume must refuse") }
            catch { #expect(error as? RelayProtectedExportError == .alreadyConsumed) }
            _ = try await first.get()
            fixture.writeHook.withLockedValue { $0 = nil }
            #expect(fixture.outputs.withLockedValue { $0.count } == 1)
            #expect(service.snapshot.pages == 0)
            endpoint.close(); try await fixture.fence()
        }
    }

    @Test func closeAndActorDeinitDoNotInventTransportSettlement() async throws {
        try await run { fixture in
            let limits = try limits(), service = try service(limits)
            var endpoint: RelayProtectedExport? = try fixture.open(service: service, limits: limits)
            try await endpoint!.waitUntilReady()
            let page = try await fixture.page(endpoint!), delivery = try page.consume()
            try await fixture.fence()
            var actor: ExportActorOwner? = ExportActorOwner(endpoint!)
            endpoint = nil
            // Last actor field release invokes endpoint deinit from whichever
            // executor retires the actor; native cleanup still runs on IO.
            actor = nil
            withExtendedLifetime(actor) {}
            try await fixture.fence()
            #expect(fixture.closeCalls.withLockedValue { $0 } == 1)
            #expect(service.snapshot.endpoints == 1 && service.snapshot.pages == 1)
            #expect(service.snapshot.nativeBytes == 0 && service.snapshot.outputBytes > 0)
            do { _ = try fixture.open(service: service, limits: limits); Issue.record("retiring endpoint remains charged") }
            catch { #expect(error as? RelayExportAdmissionError == .endpoints) }
            try await fixture.settle(success: true); await failed(delivery)
            #expect(service.snapshot.endpoints == 0 && service.snapshot.pages == 0)
        }
    }

    @Test func throwingSinkKeepsStickyClaimAndWaitsItsRealPromise() async throws {
        try await run { fixture in
            let limits = try limits(), service = try service(limits)
            fixture.mode.withLockedValue { $0 = .throwAfterEnqueue }
            let endpoint = try fixture.open(service: service, limits: limits)
            try await endpoint.waitUntilReady()
            let page = try await fixture.page(endpoint), delivery = try page.consume()
            try await fixture.fence()
            #expect(service.snapshot.pages == 1 && service.snapshot.outputBytes > 0)
            #expect(try await fixture.facts() == .init(originals: 1, claimed: 1, stamps: 1))
            try await fixture.settle(success: true); await failed(delivery)
            #expect(service.snapshot.pages == 0)
            endpoint.close(); try await fixture.fence()
        }
    }

    @Test func sinkCanStopReentrantlyWithoutReleasingNativeContextOnItsCallbackStack() async throws {
        try await run { fixture in
            let limits = try limits(), service = try service(limits)
            let endpoint = try fixture.open(service: service, limits: limits)
            try await endpoint.waitUntilReady()
            let weakEndpoint = ExportWeakEndpoint(endpoint)
            fixture.writeHook.withLockedValue { $0 = {
                weakEndpoint.value?.close()
                #expect(fixture.contextReleases.withLockedValue { $0 } == 0)
                #expect(service.snapshot.nativeBytes > 0 && service.snapshot.endpoints == 1)
            } }
            let page = try await fixture.page(endpoint), delivery = try page.consume()
            try await fixture.fence()
            #expect(service.snapshot.endpoints == 1 && service.snapshot.outputBytes > 0)
            try await fixture.settle(success: false); await failed(delivery)
            #expect(service.snapshot.endpoints == 0 && service.snapshot.pages == 0)
            #expect(fixture.contextReleases.withLockedValue { $0 } == 1)
        }
    }

    @Test func freezeBetweenPrepareAndConsumeRefusesBeforeSinkWithoutLosingClaim() async throws {
        try await run { fixture in
            let limits = try limits(), service = try service(limits)
            let endpoint = try fixture.open(service: service, limits: limits)
            try await endpoint.waitUntilReady()
            let page = try await fixture.page(endpoint)
            try await fixture.freeze()
            await failed(try page.consume())
            #expect(fixture.outputs.withLockedValue { $0.isEmpty })
            #expect(try await fixture.facts() == .init(originals: 1, claimed: 1, stamps: 1))
            #expect(service.snapshot.pages == 0 && service.snapshot.outputBytes == 0)
            endpoint.close(); try await fixture.fence()
        }
    }

    @Test func droppedPreparedPageRetiresOnIOAndMakesNoSend() async throws {
        try await run { fixture in
            let limits = try limits(), service = try service(limits)
            let endpoint = try fixture.open(service: service, limits: limits)
            try await endpoint.waitUntilReady()
            // The preparation future is also discarded; retaining it would
            // intentionally retain its result shell until consumed/closed.
            func drop() async throws { _ = try await fixture.page(endpoint) }
            try await drop(); try await fixture.fence()
            #expect(service.snapshot.pages == 0)
            #expect(fixture.outputs.withLockedValue { $0.isEmpty })
            #expect(try await fixture.facts().claimed == 1)
            endpoint.close(); try await fixture.fence()
            #expect(fixture.contextReleases.withLockedValue { $0 } == 1)
        }
    }

    @Test func earlyStopBeforeOpeningDoesNotConstructOwnerOrContext() async throws {
        try await run { fixture in
            let limits = try limits(), service = try service(limits)
            let gate = DispatchSemaphore(value: 0)
            let entered = fixture.loop.makePromise(of: Void.self)
            fixture.pool.submitRequired(for: fixture.key) {
                entered.succeed(()); #expect(gate.wait(timeout: .now() + 5) == .success)
            }
            try await entered.futureResult.get()
            defer { gate.signal() }
            let endpoint = try fixture.open(service: service, limits: limits)
            endpoint.close(); endpoint.close()
            #expect(service.snapshot.endpoints == 1)
            gate.signal(); await failed(endpoint.ready); try await fixture.fence()
            #expect(fixture.created.withLockedValue { $0 } == 0)
            #expect(fixture.contextReleases.withLockedValue { $0 } == 0)
            #expect(service.snapshot.endpoints == 0)
        }
    }

    @Test func cancellationStopsEndpointButAwaitsAdmittedPromise() async throws {
        try await run { fixture in
            let limits = try limits(), service = try service(limits)
            let endpoint = try fixture.open(service: service, limits: limits)
            try await endpoint.waitUntilReady()
            let page = try await fixture.page(endpoint)
            let begun = fixture.loop.makePromise(of: Void.self)
            fixture.writeHook.withLockedValue { $0 = { begun.succeed(()) } }
            let task = Task { try await page.consumeAndWait() }
            try await begun.futureResult.get(); task.cancel(); try await fixture.fence()
            #expect(service.snapshot.pages == 1 && service.snapshot.endpoints == 1)
            try await fixture.settle(success: false)
            do { _ = try await task.value; Issue.record("cancelled page cannot advance") } catch {}
            #expect(service.snapshot.pages == 0 && service.snapshot.endpoints == 0)
        }
    }

    @Test func perPageByteAdmissionAndNativeFieldRefusalMakeNoFalseClaim() async throws {
        try await run { fixture in
            let limits = try limits(raw: 4096, wire: 8192)
            let small = try RelayExportAdmission(limits: .init(endpoints: 1, pages: 1,
                nativeBytes: RelayProtectedExport.nativeCharge(limits) - 1, outputBytes: limits.wireBytes))
            let endpoint = try fixture.open(service: small, limits: limits, names: [String(repeating: "x", count: 5000)])
            try await endpoint.waitUntilReady()
            do { _ = try endpoint.prepare(after: 0, count: 1); Issue.record("byte cap must refuse before IO") }
            catch { #expect(error as? RelayExportAdmissionError == .nativeBytes) }
            #expect(try await fixture.facts().claimed == 0)
            #expect(small.snapshot.pages == 0 && fixture.outputs.withLockedValue { $0.isEmpty })
            endpoint.close(); try await fixture.fence()
            // A second endpoint over the same real protected owner tests the
            // native raw-field refusal with a sufficient wrapper reservation.
            fixture.closed.withLockedValue { $0 = false }
            let enough = try service(limits)
            let second = try RelayProtectedExport(forQualification: enough, limits: limits,
                pool: fixture.pool, key: fixture.key, sink: fixture.sink(), makeLattice: {
                    guard let store = fixture.cell.store else { throw ExportFixtureError.refused }; return store
                })
            fixture.endpoints.withLockedValue { $0.append(ExportWeakEndpoint(second)) }
            try await second.waitUntilReady(); await failed(try second.prepare(after: 0, count: 1))
            #expect(try await fixture.facts().claimed == 0)
            #expect(enough.snapshot.pages == 0 && fixture.outputs.withLockedValue { $0.isEmpty })
            second.close(); try await fixture.fence()
        }
    }

    @Test func cancelledQueuedPreparationReleasesItsReservationOnlyOnIO() async throws {
        try await run { fixture in
            let limits = try limits(), service = try service(limits)
            let endpoint = try fixture.open(service: service, limits: limits)
            try await endpoint.waitUntilReady()
            let gate = DispatchSemaphore(value: 0), entered = fixture.loop.makePromise(of: Void.self)
            fixture.pool.submitRequired(for: fixture.key) {
                entered.succeed(()); #expect(gate.wait(timeout: .now() + 5) == .success)
            }
            try await entered.futureResult.get(); defer { gate.signal() }
            let preparation = try endpoint.prepare(after: 0, count: 1)
            endpoint.close()
            #expect(service.snapshot.pages == 1 && service.snapshot.nativeBytes > 0)
            gate.signal(); await failed(preparation); try await fixture.fence()
            #expect(try await fixture.facts().claimed == 0)
            #expect(service.snapshot.pages == 0 && service.snapshot.endpoints == 0)
            #expect(fixture.outputs.withLockedValue { $0.isEmpty })
        }
    }

    @Test func failedNativeFactoryDestroysTransferredContextOnIOAndReturnsEndpointCredit() async throws {
        try await run { fixture in
            let limits = try limits(), service = try service(limits)
            let endpoint = try RelayProtectedExport(forQualification: service, limits: limits,
                pool: fixture.pool, key: fixture.key, sink: fixture.sink(), contextReleased: {
                    #expect(fixture.pool.isCurrentWorker); fixture.contextReleases.withLockedValue { $0 += 1 }
                }, makeLattice: {
                    let store = try fixture.makeStore(file: false, protected: false, names: [])
                    store.close(); return store
                })
            fixture.endpoints.withLockedValue { $0.append(ExportWeakEndpoint(endpoint)) }
            await failed(endpoint.ready); try await fixture.fence()
            #expect(fixture.contextReleases.withLockedValue { $0 } == 1)
            #expect(service.snapshot.endpoints == 0 && service.snapshot.pages == 0)
            endpoint.close() // no duplicate retirement or context destruction
            #expect(fixture.outputs.withLockedValue { $0.isEmpty })
        }
    }

    @Test func oldPageAndCompletedFutureCannotSettleNewPageCredit() async throws {
        try await run { fixture in
            let limits = try limits(), service = try service(limits)
            let endpoint = try fixture.open(service: service, limits: limits)
            try await endpoint.waitUntilReady()
            let old = try await fixture.page(endpoint), first = try old.consume()
            try await fixture.fence(); try await fixture.settle(success: true)
            let original = try await first.get()
            let next = try await fixture.page(endpoint)
            let retained = service.snapshot
            old.close(); _ = try await first.get()
            #expect(service.snapshot == retained && retained.pages == 1)
            let second = try next.consume()
            try await fixture.fence(); try await fixture.settle(success: true)
            let retried = try await second.get()
            #expect(retried.lastID == original.lastID && retried.serial != original.serial)
            #expect(try await fixture.facts() == .init(originals: 1, claimed: 1, stamps: 1))
            #expect(fixture.outputs.withLockedValue { $0.count } == 2)
            endpoint.close(); try await fixture.fence()
        }
    }

    @Test func unprotectedOwnerCannotProduceAMechanicalSuccessPage() async throws {
        try await run { fixture in
            let limits = try limits(), service = try service(limits)
            let endpoint = try fixture.open(service: service, limits: limits, protected: false)
            try await endpoint.waitUntilReady(); await failed(try endpoint.prepare(after: 0, count: 8))
            #expect(fixture.outputs.withLockedValue { $0.isEmpty })
            #expect(service.snapshot.pages == 0)
            endpoint.close(); try await fixture.fence()
            #expect(service.snapshot.endpoints == 0)
        }
    }

    @Test func nativeFactoryRetainsOwnerAfterSwiftFixtureCopyIsDropped() async throws {
        try await run { fixture in
            let limits = try limits(), service = try service(limits)
            fixture.mode.withLockedValue { $0 = .immediateSuccess }
            let endpoint = try fixture.open(service: service, limits: limits)
            try await endpoint.waitUntilReady()
            try await fixture.io { fixture.cell.store = nil }
            let page = try await fixture.page(endpoint), receipt = try await page.consume().get()
            #expect(receipt.count == 1 && fixture.outputs.withLockedValue { $0.count } == 1)
            endpoint.close(); try await fixture.fence()
            #expect(service.snapshot.endpoints == 0 && fixture.contextReleases.withLockedValue { $0 } == 1)
        }
    }

    @Test(arguments: [0, 1, 2])
    func openingInputsDisposeOnIOWhileEndpointCreditIsStillHeld(mode: Int) async throws {
        try await run { fixture in
            let limits = try limits(), service = try service(limits)
            let disposed = NIOLockedValueBox<[String]>([])
            let gate = DispatchSemaphore(value: 0)
            let entered = fixture.loop.makePromise(of: Void.self)
            defer { gate.signal() }
            if mode != 2 {
                fixture.pool.submitRequired(for: fixture.key) {
                    entered.succeed(()); #expect(gate.wait(timeout: .now() + 5) == .success)
                }
                try await entered.futureResult.get()
            }
            // The function returns before the controlled IO turn is released.
            // Only admitted input/context copies can own these witnesses then.
            func create() throws -> RelayProtectedExport {
                func witness(_ name: String) -> ExportInputLifetime {
                    .init {
                        #expect(fixture.pool.isCurrentWorker)
                        #expect(service.snapshot.endpoints == 1, "disposal must precede quota return")
                        disposed.withLockedValue { $0.append(name) }
                    }
                }
                let factoryCapture = witness("factory"), sinkCapture = witness("sink"), releaseCapture = witness("release")
                let sink = RelayExportSink(eventLoop: fixture.loop, isClosed: { false }, write: { _, promise in
                    withExtendedLifetime(sinkCapture) {}; promise.fail(ExportFixtureError.injected)
                }, close: { withExtendedLifetime(sinkCapture) {} })
                return try RelayProtectedExport(forQualification: service, limits: limits,
                    pool: fixture.pool, key: fixture.key, sink: sink, contextReleased: {
                        withExtendedLifetime(releaseCapture) {}
                        #expect(fixture.pool.isCurrentWorker)
                    }, makeLattice: {
                        withExtendedLifetime(factoryCapture) {}
                        if mode == 1 { throw ExportFixtureError.injected }
                        if mode == 2 {
                            let store = try exportFixturePrepare(entered) {
                                try fixture.makeStore(file: false, protected: true, names: ["real"])
                            }
                            #expect(gate.wait(timeout: .now() + 5) == .success)
                            return store
                        }
                        return try fixture.makeStore(file: false, protected: true, names: ["real"])
                    })
            }
            let endpoint = try create()
            fixture.endpoints.withLockedValue { $0.append(ExportWeakEndpoint(endpoint)) }
            if mode == 2 { try await entered.futureResult.get() }
            if mode != 1 { endpoint.close() }
            if mode != 2 { #expect(disposed.withLockedValue { $0.isEmpty }) }
            gate.signal(); await failed(endpoint.ready)
            // ready is published inside the opening job. A body-return or
            // subsequent IO sentinel cannot substitute for this lifetime check.
            #expect(disposed.withLockedValue { $0.sorted() } == ["factory", "release", "sink"])
            #expect(service.snapshot.endpoints == 0)
            try await fixture.fence()
            #expect(fixture.outputs.withLockedValue { $0.isEmpty })
        }
    }

    @Test func openingSetupFailureWakesControllerAndReleasesEndpointCredit() async throws {
        try await run { fixture in
            let limits = try limits(), service = try service(limits)
            let entered = fixture.loop.makePromise(of: Void.self)
            let endpoint = try RelayProtectedExport(forQualification: service, limits: limits,
                pool: fixture.pool, key: fixture.key, sink: fixture.sink(), makeLattice: {
                    try exportFixturePrepare(entered) { () throws -> Lattice in
                        throw ExportFixtureError.injected
                    }
                })
            fixture.endpoints.withLockedValue { $0.append(ExportWeakEndpoint(endpoint)) }
            do {
                try await entered.futureResult.get()
                Issue.record("setup failure must not report entering the successful rendezvous")
            } catch {
                if case ExportFixtureError.refused = error {} else {
                    Issue.record("setup rendezvous must receive only the scalar refusal")
                }
            }
            await failed(endpoint.ready)
            try await fixture.fence()
            #expect(fixture.created.withLockedValue { $0 } == 0)
            #expect(fixture.outputs.withLockedValue { $0.isEmpty })
            #expect(service.snapshot.endpoints == 0 && service.snapshot.pages == 0)
        }
    }

    @Test func transportClaimIsNotPublishReadyUntilCoreAndAccountingAreRecorded() async throws {
        try await run { fixture in
            let limits = try limits(), service = try service(limits)
            let rendezvous = RelayExportQualificationRendezvous()
            rendezvous.armTransport(); defer { rendezvous.releaseTransport() }
            let sink = RelayExportSink(eventLoop: fixture.loop, isClosed: { false }, write: { _, promise in
                #expect(fixture.pool.isCurrentWorker)
                promise.succeed(()) // actual NIO event-loop callback runs on the OTHER thread
                // Keep the native callback active until NIO positively reaches
                // the claimed-but-not-recorded gap, then allow native unwind.
                #expect(rendezvous.waitForTransportClaim())
            }, close: { #expect(fixture.pool.isCurrentWorker) })
            let endpoint = try RelayProtectedExport(forQualification: service, limits: limits,
                pool: fixture.pool, key: fixture.key, sink: sink, rendezvous: rendezvous,
                makeLattice: { try fixture.makeStore(file: false, protected: true, names: ["rendezvous"]) })
            fixture.endpoints.withLockedValue { $0.append(ExportWeakEndpoint(endpoint)) }
            try await endpoint.waitUntilReady()
            let page = try await fixture.page(endpoint), delivery = try page.consume()
            // This witness follows the actual native epilogue, its accounting
            // release AND its attempted publication; NIO is still withheld.
            let witness: (Bool, Int, RelayExportAdmissionSnapshot) = await withCheckedContinuation { continuation in
                fixture.pool.submitRequired(for: fixture.key) {
                    continuation.resume(returning: (rendezvous.hasFinishedNative,
                        rendezvous.publicationCount, service.snapshot))
                }
            }
            // The controller never blocks a cooperative executor and does not
            // await fixture.io's promise on the deliberately paused NIO loop.
            #expect(witness.0 && witness.1 == 0)
            #expect(witness.2.nativeBytes == 0 && witness.2.pages == 1)
            #expect(witness.2.outputBytes == limits.wireBytes)
            rendezvous.releaseTransport()
            let receipt = try await delivery.get()
            #expect(receipt.count == 1 && receipt.lastID > 0)
            #expect(rendezvous.publicationCount == 1 && !rendezvous.didTimeOut)
            #expect(service.snapshot.pages == 0 && service.snapshot.outputBytes == 0)
            endpoint.close(); try await fixture.fence()
            #expect(service.snapshot.endpoints == 0)
        }
    }


    @Test(arguments: [false, true])
    func successorPrepareCannotReinterpretAnAlreadySettledDelivery(emptySuccessor: Bool) async throws {
        try await run { fixture in
            let limits = try limits(), service = try service(limits)
            let rendezvous = RelayExportQualificationRendezvous()
            rendezvous.armPublication(); defer { rendezvous.releasePublication() }
            let endpoint = try RelayProtectedExport(forQualification: service, limits: limits,
                pool: fixture.pool, key: fixture.key, sink: fixture.sink(), rendezvous: rendezvous,
                makeLattice: { try fixture.makeStore(file: false, protected: true, names: ["serial-race"]) })
            fixture.endpoints.withLockedValue { $0.append(ExportWeakEndpoint(endpoint)) }
            try await endpoint.waitUntilReady()
            let old = try await fixture.page(endpoint)
            let firstSerial = rendezvous.preparationSnapshot.serial
            let delivery = try old.consume()
            try await fixture.fence() // native-first: the exact NIO promise is still pending
            #expect(service.snapshot.nativeBytes == 0 && service.snapshot.outputBytes > 0)
            let promises = fixture.pending.withLockedValue { values in let result = values; values.removeAll(); return result }
            #expect(promises.count == 1)
            for promise in promises { promise.succeed(()) }
            // Deliberately bypass fixture.settle: its NIO fence cannot complete
            // while this genuine NIO result callback is paused before publication.
            let released: (Bool, RelayExportAdmissionSnapshot) = await withCheckedContinuation { continuation in
                fixture.pool.submitRequired(for: fixture.key) {
                    let entered = rendezvous.waitForCreditsRelease()
                    continuation.resume(returning: (entered, service.snapshot))
                }
            }
            #expect(released.0 && released.1.pages == 0)
            #expect(released.1.nativeBytes == 0 && released.1.outputBytes == 0)
            #expect(rendezvous.publicationCount == 0)
            // This is actual native prepare while A's future remains unpublished.
            // Even an empty B has incremented the Core endpoint serial.
            let next = try endpoint.prepare(after: emptySuccessor ? Int64.max : 0, count: 8)
            let successor: (Int, RecoveryExportNativeStatus?, UInt64, RelayExportAdmissionSnapshot) = await withCheckedContinuation { continuation in
                fixture.pool.submitRequired(for: fixture.key) {
                    let sampled = rendezvous.preparationSnapshot
                    continuation.resume(returning: (sampled.count, sampled.status, sampled.serial, service.snapshot))
                }
            }
            #expect(successor.0 == 2)
            #expect(successor.1 == (emptySuccessor ? .empty : .ready))
            if !emptySuccessor { #expect(successor.2 != 0 && successor.2 != firstSerial) }
            #expect(successor.3.pages == (emptySuccessor ? 0 : 1))
            old.close()
            do { _ = try old.consume(); Issue.record("stale old page must remain consumed") }
            catch { #expect(error as? RelayProtectedExportError == .alreadyConsumed) }
            #expect(service.snapshot == successor.3)
            rendezvous.releasePublication()
            let prepared = try await next.get()
            var secondPage: RelayExportPage?
            if case .page(let value) = prepared {
                secondPage = value; fixture.pages.withLockedValue { $0.append(ExportWeakPage(value)) }
            }
            let receipt = try await delivery.get()
            #expect(receipt.count == 1 && receipt.serial == firstSerial)
            #expect(try await delivery.get() == receipt, "retained completed result is immutable")
            old.close()
            #expect(service.snapshot == successor.3, "stale custody cannot return B's credit")
            #expect(rendezvous.publicationCount == 1 && !rendezvous.didTimeOut)
            if emptySuccessor {
                if case .empty = prepared {} else { Issue.record("expected actual empty native successor") }
            } else { #expect(secondPage != nil) }
            secondPage?.close(); try await fixture.fence()
            #expect(try await fixture.facts() == .init(originals: 1, claimed: 1, stamps: 1))
            #expect(fixture.outputs.withLockedValue { $0.count } == 1)
            endpoint.close(); try await fixture.fence()
            #expect(service.snapshot.pages == 0 && service.snapshot.endpoints == 0)
        }
    }

}
