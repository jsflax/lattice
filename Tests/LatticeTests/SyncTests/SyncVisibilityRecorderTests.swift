import Foundation
import Testing

@Suite("Public visibility receipt invariants")
struct SyncVisibilityRecorderTests {
    @Test func lateReadCannotRepairDeadlineOrCompleteAnotherIdentity() {
        let expected = SyncVisibilityExpected(runID: "run", stream: "quiet", phase: "measured", writer: 0, sequence: 0, bytes: 32)
        let recorder = SyncVisibilityRecorder(expected: [expected])
        recorder.schedule(0, at: 10, deadline: 50)
        let unknown = SyncVisibilityExpected(runID: "another-run", stream: "quiet", phase: "measured", writer: 0, sequence: 0, bytes: 32)
        recorder.observed(unknown, at: 20)
        #expect(!recorder.allVisible(phase: "measured"))
        recorder.freeze(phase: "measured")
        recorder.observed(expected, at: 51)
        recorder.observed(expected, at: 52)
        let (rows, counts, _) = recorder.snapshot()
        #expect(rows.count == 1 && rows[0].timedOut)
        #expect(rows[0].firstExactReadNS == nil && rows[0].lateExactReadNS == 51)
        #expect(counts.unknownOperation == 1 && counts.duplicateCallbacks == 1)
        #expect(!recorder.allVisible(phase: "measured"))
    }

    @Test func duplicateCallbacksCannotInflateCoverageAndDiagnosticsStayBounded() {
        let expected = (0..<2).map { SyncVisibilityExpected(runID: "run", stream: "hot", phase: "measured", writer: 0, sequence: $0, bytes: 32) }
        let recorder = SyncVisibilityRecorder(expected: expected)
        for index in 0..<2 { recorder.schedule(index, at: 10, deadline: 50) }
        recorder.observed(expected[0], at: 20, readerStoreID: "original-watcher")
        recorder.observed(expected[0], at: 21, readerStoreID: "duplicate-watcher")
        #expect(!recorder.allVisible(phase: "measured"))
        recorder.observed(expected[1], at: 22)
        #expect(recorder.allVisible(phase: "measured"))
        for _ in 0..<65 { recorder.error(String(repeating: "x", count: 1024)) }
        let (rows, counts, errors) = recorder.snapshot()
        #expect(rows.count == 2 && rows[0].firstExactReadNS == 20 && rows[1].firstExactReadNS == 22)
        #expect(rows[0].readerStoreID == "original-watcher" && rows[0].observedID == expected[0].id)
        #expect(counts.duplicateCallbacks == 1 && counts.diagnosticOverflow == 1)
        #expect(errors.count == 64 && errors.allSatisfy { $0.count == 512 })
    }

    @Test func changedValueOrMalformedObservationCannotPassAfterValidCoverage() {
        let expected = SyncVisibilityExpected(runID: "run", stream: "hot", phase: "measured", writer: 0, sequence: 0, bytes: 32)
        let recorder = SyncVisibilityRecorder(expected: [expected])
        recorder.schedule(0, at: 10, deadline: 50)
        recorder.observed(expected, at: 20)
        #expect(recorder.allVisible(phase: "measured"))
        let changed = SyncVisibilityExpected(runID: "run", stream: "hot", phase: "measured", writer: 0, sequence: 0, bytes: 31)
        recorder.observed(changed, at: 21)
        #expect(!recorder.allVisible(phase: "measured"))
        let malformed = SyncVisibilityExpected(runID: "", stream: "hot", phase: "measured", writer: 0, sequence: 0, bytes: 32)
        recorder.observed(malformed, at: 22)
        let (rows, counts, _) = recorder.snapshot()
        #expect(rows[0].firstExactReadNS == 20 && rows[0].valueMatch == false)
        #expect(counts.valueMismatch == 1 && counts.malformedObservation == 1)
    }
}
