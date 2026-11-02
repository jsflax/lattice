import Foundation
import Testing
import XCTest
@testable import Lattice

private final class BindingBackend: BackgroundSyncBackend, @unchecked Sendable {
    let identityHash: Int64
    private let lock = NSLock()
    private var commands: [BackgroundTaskCommand] = []
    private var closes = 0
    let operation: @Sendable (BackgroundTaskCommand, SyncWorkCancellation) throws -> Lattice.SyncOnceResult

    init(identity: Int64, operation: @escaping @Sendable (BackgroundTaskCommand, SyncWorkCancellation) throws -> Lattice.SyncOnceResult = { _, _ in .completed }) {
        identityHash = identity
        self.operation = operation
    }

    func performBackgroundSync(_ command: BackgroundTaskCommand,
                               cancellation: SyncWorkCancellation) throws -> Lattice.SyncOnceResult {
        lock.lock(); commands.append(command); lock.unlock()
        return try operation(command, cancellation)
    }

    func closeBackgroundSyncMember() { lock.withLock { closes += 1 } }
    var closeCount: Int { lock.withLock { closes } }
    var recordedCommands: [BackgroundTaskCommand] { lock.withLock { commands } }
    var count: Int { lock.lock(); defer { lock.unlock() }; return commands.count }
}

/// This fixture deliberately occupies an actor to test a queued admission.
/// Its blocked job must not consume a Swift cooperative executor thread.
private final class BindingOwnerExecutor: SerialExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "lattice.binding-owner-test")
    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        queue.async { unowned.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }
}

private actor BindingOwner {
    nonisolated let executor = BindingOwnerExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    let backend: BindingBackend
    init(_ backend: BindingBackend) { self.backend = backend }
    func group() throws -> BackgroundSyncBindingGroup {
        try BackgroundSyncBindings.attach(capability: backend, isolation: self)
    }
    func hold(entered: BindingSignal, release: BindingSignal) {
        entered.set()
        _ = release.waitBlocking()
    }
}

private final class WeakBindingOwner: @unchecked Sendable {
    weak var value: BindingOwner?
    init(_ owner: BindingOwner) { value = owner }
}

private final class BindingSignal: @unchecked Sendable {
    private let condition = NSCondition()
    private var value = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    var isSet: Bool { condition.lock(); defer { condition.unlock() }; return value }

    func set() {
        condition.lock()
        value = true
        let pending = Array(waiters.values)
        waiters.removeAll()
        condition.broadcast()
        condition.unlock()
        for waiter in pending { waiter.resume(returning: true) }
    }

    /// Only the synchronous native fake or dedicated actor queue may block.
    /// An async test awaiting a receipt must use waitAsync instead.
    func waitBlocking() -> Bool {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(2)
        while !value {
            if !condition.wait(until: deadline) { return value }
        }
        return true
    }

    func waitAsync() async -> Bool {
        await withCheckedContinuation { continuation in
            let id = UUID()
            condition.lock()
            if value {
                condition.unlock()
                continuation.resume(returning: true)
                return
            }
            waiters[id] = continuation
            condition.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
                condition.lock()
                let waiter = waiters.removeValue(forKey: id)
                condition.unlock()
                waiter?.resume(returning: false)
            }
        }
    }
}

