import Foundation
import Testing
@testable import Lattice

private final class SchedulerFake: @unchecked Sendable {
    private let lock = NSLock()
    private var registrationCount = 0
    private var registrationAccepted = true
    private var pending: [BackgroundTaskPendingRequest] = []
    private var submissions: [BackgroundTaskPendingRequest] = []
    private var submissionFails = false
    private var diagnostics: [String] = []
    @MainActor var assertions: [SchedulerAssertion] = []

    enum Failure: Error { case submission, lifecycle }

    var registrations: Int { lock.withLock { registrationCount } }
    var submitted: [BackgroundTaskPendingRequest] { lock.withLock { submissions } }
    var requests: [BackgroundTaskPendingRequest] { lock.withLock { pending } }
    var messages: [String] { lock.withLock { diagnostics } }
    func acceptRegistration(_ accepted: Bool) { lock.withLock { registrationAccepted = accepted } }
    func failSubmission(_ fail: Bool) { lock.withLock { submissionFails = fail } }
    func setPending(_ requests: [BackgroundTaskPendingRequest]) { lock.withLock { pending = requests } }

    func hooks() -> BackgroundTaskSchedulerHooks {
        BackgroundTaskSchedulerHooks(
            permittedIdentifiers: ["app.sync", "app.other"], registrationError: nil,
            register: { [self] _, _ in lock.withLock { registrationCount += 1; return registrationAccepted } },
            observe: { _ in false }, pendingRequests: { [self] in requests },
            submit: { [self] request in
                try lock.withLock {
                    if submissionFails { throw Failure.submission }
                    submissions.append(request)
                    pending = [request]
                }
            },
            beginCleanup: { [self] expire in
                let assertion = SchedulerAssertion(expire: expire)
                assertions.append(assertion)
                return assertion
            },
            now: { Date(timeIntervalSince1970: 1_000) },
            report: { [self] message in lock.withLock { diagnostics.append(message) } })
    }
}

@MainActor
private final class SchedulerAssertion: BackgroundTaskCleanupAssertion {
    let expire: @Sendable () -> Void
    var ends = 0
    init(expire: @escaping @Sendable () -> Void) { self.expire = expire }
    func end() { ends += 1 }
}

@MainActor
private final class SchedulerDelivery: BackgroundTaskDelivery {
    let identifier: String
    var completions: [Bool] = []
    var expireOnInstallation = false
    var expirationHandler: (@Sendable () -> Void)? {
        didSet { if expireOnInstallation { expirationHandler?() } }
    }
    init(_ identifier: String = "app.sync") { self.identifier = identifier }
    func complete(success: Bool) { completions.append(success) }
}

private actor SchedulerLatch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor SchedulerHistory {
    var commands: [BackgroundTaskCommand] = []
    var cancelled = false
    func append(_ command: BackgroundTaskCommand) { commands.append(command) }
    func recordCancellation(_ value: Bool) { cancelled = value }
}

private final class SchedulerAvailability: @unchecked Sendable {
    private let lock = NSLock()
    private var live = true
    var isLive: Bool { lock.withLock { live } }
    func release() { lock.withLock { live = false } }
}

private final class SchedulerReleaseProbe: Sendable {
    let released: @Sendable () -> Void
    init(_ released: @escaping @Sendable () -> Void) { self.released = released }
    deinit { released() }
}

@Suite("Background task scheduler")
struct BackgroundTaskSchedulerTests {
    private let policy = Lattice.Configuration.BackgroundSync.appRefresh(identifier: "app.sync", minimumInterval: 60)

