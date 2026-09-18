import Foundation
import Testing
@testable import LatticeServerKit

@Suite("Push harness stage diagnostics")
struct PushHarnessStageDiagnosticsTests {
    @Test func defaultRecorderStillAdmitsOnlyTwoConnections() throws {
        let recorder = ACKPathRecorder(testRunID: UUID())
        #expect(recorder.registerConnection(id: UUID(), role: .peer) != nil)
        #expect(recorder.registerConnection(id: UUID(), role: .uploader) != nil)
        #expect(recorder.registerConnection(id: UUID(), role: .peer) == nil)
        let snapshot = try #require(recorder.closeSnapshot(partial: false))
        #expect(snapshot.connectionLimit == 2)
        #expect(snapshot.rejectedConnections == 1)
        #expect(snapshot.latestStages.isEmpty)
        #expect(snapshot.latestSetupStages.isEmpty)
    }

    @Test func eightDistinctConnectionsFitWithinFixedCap() throws {
        let recorder = ACKPathRecorder(testRunID: UUID(), connectionLimit: 8, retainLatestStages: true)
        var ids: [UUID] = []
        for _ in 0..<8 {
            let id = UUID()
            ids.append(id)
            let connection = try #require(recorder.registerConnection(id: id, role: .peer))
            connection.record(.watchSubscribeRequested)
        }
        #expect(Set(ids).count == 8)
        #expect(recorder.registerConnection(id: UUID(), role: .peer) == nil)
        #expect(recorder.registerConnection(id: ids[0], role: .peer) == nil)
        let snapshot = try #require(recorder.closeSnapshot(partial: true))
        #expect(snapshot.connectionLimit == 8)
        #expect(snapshot.rejectedConnections == 2)
        #expect(snapshot.latestStages.count == 8)
        #expect(snapshot.latestSetupStages.count == 8)
    }

    @Test func traceOverflowRetainsLastNativeSetupFactWithoutGrowingHeadTrace() throws {
        let recorder = ACKPathRecorder(testRunID: UUID(), connectionLimit: 8, retainLatestStages: true)
        let connection = try #require(recorder.registerConnection(id: UUID(), role: .peer))
        for _ in 0..<ACKPathRecorder.recordLimit { connection.record(.binaryEntered) }
        #expect(connection.record(.watchOpenBegin) == 0)
        #expect(connection.record(.pushClientFirstBinaryProcessed) == 0)
        let snapshot = try #require(recorder.closeSnapshot(partial: true))
        #expect(snapshot.records.count == 256)
        #expect(snapshot.dropped == 2)
        #expect(snapshot.latestStages.count == 1)
        #expect(snapshot.latestStages.first?.stage == .pushClientFirstBinaryProcessed)
        #expect(snapshot.latestSetupStages.first?.stage == .watchOpenBegin)
        #expect(snapshot.latestSetupStages.first?.sequence == 0)
        #expect(snapshot.latestSetupStages.first?.connection == connection.id)
        #expect(try JSONEncoder().encode(snapshot).count < ACKPathRecorder.outputByteLimit)
    }

    @Test func firstFailureFreezeRejectsLateStagesAndASecondSnapshot() throws {
        let recorder = ACKPathRecorder(testRunID: UUID(), connectionLimit: 8, retainLatestStages: true)
        let connection = try #require(recorder.registerConnection(id: UUID(), role: .peer))
        connection.record(.watchOpenBegin)
        let frozen = try #require(recorder.closeSnapshot(partial: true))
        #expect(connection.record(.watchOpenEnd, result: true) == 0)
        #expect(recorder.registerConnection(id: UUID(), role: .peer) == nil)
        #expect(recorder.closeSnapshot(partial: false) == nil)
        #expect(frozen.records.count == 1)
        #expect(frozen.latestSetupStages.first?.stage == .watchOpenBegin)
        #expect(frozen.partial)
    }
}