@Suite("Background sync weak bindings")
struct BackgroundSyncBindingTests {
    @Test func commandsHopToTheOwningActorBeforeNativeWork() async throws {
        let first = BindingBackend(identity: 91001), second = BindingBackend(identity: 91002)
        let firstOwner = BindingOwner(first), secondOwner = BindingOwner(second)
        let firstGroup = try await firstOwner.group(), secondGroup = try await secondOwner.group()
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            tasks.addTask { () async throws -> Void in
                for _ in 0..<40 {
                    let result = try await firstGroup.perform(.resume)
                    #expect(result == .completed)
                }
            }
            tasks.addTask { () async throws -> Void in
                for _ in 0..<40 {
                    let result = try await secondGroup.perform(.suspend)
                    #expect(result == .completed)
                }
            }
            try await tasks.waitForAll()
        }
        #expect(first.count == 40)
        #expect(second.count == 40)
        withExtendedLifetime((firstOwner, secondOwner)) {}
    }

    @Test func idleRegistrationDoesNotRetainItsActorOrStore() async throws {
        func make() async throws -> (BackgroundTaskBinding, WeakBindingOwner) {
            let owner = BindingOwner(BindingBackend(identity: 91003))
            let weakOwner = WeakBindingOwner(owner)
            return (try await owner.group().binding, weakOwner)
        }
        let (binding, owner) = try await make()
        #expect(owner.value == nil)
        #expect(!binding.isAvailable())
        #expect(try await binding.operation(.resume) == .notNeeded)
    }

    @Test func releasingNewestFacadePreservesTheEarlierOne() async throws {
        let first = BindingBackend(identity: 91004)
        let group = try BackgroundSyncBindings.attach(capability: first, isolation: nil)
        func addTemporary() throws {
            let temporary = BindingBackend(identity: 91004)
            let same = try BackgroundSyncBindings.attach(capability: temporary, isolation: nil)
            #expect(same === group)
        }
        try addTemporary()
        #expect(group.isAvailable)
        #expect(try await group.perform(.resume) == .completed)
        #expect(first.count == 1)
    }

    @Test func invalidationRejectsRetainedCapabilities() async throws {
        let backend = BindingBackend(identity: 91005)
        let group = try BackgroundSyncBindings.attach(capability: backend, isolation: nil)
        group.invalidate()
        #expect(try await group.perform(.refresh(duration: 1)) == .unavailable)
        #expect(backend.count == 0)
    }

    @Test func cancellationBeforeNativeTokenInstallationIsNotLost() {
        let token = SyncWorkCancellation(), called = BindingSignal()
        token.cancel()
        token.install { called.set() }
        #expect(called.isSet)
        #expect(token.isCancelled)
        token.clearHandler()
    }

    @Test func foregroundTransferDisarmsObsoleteCommandCancellation() {
        let command = SyncWorkCancellation(), native = SyncWorkCancellation()
        command.install { native.cancel() }
        #expect(command.disarmIfNotCancelled())
        command.cancel()
        #expect(command.isCancelled)
        #expect(!native.isCancelled)

        let cancelledCommand = SyncWorkCancellation()
        cancelledCommand.install { native.cancel() }
        cancelledCommand.cancel()
        #expect(!cancelledCommand.disarmIfNotCancelled())
        #expect(native.isCancelled)
    }

    @Test func lineageResumesDistinctNativeMembersButOnlyOwnerRefreshes() async throws {
        let primary = BindingBackend(identity: 91101), first = BindingBackend(identity: 91102)
        let latest = BindingBackend(identity: 91102), second = BindingBackend(identity: 91103)
        let lineage = BackgroundSyncLineage()
        let group = try BackgroundSyncBindings.attachManaged(capability: primary, owner: nil,
            lineage: lineage, ownsLifecycle: true)
        for member in [first, latest, second] {
            let joined = try BackgroundSyncBindings.attachManaged(capability: member, owner: nil,
                lineage: lineage, ownsLifecycle: false)
            #expect(joined === group)
        }
        #expect(try await group.perform(.resume) == .completed)
        #expect(primary.recordedCommands == [.resume])
        #expect(first.count == 0)
        #expect(latest.recordedCommands == [.resume])
        #expect(second.recordedCommands == [.resume])
        #expect(try await group.perform(.suspend) == .completed)
        #expect(try await group.perform(.refresh(duration: 2)) == .completed)
        #expect(primary.recordedCommands.prefix(2) == [.resume, .suspend])
        #expect(primary.count == 3)
        if case let .refresh(duration) = primary.recordedCommands.last {
            #expect(duration > 0 && duration <= 2)
        } else { Issue.record("Only the primary should refresh") }
        #expect(latest.recordedCommands == [.resume, .suspend, .suspend])
        #expect(second.recordedCommands == [.resume, .suspend, .suspend])
    }

    @Test func alreadyRunningOwnerLeavesBorrowedForegroundWorkAlone() async throws {
        let primary = BindingBackend(identity: 91104) { command, _ in
            if case .refresh = command { return .alreadyRunning }
            return .completed
        }
        let borrowed = BindingBackend(identity: 91105)
        let lineage = BackgroundSyncLineage()
        let group = try BackgroundSyncBindings.attachManaged(capability: primary, owner: nil,
            lineage: lineage, ownsLifecycle: true)
        _ = try BackgroundSyncBindings.attachManaged(capability: borrowed, owner: nil,
            lineage: lineage, ownsLifecycle: false)
        #expect(try await group.perform(.resume) == .completed)
        #expect(try await group.perform(.refresh(duration: 2)) == .alreadyRunning)
        #expect(borrowed.recordedCommands == [.resume])
    }

    @Test func derivedCloseDoesNotInvalidateOwnerOrSibling() async throws {
        let primary = BindingBackend(identity: 91106), derived = BindingBackend(identity: 91107)
        let sibling = BindingBackend(identity: 91108), lineage = BackgroundSyncLineage()
        let group = try BackgroundSyncBindings.attachManaged(capability: primary, owner: nil,
            lineage: lineage, ownsLifecycle: true)
        for member in [derived, sibling] {
            _ = try BackgroundSyncBindings.attachManaged(capability: member, owner: nil,
                lineage: lineage, ownsLifecycle: false)
        }
        BackgroundSyncBindings.invalidate(identity: derived.identityHash)
        derived.closeBackgroundSyncMember() // Lattice._close performs this part.
        #expect(!group.isInvalidated)
        try lineage.validate()
        #expect(try await group.perform(.resume) == .completed)
        #expect(primary.count == 1)
        #expect(sibling.count == 1)
        #expect(derived.count == 0)
        #expect(derived.closeCount == 1)
        #expect(throws: (any Swift.Error).self) {
            try BackgroundSyncBindings.attachManaged(capability: derived, owner: nil,
                lineage: lineage, ownsLifecycle: false)
        }
    }

    @Test func ownerCloseRetiresBorrowersAndRejectsStaleReferences() async throws {
        let primary = BindingBackend(identity: 91109), first = BindingBackend(identity: 91110)
        let second = BindingBackend(identity: 91111), lineage = BackgroundSyncLineage()
        let group = try BackgroundSyncBindings.attachManaged(capability: primary, owner: nil,
            lineage: lineage, ownsLifecycle: true)
        for member in [first, second] {
            _ = try BackgroundSyncBindings.attachManaged(capability: member, owner: nil,
                lineage: lineage, ownsLifecycle: false)
        }
        BackgroundSyncBindings.invalidate(identity: primary.identityHash)
        BackgroundSyncBindings.invalidate(identity: primary.identityHash)
        #expect(group.isInvalidated)
        #expect(primary.closeCount == 0, "The outer owner close handles its own backend")
        #expect(first.closeCount == 1)
        #expect(second.closeCount == 1)
        #expect(throws: (any Swift.Error).self) { try lineage.validate() }
        #expect(throws: (any Swift.Error).self) {
            try BackgroundSyncBindings.attachManaged(capability: BindingBackend(identity: 91112), owner: nil,
                lineage: lineage, ownsLifecycle: false)
        }
        #expect(try await group.perform(.resume) == .unavailable)
    }

    @Test func nativeIdentityCannotJoinDifferentLiveLineages() throws {
        let first = BindingBackend(identity: 91113), second = BindingBackend(identity: 91114)
        let borrowed = BindingBackend(identity: 91115)
        let firstLineage = BackgroundSyncLineage(), secondLineage = BackgroundSyncLineage()
        _ = try BackgroundSyncBindings.attachManaged(capability: first, owner: nil,
            lineage: firstLineage, ownsLifecycle: true)
        _ = try BackgroundSyncBindings.attachManaged(capability: second, owner: nil,
            lineage: secondLineage, ownsLifecycle: true)
        _ = try BackgroundSyncBindings.attachManaged(capability: borrowed, owner: nil,
            lineage: firstLineage, ownsLifecycle: false)
        #expect(throws: (any Swift.Error).self) {
            try BackgroundSyncBindings.attachManaged(capability: borrowed, owner: nil,
                lineage: secondLineage, ownsLifecycle: false)
        }
    }

    @Test func unconfirmedMemberSuspensionCannotBecomeCompleted() async throws {
        let primary = BindingBackend(identity: 91116)
        let borrowed = BindingBackend(identity: 91117) { command, _ in
            command == .suspend ? .unavailable : .completed
        }
        let lineage = BackgroundSyncLineage()
        let group = try BackgroundSyncBindings.attachManaged(capability: primary, owner: nil,
            lineage: lineage, ownsLifecycle: true)
        _ = try BackgroundSyncBindings.attachManaged(capability: borrowed, owner: nil,
            lineage: lineage, ownsLifecycle: false)
        #expect(try await group.perform(.suspend) == .budgetExhausted)
        await #expect(throws: (any Swift.Error).self) {
            try await group.perform(.refresh(duration: 2))
        }
    }

    @Test func expiredNativeAliasDoesNotBlockLaterAddressReuse() throws {
        let primary = BindingBackend(identity: 91120), lineage = BackgroundSyncLineage()
        let group = try BackgroundSyncBindings.attachManaged(capability: primary, owner: nil,
            lineage: lineage, ownsLifecycle: true)
        func retireTemporaryAllocation() throws {
            let old = BindingBackend(identity: 91121)
            _ = try BackgroundSyncBindings.attachManaged(capability: old, owner: nil,
                lineage: lineage, ownsLifecycle: false)
            BackgroundSyncBindings.invalidate(identity: old.identityHash)
            old.closeBackgroundSyncMember()
        }
        try retireTemporaryAllocation()
        let reusedAddress = BindingBackend(identity: 91121)
        let joined = try BackgroundSyncBindings.attachManaged(capability: reusedAddress, owner: nil,
            lineage: lineage, ownsLifecycle: false)
        #expect(joined === group)
        #expect(reusedAddress.closeCount == 0)
    }

    @Test func deadOriginalOwnerCannotBeReplacedByABorrowerAtItsAddress() throws {
        let lineage = BackgroundSyncLineage(), borrowed = BindingBackend(identity: 91123)
        func createFamily() throws {
            let primary = BindingBackend(identity: 91122)
            _ = try BackgroundSyncBindings.attachManaged(capability: primary, owner: nil,
                lineage: lineage, ownsLifecycle: true)
            _ = try BackgroundSyncBindings.attachManaged(capability: borrowed, owner: nil,
                lineage: lineage, ownsLifecycle: false)
        }
        try createFamily()
        let newAllocationAtOldOwnerAddress = BindingBackend(identity: 91122)
        #expect(throws: (any Swift.Error).self) {
            try BackgroundSyncBindings.attachManaged(capability: newAllocationAtOldOwnerAddress, owner: nil,
                lineage: lineage, ownsLifecycle: false)
        }
        #expect(borrowed.closeCount == 1)
        #expect(lineage.current?.isInvalidated == true)
    }

    @Test func refreshBudgetIncludesBorrowerSettlement() async throws {
        let primary = BindingBackend(identity: 91124)
        let borrowed = BindingBackend(identity: 91125) { command, _ in
            if command == .suspend { Thread.sleep(forTimeInterval: 0.04) }
            return .completed
        }
        let lineage = BackgroundSyncLineage()
        let group = try BackgroundSyncBindings.attachManaged(capability: primary, owner: nil,
            lineage: lineage, ownsLifecycle: true)
        _ = try BackgroundSyncBindings.attachManaged(capability: borrowed, owner: nil,
            lineage: lineage, ownsLifecycle: false)
        #expect(try await group.perform(.refresh(duration: 0.02)) == .budgetExhausted)
        #expect(borrowed.recordedCommands == [.suspend])
    }

}

