import Testing
@testable import LatticeServerKit

@Suite("ObserverActorDiagnostics")
struct ObserverActorDiagnosticsTests {
    @Test func disabledDoesNotAllocateIdentifiersOrPublish() {
        let recorder = ObserverActorDiagnostics(enabled: false)
        #expect(recorder.groupID() == nil)
        let scope = recorder.begin(.unsubscribe, at: 1)
        #expect(scope == nil)
        recorder.phase(scope, .observerRemoval, at: 2)
        recorder.end(scope, at: 3)
        #expect(recorder.snapshotLines(reason: .thrownFailure, at: 4).isEmpty)
    }

    @Test func nativePhaseIsReadableBeforeActorScopeReturns() throws {
        let recorder = ObserverActorDiagnostics(enabled: true)
        let group = try #require(recorder.groupID())
        let scope = recorder.begin(.unsubscribe, group: group, at: 10)
        recorder.phase(scope, .observerRemoval, at: 20)
        let held = recorder.snapshotLines(reason: .p95Gate, at: 5_000_000_020)
        #expect(held.contains { $0.contains("state=current") && $0.contains("phase=observerRemoval")
            && $0.contains("group=\(group)") && $0.contains("phase_age_ns=5000000000") })
        recorder.phase(scope, .tokenRelease, at: 5_000_000_021)
        recorder.end(scope, at: 5_000_000_022)
        let finished = recorder.snapshotLines(reason: .p95Gate, at: 5_000_000_030)
        #expect(!finished.contains { $0.contains("state=current") })
        #expect(finished.contains { $0.contains("phase=observerRemoval")
            && $0.contains("elapsed_ns=5000000001") && $0.contains("exited_ns=5000000021") })
    }

    @Test func retainsEarlyLongPhaseWithBoundedHistoryAndOutput() {
        let recorder = ObserverActorDiagnostics(enabled: true)
        let long = recorder.begin(.installGroup, group: recorder.groupID(), at: 1)
        recorder.phase(long, .observerRegistration, at: 2)
        recorder.end(long, at: 10_000)
        for i in UInt64(0)..<200 {
            let scope = recorder.begin(.advance, group: 2, at: 10_001 + i * 2)
            recorder.end(scope, at: 10_002 + i * 2)
        }
        let current = recorder.begin(.nudge, group: 3, at: 11_000)
        let first = recorder.snapshotLines(reason: .p95Gate, at: 11_001)
        #expect(first.count <= 66)
        #expect(first.contains { $0.contains("phase=observerRegistration") && $0.contains("elapsed_ns=9998") })
        #expect(first.contains { $0.contains("recent_evictions=170") && $0.contains("missing_intervals=unknown") })
        #expect(recorder.snapshotLines(reason: .p95Gate, at: 11_002).count <= 66)
        #expect(recorder.snapshotLines(reason: .p95Gate, at: 11_003).count <= 66)
        #expect(recorder.snapshotLines(reason: .p95Gate, at: 11_004).isEmpty)
        recorder.end(current, at: 11_005)
    }

    @Test func rejectedOverlappingScopeCannotClearTheOwner() {
        let recorder = ObserverActorDiagnostics(enabled: true)
        let owner = recorder.begin(.nudge, group: 1, at: 1)
        let rejected = recorder.begin(.activate, group: 2, at: 2)
        #expect(rejected == nil)
        recorder.end(rejected, at: 3)
        let lines = recorder.snapshotLines(reason: .p95Gate, at: 4)
        #expect(lines.contains { $0.contains("overlapping_scopes=1") })
        #expect(lines.contains { $0.contains("state=current") && $0.contains("operation=nudge")
            && $0.contains("group=1") })
        recorder.end(owner, at: 5)
    }
}