    @Test(arguments: [false, true])
    func cancellationCaptureMayReenterWhenRetired(replace: Bool) {
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let cancellation = BackgroundTaskCancellation()
            func installCapture() {
                let probe = SchedulerReleaseProbe { cancellation.cancel() }
                cancellation.install { withExtendedLifetime(probe) {} }
            }
            installCapture()
            if replace { cancellation.install {} } else { cancellation.clear() }
            finished.signal()
        }
        // A destructor that reenters the cancellation lock must not deadlock.
        #expect(finished.wait(timeout: .now() + 2) == .success)
    }

    @Test func concurrentRegistrationOccursOnceAndConflictsAreSynchronous() async throws {
        let fake = SchedulerFake()
        let scheduler = BackgroundTaskScheduler(hooks: fake.hooks())
        let policy = self.policy
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<24 { group.addTask { try scheduler.register(policy: policy) } }
            try await group.waitForAll()
        }
        #expect(fake.registrations == 1)
        #expect(throws: BackgroundTaskSchedulerError.conflictingPolicy("app.sync")) {
            try scheduler.register(policy: .appRefresh(identifier: "app.sync", minimumInterval: 120))
        }
        #expect(fake.registrations == 1)
    }

    @Test func rejectedRegistrationCanRetryWithoutAFalseRegisteredRecord() throws {
        let fake = SchedulerFake()
        fake.acceptRegistration(false)
        let scheduler = BackgroundTaskScheduler(hooks: fake.hooks())
        #expect(throws: BackgroundTaskSchedulerError.registrationRejected("app.sync")) {
            try scheduler.register(policy: policy)
        }
        #expect(scheduler.snapshot("app.sync") == nil)
        fake.acceptRegistration(true)
        try scheduler.register(policy: policy)
        #expect(fake.registrations == 2)
        #expect(scheduler.snapshot("app.sync")?.binding == nil)
    }

    @Test func invalidHostAndPolicyNeverReachNativeRegistration() {
        let fake = SchedulerFake()
        var hooks = fake.hooks()
        hooks.registrationError = .applicationExtensionUnsupported
        let scheduler = BackgroundTaskScheduler(hooks: hooks)
        #expect(throws: BackgroundTaskSchedulerError.applicationExtensionUnsupported) {
            try scheduler.register(policy: policy)
        }
        let normal = BackgroundTaskScheduler(hooks: fake.hooks())
        #expect(throws: BackgroundSyncPolicyValidationError.invalidMinimumInterval) {
            try normal.register(policy: .appRefresh(identifier: "app.sync", minimumInterval: .nan))
        }
        #expect(fake.registrations == 0)
    }

    @Test func bindingConflictsInvalidateAndReleasedGroupsAreCheckedSynchronously() throws {
        let fake = SchedulerFake()
        let scheduler = BackgroundTaskScheduler(hooks: fake.hooks())
        try scheduler.register(policy: policy)
        let availability = SchedulerAvailability()
        try scheduler.bind(identifier: "app.sync", binding: BackgroundTaskBinding(identity: 1,
            isAvailable: {
                // Reenter the registry: availability probes must run outside its lock.
                _ = scheduler.snapshot("app.sync")
                return availability.isLive
            }, operation: { _ in .completed }))
        let first = try #require(scheduler.snapshot("app.sync"))
        try scheduler.bind(identifier: "app.sync", binding: BackgroundTaskBinding(identity: 1,
            isAvailable: { availability.isLive }, operation: { _ in .completed }))
        #expect(scheduler.snapshot("app.sync")?.generation == first.generation)
        #expect(throws: BackgroundTaskSchedulerError.conflictingStore("app.sync")) {
            try scheduler.bind(identifier: "app.sync", binding: BackgroundTaskBinding(identity: 2,
                isAvailable: { true }, operation: { _ in .completed }))
        }
        availability.release()
        try scheduler.bind(identifier: "app.sync", binding: BackgroundTaskBinding(identity: 2,
            isAvailable: { true }, operation: { _ in .completed }))
        #expect(scheduler.snapshot("app.sync")?.binding?.identity == 2)
        #expect(scheduler.snapshot("app.sync")?.generation != first.generation)
        scheduler.invalidate(identity: 1)
        #expect(scheduler.snapshot("app.sync")?.binding?.identity == 2)
        scheduler.invalidate(identity: 2)
        #expect(scheduler.snapshot("app.sync")?.binding == nil)
        #expect(fake.registrations == 1)
    }

    @Test func reschedulingPreservesEarlierOtherAndFailedRequests() async throws {
        let fake = SchedulerFake()
        let submitter = BackgroundTaskSubmitter(hooks: fake.hooks())
        let earlier = BackgroundTaskPendingRequest(identifier: "app.sync", earliestBeginDate: Date(timeIntervalSince1970: 1_010))
        fake.setPending([earlier])
        #expect(try await submitter.schedule(identifier: "app.sync", minimumInterval: 60) == .preservedExisting(identifier: "app.sync"))
        #expect(fake.submitted.isEmpty)

        let other = BackgroundTaskPendingRequest(identifier: "another.owner", earliestBeginDate: Date(timeIntervalSince1970: 9_000))
        fake.setPending([other])
        #expect(try await submitter.schedule(identifier: "app.sync", minimumInterval: 60) == .preservedExisting(identifier: "another.owner"))
        #expect(fake.requests == [other])

        let later = BackgroundTaskPendingRequest(identifier: "app.sync", earliestBeginDate: Date(timeIntervalSince1970: 2_000))
        fake.setPending([later])
        fake.failSubmission(true)
        await #expect(throws: SchedulerFake.Failure.self) {
            try await submitter.schedule(identifier: "app.sync", minimumInterval: 60)
        }
        #expect(fake.requests == [later])
        fake.failSubmission(false)
        #expect(try await submitter.schedule(identifier: "app.sync", minimumInterval: 60) == .submitted)
        #expect(fake.requests.first?.earliestBeginDate == Date(timeIntervalSince1970: 1_060))
    }

    @Test func oneLiveStoreCannotAcquireTwoTaskDrivers() throws {
        let fake = SchedulerFake()
        let scheduler = BackgroundTaskScheduler(hooks: fake.hooks())
        try scheduler.register(policy: policy)
        try scheduler.register(policy: .appRefresh(identifier: "app.other"))
        let binding = BackgroundTaskBinding(identity: 1, isAvailable: { true }, operation: { _ in .completed })
        try scheduler.bind(identifier: "app.sync", binding: binding)
        #expect(throws: BackgroundTaskSchedulerError.storeAlreadyBound("app.sync")) {
            try scheduler.bind(identifier: "app.other", binding: binding)
        }
        #expect(scheduler.snapshot("app.other")?.binding == nil)
        // A different native store may use its own registered identifier.
        try scheduler.bind(identifier: "app.other", binding: BackgroundTaskBinding(identity: 2,
            isAvailable: { true }, operation: { _ in .completed }))
        #expect(scheduler.snapshot("app.other")?.binding?.identity == 2)
    }

    @Test func concurrentSubmissionDecisionsKeepTheEarliestRequest() async throws {
        let fake = SchedulerFake()
        let submitter = BackgroundTaskSubmitter(hooks: fake.hooks())
        try await withThrowingTaskGroup(of: Void.self) { group in
            for interval in [300.0, 200.0, 60.0, 400.0, 100.0] {
                group.addTask { _ = try await submitter.schedule(identifier: "app.sync", minimumInterval: interval) }
            }
            try await group.waitForAll()
        }
        #expect(fake.requests == [BackgroundTaskPendingRequest(identifier: "app.sync", earliestBeginDate: Date(timeIntervalSince1970: 1_060))])
    }

    @Test @MainActor func expirationWaitsForSettlementAndCompletesExactlyOnce() async throws {
        let fake = SchedulerFake()
        let scheduler = BackgroundTaskScheduler(hooks: fake.hooks())
        try scheduler.register(policy: policy)
        let started = SchedulerLatch(), release = SchedulerLatch(), history = SchedulerHistory()
        try scheduler.bind(identifier: "app.sync", binding: BackgroundTaskBinding(identity: 1,
            isAvailable: { true }, operation: { command in
                await history.append(command)
                await started.open()
                await release.wait() // Deliberately refuses to fake cleanup on cancellation.
                await history.recordCancellation(Task.isCancelled)
                return .completed
            }))
        let delivery = SchedulerDelivery()
        scheduler.receive(delivery)
        await started.wait()
        let expiration = try #require(delivery.expirationHandler)
        await Task.detached { expiration() }.value
        #expect(delivery.completions.isEmpty)
        await release.open()
        await scheduler.settleForTesting()
        #expect(await history.cancelled)
        #expect(delivery.completions == [false])
        expiration()
        #expect(delivery.completions == [false])
    }

    @Test @MainActor func expirationBeforeTaskCreationDoesNotStartWork() async throws {
        let fake = SchedulerFake(), history = SchedulerHistory()
        let scheduler = BackgroundTaskScheduler(hooks: fake.hooks())
        try scheduler.register(policy: policy)
        try scheduler.bind(identifier: "app.sync", binding: BackgroundTaskBinding(identity: 1,
            isAvailable: { true }, operation: { command in await history.append(command); return .completed }))
        let delivery = SchedulerDelivery()
        delivery.expireOnInstallation = true
        scheduler.receive(delivery)
        await scheduler.settleForTesting()
        #expect(await history.commands.isEmpty)
        #expect(delivery.completions == [false])
    }

    @Test(arguments: [BackgroundTaskOutcome.completed, .incomplete, .notNeeded])
    @MainActor func onlyActualCompletionReportsSuccess(outcome: BackgroundTaskOutcome) async throws {
        let fake = SchedulerFake()
        let scheduler = BackgroundTaskScheduler(hooks: fake.hooks())
        try scheduler.register(policy: policy)
        try scheduler.bind(identifier: "app.sync", binding: BackgroundTaskBinding(identity: 1,
            isAvailable: { true }, operation: { _ in outcome }))
        let delivery = SchedulerDelivery()
        scheduler.receive(delivery)
        await scheduler.settleForTesting()
        #expect(delivery.completions == [outcome == .completed])
    }

    @Test @MainActor func unboundColdDeliveryRetriesWithoutOpeningAStore() async throws {
        let fake = SchedulerFake()
        let scheduler = BackgroundTaskScheduler(hooks: fake.hooks())
        try scheduler.register(policy: policy)
        let delivery = SchedulerDelivery()
        scheduler.receive(delivery)
        await scheduler.settleForTesting()
        await scheduler.schedule("app.sync")
        #expect(delivery.completions == [false])
        #expect(fake.submitted.count == 1)
        #expect(fake.requests.first?.identifier == "app.sync")
    }

    @Test @MainActor func foregroundTakeoverWaitsForRefreshCleanupThenResumes() async throws {
        let fake = SchedulerFake()
        let scheduler = BackgroundTaskScheduler(hooks: fake.hooks())
        try scheduler.register(policy: policy)
        let started = SchedulerLatch(), release = SchedulerLatch(), history = SchedulerHistory()
        try scheduler.bind(identifier: "app.sync", binding: BackgroundTaskBinding(identity: 1,
            isAvailable: { true }, operation: { command in
                await history.append(command)
                if case .refresh = command { await started.open(); await release.wait() }
                return .completed
            }))
        scheduler.observe(.background)
        await scheduler.settleForTesting()
        let delivery = SchedulerDelivery()
        scheduler.receive(delivery)
        await started.wait()
        scheduler.observe(.active)
        #expect(await history.commands == [.suspend, .refresh(duration: 20)])
        #expect(delivery.completions.isEmpty)
        await release.open()
        await scheduler.settleForTesting()
        #expect(await history.commands == [.suspend, .refresh(duration: 20), .resume])
        #expect(delivery.completions == [false])
        scheduler.observe(.inactive)
        await scheduler.settleForTesting()
        scheduler.observe(.active)
        await scheduler.settleForTesting()
        #expect(await history.commands == [.suspend, .refresh(duration: 20), .resume])
    }

    @Test @MainActor func protectedDataAvailabilityAloneNeverClaimsForeground() async throws {
        let fake = SchedulerFake(), history = SchedulerHistory()
        let scheduler = BackgroundTaskScheduler(hooks: fake.hooks())
        try scheduler.register(policy: policy)
        try scheduler.bind(identifier: "app.sync", binding: BackgroundTaskBinding(identity: 1,
            isAvailable: { true }, operation: { command in await history.append(command); return .completed }))
        scheduler.observe(.inactive)
        scheduler.observe(.protectedDataAvailable)
        await scheduler.settleForTesting()
        #expect(await history.commands.isEmpty)
        scheduler.observe(.protectedDataUnavailable)
        await scheduler.settleForTesting()
        scheduler.observe(.protectedDataAvailable)
        await scheduler.settleForTesting()
        #expect(await history.commands == [.suspend])
    }

    @Test @MainActor func protectedDataLossCancelsRefreshAndAvailabilityWaitsForForeground() async throws {
        let fake = SchedulerFake()
        let scheduler = BackgroundTaskScheduler(hooks: fake.hooks())
        try scheduler.register(policy: policy)
        let started = SchedulerLatch(), release = SchedulerLatch(), history = SchedulerHistory()
        try scheduler.bind(identifier: "app.sync", binding: BackgroundTaskBinding(identity: 1,
            isAvailable: { true }, operation: { command in
                await history.append(command)
                if case .refresh = command {
                    await started.open()
                    // Cancellation requests cleanup; it cannot manufacture a
                    // settled receipt while this native-work stand-in waits.
                    await release.wait()
                    await history.recordCancellation(Task.isCancelled)
                }
                return .completed
            }))
        scheduler.observe(.background)
        await scheduler.settleForTesting()
        let delivery = SchedulerDelivery()
        scheduler.receive(delivery)
        await started.wait()
        let staleExpiration = try #require(delivery.expirationHandler)

        scheduler.observe(.protectedDataUnavailable)
        #expect(delivery.completions.isEmpty)
        scheduler.observe(.protectedDataAvailable)
        #expect(delivery.completions.isEmpty)
        #expect(await history.commands == [.suspend, .refresh(duration: 20)])

        await release.open()
        await scheduler.settleForTesting()
        #expect(await history.cancelled)
        #expect(delivery.completions == [false])
        #expect(delivery.expirationHandler == nil)
        #expect(await history.commands == [.suspend, .refresh(duration: 20)])

        scheduler.observe(.active)
        await scheduler.settleForTesting()
        #expect(await history.commands == [.suspend, .refresh(duration: 20), .resume])
        staleExpiration()
        await scheduler.settleForTesting()
        #expect(delivery.completions == [false])
        #expect(await history.commands == [.suspend, .refresh(duration: 20), .resume])
    }

    @Test @MainActor func coldBackgroundNotificationDoesNotCancelItsDeliveredTask() async throws {
        let fake = SchedulerFake(), history = SchedulerHistory()
        let scheduler = BackgroundTaskScheduler(hooks: fake.hooks())
        try scheduler.register(policy: policy)
        let started = SchedulerLatch(), release = SchedulerLatch()
        try scheduler.bind(identifier: "app.sync", binding: BackgroundTaskBinding(identity: 1,
            isAvailable: { true }, operation: { command in
                await history.append(command)
                await started.open(); await release.wait()
                await history.recordCancellation(Task.isCancelled)
                return .completed
            }))
        let delivery = SchedulerDelivery()
        scheduler.receive(delivery) // BGTask runtime can arrive before a UIApplication object.
        await started.wait()
        scheduler.observe(.background)
        await release.open()
        await scheduler.settleForTesting()
        #expect(!(await history.cancelled))
        #expect(delivery.completions == [true])
        #expect(await history.commands == [.refresh(duration: 20)])
        #expect(fake.assertions.isEmpty) // BGTask already owns this runtime.
    }

    @Test @MainActor func latestForegroundDesireRetriesACancelledResume() async throws {
        let fake = SchedulerFake(), history = SchedulerHistory()
        let scheduler = BackgroundTaskScheduler(hooks: fake.hooks())
        try scheduler.register(policy: policy)
        let started = SchedulerLatch(), release = SchedulerLatch()
        try scheduler.bind(identifier: "app.sync", binding: BackgroundTaskBinding(identity: 1,
            isAvailable: { true }, operation: { command in
                await history.append(command)
                if await history.commands.count == 1 {
                    await started.open(); await release.wait()
                }
                return .completed
            }))
        scheduler.observe(.active)
        await started.wait()
        scheduler.observe(.background)
        scheduler.observe(.active)
        await release.open()
        await scheduler.settleForTesting()
        #expect(await history.commands == [.resume, .resume])
        #expect(fake.assertions.first?.ends == 1)
    }

    @Test(arguments: [BackgroundTaskCommand.resume, .suspend])
    @MainActor func failedLifecycleWorkCanRetryWithoutSpinning(command: BackgroundTaskCommand) async throws {
        let fake = SchedulerFake(), history = SchedulerHistory()
        let scheduler = BackgroundTaskScheduler(hooks: fake.hooks())
        try scheduler.register(policy: policy)
        try scheduler.bind(identifier: "app.sync", binding: BackgroundTaskBinding(identity: 1,
            isAvailable: { true }, operation: { received in
                await history.append(received)
                if await history.commands.count == 1 { throw SchedulerFake.Failure.lifecycle }
                return .completed
            }))
        let event: BackgroundTaskLifecycleEvent = command == .resume ? .active : .background
        scheduler.observe(event)
        await scheduler.settleForTesting()
        #expect(await history.commands == [command])
        #expect(fake.messages.count == 1)

        scheduler.observe(event)
        await scheduler.settleForTesting()
        #expect(await history.commands == [command, command])
        scheduler.observe(event)
        await scheduler.settleForTesting()
        #expect(await history.commands == [command, command])
        if command == .suspend { #expect(fake.assertions.first?.ends == 1) }
    }

    @Test @MainActor func cleanupAssertionEndsOnlyAfterSuspensionSettles() async throws {
        let fake = SchedulerFake()
        let scheduler = BackgroundTaskScheduler(hooks: fake.hooks())
        try scheduler.register(policy: policy)
        let started = SchedulerLatch(), release = SchedulerLatch(), history = SchedulerHistory()
        try scheduler.bind(identifier: "app.sync", binding: BackgroundTaskBinding(identity: 1,
            isAvailable: { true }, operation: { command in
                await history.append(command)
                if command == .suspend {
                    await started.open(); await release.wait()
                    await history.recordCancellation(Task.isCancelled)
                }
                return .completed
            }))
        scheduler.observe(.active)
        await scheduler.settleForTesting()
        scheduler.observe(.background)
        await started.wait()
        let assertion = try #require(fake.assertions.first)
        #expect(assertion.ends == 0)
        assertion.expire()
        #expect(assertion.ends == 0)
        await release.open()
        await scheduler.settleForTesting()
        #expect(assertion.ends == 1)
        #expect(await history.cancelled)
    }

    @Test @MainActor func invalidationRetiresBindingBeforeOldWorkCompletes() async throws {
        let fake = SchedulerFake()
        let scheduler = BackgroundTaskScheduler(hooks: fake.hooks())
        try scheduler.register(policy: policy)
        let started = SchedulerLatch(), release = SchedulerLatch()
        try scheduler.bind(identifier: "app.sync", binding: BackgroundTaskBinding(identity: 1,
            isAvailable: { true }, operation: { _ in await started.open(); await release.wait(); return .completed }))
        let delivery = SchedulerDelivery()
        scheduler.receive(delivery)
        await started.wait()
        scheduler.invalidate(identity: 1)
        #expect(scheduler.snapshot("app.sync")?.binding == nil)
        #expect(delivery.completions.isEmpty)
        await release.open()
        await scheduler.settleForTesting()
        #expect(delivery.completions == [false])
    }

    @Test @MainActor func anotherFacadeOfTheSameStoreDoesNotCancelItsAttempt() async throws {
        let fake = SchedulerFake(), history = SchedulerHistory()
        let scheduler = BackgroundTaskScheduler(hooks: fake.hooks())
        try scheduler.register(policy: policy)
        let started = SchedulerLatch(), release = SchedulerLatch()
        let binding = BackgroundTaskBinding(identity: 1, isAvailable: { true }, operation: { _ in
            await started.open(); await release.wait()
            await history.recordCancellation(Task.isCancelled)
            return .completed
        })
        try scheduler.bind(identifier: "app.sync", binding: binding)
        let delivery = SchedulerDelivery()
        scheduler.receive(delivery)
        await started.wait()
        try scheduler.bind(identifier: "app.sync", binding: binding)
        await release.open()
        await scheduler.settleForTesting()
        #expect(!(await history.cancelled))
        #expect(delivery.completions == [true])
    }

    @Test @MainActor func newMembersDuringResumeReceiveTheForegroundState() async throws {
        let fake = SchedulerFake(), history = SchedulerHistory()
        let scheduler = BackgroundTaskScheduler(hooks: fake.hooks())
        try scheduler.register(policy: policy)
        let started = SchedulerLatch(), release = SchedulerLatch()
        try scheduler.bind(identifier: "app.sync", binding: BackgroundTaskBinding(identity: 1,
            isAvailable: { true }, operation: { command in
                await history.append(command)
                if await history.commands.count == 1 {
                    await started.open(); await release.wait()
                    await history.recordCancellation(Task.isCancelled)
                }
                return .completed
            }))
        scheduler.observe(.active)
        await started.wait()
        let generation = scheduler.snapshot("app.sync")?.generation
        scheduler.membersDidChange(identity: 1)
        #expect(scheduler.snapshot("app.sync")?.generation == generation)
        await release.open()
        await scheduler.settleForTesting()
        #expect(!(await history.cancelled))
        #expect(await history.commands == [.resume, .resume])
        scheduler.observe(.active)
        await scheduler.settleForTesting()
        #expect(await history.commands == [.resume, .resume])
    }

    @Test @MainActor func membershipChangesDoNotExpireADeliveredTask() async throws {
        let fake = SchedulerFake(), history = SchedulerHistory()
        let scheduler = BackgroundTaskScheduler(hooks: fake.hooks())
        try scheduler.register(policy: policy)
        let started = SchedulerLatch(), release = SchedulerLatch()
        try scheduler.bind(identifier: "app.sync", binding: BackgroundTaskBinding(identity: 1,
            isAvailable: { true }, operation: { _ in
                await started.open(); await release.wait()
                await history.recordCancellation(Task.isCancelled)
                return .completed
            }))
        let delivery = SchedulerDelivery()
        scheduler.receive(delivery)
        await started.wait()
        scheduler.membersDidChange(identity: 1)
        await release.open()
        await scheduler.settleForTesting()
        #expect(!(await history.cancelled))
        #expect(delivery.completions == [true])
    }

    @Test func submissionFailureIsObservable() async throws {
        let fake = SchedulerFake()
        fake.failSubmission(true)
        let scheduler = BackgroundTaskScheduler(hooks: fake.hooks())
        try scheduler.register(policy: policy)
        await scheduler.schedule("app.sync")
        #expect(fake.messages.count == 1)
        #expect(fake.messages[0].contains("app.sync"))
    }
}