/// These tests deliberately park native work or its owning actor while the
/// caller cancels or preempts it. SwiftPM's XCTest phase runs before its parallel Swift
/// Testing phase, so their two-second admission prerequisite measures this
/// scenario instead of competing with every SQL benchmark in the package.
/// Keeping the suite-name prefix also includes them in the strict cooperative
/// executor CI pass; no timeout or cancellation contract is relaxed.
final class BackgroundSyncBindingTestsOrdering: XCTestCase {
    func testCancelledCallerWaitsForNativeSettlement() async throws {
        let entered = BindingSignal(), stopped = BindingSignal(), settled = BindingSignal()
        let backend = BindingBackend(identity: 91006) { _, token in
            token.install { stopped.set() }
            entered.set()
            guard stopped.waitBlocking() else { throw Lattice.Error.databaseError("Cancellation did not reach native work") }
            settled.set()
            return .budgetExhausted
        }
        let group = try BackgroundSyncBindings.attach(capability: backend, isolation: nil)
        let work = Task { try await group.perform(.refresh(duration: 10)) }
        defer { work.cancel(); stopped.set() }
        let didEnter = await entered.waitAsync()
        guard didEnter else {
            work.cancel(); stopped.set(); _ = await work.result
            XCTFail("The native fake must start before testing cancellation")
            return
        }
        work.cancel()
        do {
            _ = try await work.value
            XCTFail("Cancelled work returned success")
        } catch is CancellationError {
            XCTAssertTrue(settled.isSet, "Cancellation must return only after native settlement")
        }
    }

