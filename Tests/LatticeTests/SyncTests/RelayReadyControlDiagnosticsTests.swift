import Foundation
import Testing
import Lattice
@testable import LatticeServerKit

@Suite("Bounded passive READY control observations")
struct RelayReadyControlDiagnosticsTests {
    @Test func capacityPreservesFirstRecordsAndReportsEveryOmission() throws {
        let recorder = RelayReadyControlRecorder(), connection = UUID()
        let first = try #require(recorder.begin(connectionID: connection, inputBytes: 7))
        first.record(.inputReserved)
        let initial = try #require(recorder.snapshot().records.first)
        for index in 1..<64 { #expect(recorder.begin(connectionID: connection, inputBytes: index) != nil) }
        for _ in 0..<3 { #expect(recorder.begin(connectionID: UUID(), inputBytes: 999) == nil) }
        let full = recorder.snapshot()
        #expect(full.records.count == 64); #expect(full.omitted == 3)
        #expect(full.records.map(\.turn) == Array(UInt64(1)...UInt64(64)))
        #expect(full.records[0].connectionID == connection); #expect(full.records[0].inputBytes == 7)
        #expect(full.records[0].timestamps == initial.timestamps)
        first.record(.completionEntered) // Existing custody remains observable after admission is full.
        #expect(recorder.snapshot().records[0].visited & (UInt16(1) << RelayReadyTraceStage.completionEntered.rawValue) != 0)
        #expect(recorder.snapshot().records.count == 64)
    }

    @Test func firstStageRefusalAndSettlementSurviveDuplicateReports() throws {
        let recorder = RelayReadyControlRecorder()
        let trace = try #require(recorder.begin(connectionID: UUID(), inputBytes: 5))
        trace.record(.socketLoopEntered); trace.refuse(.socketClosed); trace.sendSettled(succeeded: false)
        let first = try #require(recorder.snapshot().records.first)
        trace.record(.socketLoopEntered); trace.refuse(.nativeResult); trace.sendSettled(succeeded: true)
        let repeated = try #require(recorder.snapshot().records.first)
        #expect(repeated.timestamps == first.timestamps)
        #expect(repeated.refusal == .socketClosed); #expect(repeated.sendSucceeded == false)
        #expect(repeated.native == nil); #expect(repeated.requestID == nil)
    }

    @Test func connectionAndTurnFactsCannotFillUnobservedNativeStages() throws {
        let recorder = RelayReadyControlRecorder(), a = UUID(), b = UUID()
        let first = try #require(recorder.begin(connectionID: a, inputBytes: 1))
        let second = try #require(recorder.begin(connectionID: b, inputBytes: 2))
        first.record(.readyCallEntered); second.refuse(.ingressRevoked)
        let records = recorder.snapshot().records
        #expect(records[0].connectionID == a); #expect(records[1].connectionID == b)
        #expect(records[0].refusal == .none); #expect(records[1].refusal == .ingressRevoked)
        #expect(records.allSatisfy { $0.native == nil && $0.requestID == nil && $0.sendSucceeded == nil })
        #expect(records[0].visited & (UInt16(1) << RelayReadyTraceStage.readyCallReturned.rawValue) == 0)
        let json = records[0].snapshotJSON()
        #expect(json["requestID"] is NSNull); #expect(json["native"] is NSNull); #expect(json["sendSucceeded"] is NSNull)
        #expect(JSONSerialization.isValidJSONObject(recorder.snapshotJSON()))
    }

    @Test func logicalScalarStorageAndStageCountStayWithinTheRecordedBound() {
        #expect(RelayReadyTraceStage.allCases.count <= 16)
        // Includes the inline native value/optional and record scalars plus the
        // separate fixed timestamp elements. Allocator/container overhead is
        // deliberately not an RSS or total memory claim.
        let logicalBytes = MemoryLayout<RelayReadyTraceRecord>.stride
            + RelayReadyTraceStage.allCases.count * MemoryLayout<UInt64>.stride
        #expect(RecoveryRelayNativeReadyDiagnostics.scalarStorageBytes <= 2048)
        #expect(logicalBytes <= 2048)
        #expect(logicalBytes * RelayReadyControlRecorder.capacity <= 128 * 1024)
    }

    @Test func hookDefaultsDoNotInstallAnObserverOrAReadySendGate() throws {
        let ordinary = RelayIngressTestHooks(beforeAsyncSetup: {}, didBufferFrame: { _ in }, didFinishAsyncSetup: {})
        #expect(ordinary.beginRecoveryReadyTrace == nil); #expect(ordinary.parkRecoveryReadySend == nil)
        let recorder = RelayReadyControlRecorder(), connection = UUID()
        let optedIn = RelayIngressTestHooks(beforeAsyncSetup: {}, didBufferFrame: { _ in }, didFinishAsyncSetup: {},
            beginRecoveryReadyTrace: { recorder.begin(connectionID: $0, inputBytes: $1) })
        #expect(recorder.snapshot().records.isEmpty)
        let begin = try #require(optedIn.beginRecoveryReadyTrace)
        #expect(begin(connection, 17) != nil); #expect(optedIn.parkRecoveryReadySend == nil)
        #expect(recorder.snapshot().records.first?.connectionID == connection)
    }
}
