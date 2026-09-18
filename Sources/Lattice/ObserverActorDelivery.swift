import Foundation

/// One actor-bound mailbox per created handle, shared by its value copies,
/// cache resurrection and attached clones. Every admitted batch is retained;
/// pending payload storage remains unbounded, as in the previous Task-per-batch
/// path. A blocked destination actor or callback still blocks delivery.
///
/// The operation is formed in the actual creation actor's isolated context
/// and passed UNCHANGED to Task. Each turn runs one whole batch and schedules
/// at most one next turn directly on that same actor. No generic-executor
/// currying closure or Task.yield is inserted before the next batch.
final class ObserverActorDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [(@Sendable () -> Void)?] = []
    private var head = 0
    private var scheduled = false
    // The stored operation captures self weakly to avoid an idle cycle. This
    // lease keeps queued work alive even if the caller releases its facade.
    // It exists only while a drain is scheduled and is released off-lock.
    private var pendingLifetime: ObserverActorDelivery?
    private var operation: @Sendable @isolated(any) () async -> Void = {}

    // Swift's Task initializer uses this compiler-supported inheritance
    // attribute. Applying it inside a nonisolated currying closure instead
    // would lose the creation actor, despite capturing the same Actor value.
    private static func inheritIsolation(
        @_inheritActorContext _ operation: @escaping @Sendable @isolated(any) () async -> Void
    ) -> @Sendable @isolated(any) () async -> Void { operation }

    // Preserve the original optional isolated parameter through callers.
    // Unwrapping it into a new binding loses the compiler's isolation proof.
    init(isolation: isolated (any Actor)?) {
        precondition(isolation != nil, "Actor delivery requires an attaching actor")
        operation = Self.inheritIsolation { [weak self] in
            _ = isolation
            self?.deliverTurn()
        }
    }

    func enqueue(_ batch: @escaping @Sendable () -> Void) {
        lock.lock()
        batches.append(batch)
        let needsTask = !scheduled
        if needsTask {
            scheduled = true
            pendingLifetime = self
        }
        lock.unlock()
        if needsTask { Task(operation: operation) }
    }

    private func takeNext() -> (@Sendable () -> Void)? {
        lock.lock()
        guard head < batches.count else { lock.unlock(); return nil }
        // Retain before clearing its slot: a capture's final release may
        // reenter this mailbox and must never occur under the state lock.
        let batch = batches[head]!
        batches[head] = nil
        head += 1
        if head == batches.count {
            // Every slot is nil here. Release burst capacity when idle.
            batches = []
            head = 0
        } else if head >= 64 && head >= batches.count - head {
            batches.removeFirst(head)
            head = 0
        }
        lock.unlock()
        return batch
    }

    private func deliverBatch() {
        // Separate synchronous scope: execute and release payload outside the
        // lock before deciding whether another turn is needed.
        var batch = takeNext()
        batch?()
        batch = nil
    }

    private func deliverTurn() {
        deliverBatch()
        let releasedLifetime: ObserverActorDelivery?
        lock.lock()
        let needsNext = head < batches.count
        if needsNext {
            releasedLifetime = nil
        } else {
            scheduled = false
            releasedLifetime = pendingLifetime
            pendingLifetime = nil
        }
        lock.unlock()
        // The current actor turn contains no await. The next actor turn
        // cannot enter its callback until this synchronous body returns.
        if needsNext { Task(operation: operation) }
        withExtendedLifetime(releasedLifetime) {}
    }
}
