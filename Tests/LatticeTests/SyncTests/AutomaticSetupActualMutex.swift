import Foundation
import LatticeAutomaticSetupTestSupport
@testable import Lattice
@testable import LatticeServerKit

/// Test-only custody of the exact opened native writer. This is deliberately
/// independent of production setup lifetime/capacity and never supplies an
/// admission result. The C++ helper owns one bounded actual mutex worker.
final class AutomaticSetupActualMutex: @unchecked Sendable {
    struct Facts: Sendable {
        let acquired, workerFinished, releaseRequested, acquisitionTimedOut: Bool
        let safetyReleased, writerRetired: Bool
        let status: Int32
    }
    private let value: lattice.automatic_setup_test_support.writer_mutex_hold
    init(owner: Lattice) {
        precondition(RelayExecutionPool.io.isCurrentWorker)
        value = lattice.automatic_setup_test_support.writer_mutex_hold.holdActualWriter(owner.cxxLatticeRef)
    }
    var facts: Facts {
        let f = value.facts()
        return .init(acquired: f.acquisitionSucceeded, workerFinished: f.workerFinished,
                     releaseRequested: f.releaseRequested, acquisitionTimedOut: f.acquisitionTimedOut,
                     safetyReleased: f.safetyDeadlineReleased, writerRetired: f.writerRetired, status: f.status)
    }
    func requestRelease() { value.requestRelease() }
    func retire(on originalKey: String) async -> Bool {
        await withCheckedContinuation { continuation in
            RelayExecutionPool.io.submitRequired(for: originalKey) { [self] in
                precondition(RelayExecutionPool.io.isCurrentWorker)
                // Original key is captured by this submission. Native never
                // mistakes a prior OS thread id for the keyed lane identity.
                continuation.resume(returning: value.retireOnIO())
            }
        }
    }
}
