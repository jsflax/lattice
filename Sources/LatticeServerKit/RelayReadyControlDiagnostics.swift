import Foundation
import Lattice
import NIOConcurrencyHelpers

/// Observations never drive admission, a timeout, cancellation or publication.
/// The entered call includes Swift guards/UTF-8 conversion: only a returned
/// native snapshot can establish which inner native stages actually ran.
enum RelayReadyTraceStage: Int, CaseIterable, Sendable {
    case entered, inputReserved, admissionRequested, readyCallEntered, readyCallReturned, readyCallThrew
    case completionEntered, sendQueued, socketLoopEntered, handedOff, sendSettled, admissionFailed, refused
}
enum RelayReadyTraceRefusal: String, Sendable {
    case none, ingressRevoked, completionLifetime, socketUnavailable, socketClosed, swiftLifetime, nativeResult
}
struct RelayReadyTraceRecord: Sendable {
    let turn: UInt64
    let connectionID: UUID
    let inputBytes: Int
    var requestID: UUID?
    var visited: UInt16 = 0
    var timestamps = Array(repeating: UInt64(0), count: RelayReadyTraceStage.allCases.count)
    var refusal = RelayReadyTraceRefusal.none
    var sendSucceeded: Bool?
    var native: RecoveryRelayNativeReadyDiagnostics?

    mutating func mark(_ stage: RelayReadyTraceStage) {
        let bit = UInt16(1) << stage.rawValue
        guard visited & bit == 0 else { return } // Preserve each first observation.
        timestamps[stage.rawValue] = DispatchTime.now().uptimeNanoseconds
        visited |= bit
    }
    func snapshotJSON() -> [String: Any] {
        let stages = RelayReadyTraceStage.allCases.map { stage -> [String: Any] in
            let observed = visited & (UInt16(1) << stage.rawValue) != 0
            return ["stage": String(describing: stage), "observed": observed,
                    "uptimeNanoseconds": observed ? timestamps[stage.rawValue] as Any : NSNull()]
        }
        return ["turn": turn, "connectionID": connectionID.uuidString, "inputBytes": inputBytes,
                "requestID": requestID.map { $0.uuidString as Any } ?? NSNull(), "requestCorrelationKnown": requestID != nil,
                "stages": stages, "firstRefusal": refusal.rawValue, "sendSucceeded": sendSucceeded.map { $0 as Any } ?? NSNull(),
                "native": native.map { $0.snapshotJSON() as Any } ?? NSNull()]
    }
}
/// One finite recorder per opted-in exact test mount. Retains only copied
/// scalar records and UUIDs, never input/response bytes, sockets or owners.
final class RelayReadyControlRecorder: @unchecked Sendable {
    static let capacity = 64
    private struct State { var records: [RelayReadyTraceRecord] = []; var omitted: UInt64 = 0 }
    private let state = NIOLockedValueBox(State())
    func begin(connectionID: UUID, inputBytes: Int) -> RelayReadyControlTrace? {
        let turn: UInt64? = state.withLockedValue { value in
            guard value.records.count < Self.capacity else {
                if value.omitted < UInt64.max { value.omitted += 1 }
                return nil
            }
            let turn = UInt64(value.records.count + 1)
            var record = RelayReadyTraceRecord(turn: turn, connectionID: connectionID, inputBytes: inputBytes)
            record.mark(.entered); value.records.append(record); return turn
        }
        guard let turn else { return nil }
        return .init(recorder: self, turn: turn)
    }
    fileprivate func update(_ turn: UInt64, _ body: (inout RelayReadyTraceRecord) -> Void) {
        state.withLockedValue { value in
            guard turn > 0, turn <= UInt64(value.records.count) else { return }
            body(&value.records[Int(turn - 1)])
        }
    }
    func snapshot() -> (records: [RelayReadyTraceRecord], omitted: UInt64) {
        state.withLockedValue { ($0.records, $0.omitted) }
    }
    func snapshotJSON() -> [String: Any] {
        let copy = snapshot() // Format after releasing the recorder lock.
        return ["capacity": Self.capacity, "omitted": copy.omitted,
                "records": copy.records.map { $0.snapshotJSON() }]
    }
}
/// Follows the existing operation/completion closures; holds only the bounded
/// recorder and a local turn. It introduces no source/socket/native custody.
final class RelayReadyControlTrace: Sendable {
    private let recorder: RelayReadyControlRecorder
    private let turn: UInt64
    fileprivate init(recorder: RelayReadyControlRecorder, turn: UInt64) { self.recorder = recorder; self.turn = turn }
    func record(_ stage: RelayReadyTraceStage) { recorder.update(turn) { $0.mark(stage) } }
    func refuse(_ reason: RelayReadyTraceRefusal) {
        recorder.update(turn) { if $0.refusal == .none { $0.refusal = reason }; $0.mark(.refused) }
    }
    func nativeReturned(_ native: RecoveryRelayNativeReadyDiagnostics) {
        let id = UUID(uuidString: native.requestID)
        recorder.update(turn) { if $0.native == nil { $0.requestID = id; $0.native = native } }
    }
    func sendSettled(succeeded: Bool) {
        recorder.update(turn) { if $0.sendSucceeded == nil { $0.sendSucceeded = succeeded }; $0.mark(.sendSettled) }
    }
}