    func testForegroundSettlesAnActiveManualPassBeforeResuming() async throws {
        let entered = BindingSignal(), stopped = BindingSignal(), settled = BindingSignal()
        let backend = BindingBackend(identity: 91007) { command, token in
            if case .refresh = command {
                token.install { stopped.set() }
                entered.set()
                guard stopped.waitBlocking() else { throw Lattice.Error.databaseError("Manual work was not cancelled") }
                settled.set()
                return .budgetExhausted
            }
            guard settled.isSet else {
                throw Lattice.Error.databaseError("Foreground startup preceded manual settlement")
            }
            return .completed
        }
        let group = try BackgroundSyncBindings.attach(capability: backend, isolation: nil)
        let manual = Task { try await group.perform(.refresh(duration: 10)) }
        defer { manual.cancel(); stopped.set() }
        let didEnter = await entered.waitAsync()
        guard didEnter else {
            manual.cancel(); stopped.set(); _ = await manual.result
            XCTFail("The native fake must start before testing foreground takeover")
            return
        }
        let competingRefresh = try await group.perform(.refresh(duration: 10))
        XCTAssertEqual(competingRefresh, .alreadyRunning)
        let foreground = try await group.perform(.resume)
        XCTAssertEqual(foreground, .completed)
        do {
            _ = try await manual.value
            XCTFail("Foreground takeover should cancel the manual pass")
        } catch is CancellationError {}
        XCTAssertEqual(backend.count, 2)
    }

    func testInvalidationCancelsBeforeAQueuedActorHopCanStartNativeWork() async throws {
        let backend = BindingBackend(identity: 91118), owner = BindingOwner(BindingBackend(identity: 91119))
        let lineage = BackgroundSyncLineage()
        let group = try BackgroundSyncBindings.attachManaged(capability: backend, owner: owner,
            lineage: lineage, ownsLifecycle: true)
        let entered = BindingSignal(), release = BindingSignal()
        let occupied = Task { await owner.hold(entered: entered, release: release) }
        defer { release.set() }
        let didEnter = await entered.waitAsync()
        guard didEnter else {
            release.set(); await occupied.value
            XCTFail("The owner actor must be occupied before queueing native admission")
            return
        }
        let work = Task { try await group.perform(.resume) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while group.activeOperationCount == 0 && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(group.activeOperationCount, 1)
        BackgroundSyncBindings.invalidate(identity: backend.identityHash)
        release.set()
        await occupied.value
        do {
            _ = try await work.value
            XCTFail("Retired queued work must be cancelled before native startup")
        } catch is CancellationError {}
        XCTAssertEqual(backend.count, 0)
        withExtendedLifetime(owner) {}
    }

}
