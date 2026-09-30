import Foundation
import LatticeSwiftCppBridge
import CxxStdlib

/// Copied fixed scalar facts only. The reviewed C++ value contains fixed arrays
/// and scalars, with no owner, callback, pointer, charge or publication token.
/// Its ordinary READY result is transferred separately and remains unchanged.
package struct RecoveryRelayNativeReadyDiagnostics: @unchecked Sendable {
    private let value: lattice.relay_ready_diagnostics
    package init(_ value: lattice.relay_ready_diagnostics) { self.value = value }
    package var requestID: String { String(value.requestID()) }
    package var operation: Int32 { value.operation }
    package static var scalarStorageBytes: Int { MemoryLayout<lattice.relay_ready_diagnostics>.size }

    /// Formatting is explicit and used only by an opted-in fixture snapshot.
    /// Shared cost slots do not prove either named stage actually executed.
    package func snapshotJSON() -> [String: Any] {
        let names = ["preparation", "read", "authenticatedControl", "resume"]
        let pointNames = [
            ["entered", "prepared", "captured", "assembled", "publishRequested", "publishBody", "publicationSettled", "auditBegin", "auditEnd", "finished"],
            ["entered", "ownedRequested", "bodyBegin", "bodyEnd", "settled", "finished"],
            ["entered", "controlParsed", "deadlineReserved", "expirationReturned", "prepareReturned", "resumeReturned", "leaseCopied", "finished"],
            ["entered", "ownedRequested", "bodyEntered", "identityChecked", "expiryChecked", "settled", "finished"]
        ]
        var stages: [[String: Any]] = []
        for family in 0..<4 {
            var points: [[String: Any]] = []
            for point in pointNames[family].indices {
                let visits = value.stageVisits(family: UInt32(family), point: UInt32(point))
                points.append(["point": pointNames[family][point], "visits": visits,
                    "firstMicroseconds": visits == 0 ? NSNull() : value.stageFirstMicroseconds(family: UInt32(family), point: UInt32(point)) as Any,
                    "lastMicroseconds": visits == 0 ? NSNull() : value.stageLastMicroseconds(family: UInt32(family), point: UInt32(point)) as Any])
            }
            stages.append(["family": names[family], "clock": "ownSteadyClockOrigin", "points": points])
        }
        let costNames = ["retentionAudit", "storeAudit", "request", "sequenceInit", "rawFetchHash", "frameDecode",
            "canonicalEncode", "sequenceAdvance", "receiptEvidence", "receiptBatch", "fusedFrameValidation"]
        var costs: [[String: Any]] = []
        for family in 0..<2 {
            costs.append(["slot": names[family], "interpretation": "sharedWholeCallNotStageApplicability",
                "phaseNames": costNames,
                "calls": (0..<11).map { value.costCalls(family: UInt32(family), phase: UInt32($0)) },
                "inclusiveMicroseconds": (0..<11).map { value.costMicroseconds(family: UInt32(family), phase: UInt32($0)) },
                "counterNames": ["receiptBatches", "receiptIDs", "hashInputBytes", "hashStagedBytes", "hashDirectBlocks"],
                "counters": (0..<5).map { value.costCounter(family: UInt32(family), index: UInt32($0)) }])
        }
        let settlements = ["expiration", "preparation", "publication", "resume", "read"].enumerated().map { index, name -> [String: Any] in
            let slot = UInt32(index)
            return ["name": name, "state": value.settlementState(slot), "errorBits": value.settlementErrors(slot),
                "refusalCode": value.settlementRefusal(slot),
                "unexpectedCommitObserved": value.settlementUnexpectedCommitObserved(slot),
                "unexpectedCommit": value.settlementUnexpectedCommitObserved(slot) ? value.settlementUnexpectedCommit(slot) as Any : NSNull()]
        }
        return ["schema": "ready-native-observation-v1", "operationCode": value.operation, "bridgeStatus": value.bridge_status,
            "requestID": requestID, "stages": stages, "settlements": settlements, "sharedInclusiveCosts": costs,
            "clockDomains": ["authenticated": "steadyClockTimeSinceEpochMillisecondsNotUnix",
                             "retention": "retentionSessionRelativeSteadyMilliseconds"],
            "authenticatedClockMilliseconds": value.authenticated_clock_ms, "authenticatedDeadlineMilliseconds": value.authenticated_deadline_ms,
            "requestedDurationMilliseconds": value.duration_ms,
            "resumeExpirationPresent": value.resume_expiration_present, "resumeExpirationMilliseconds": value.resume_expiration_ms,
            "resumeExpiryClockObserved": value.resume_expiry_clock_observed, "resumeExpiryClockMilliseconds": value.resume_expiry_clock_ms,
            "resumeNewDeadlineMilliseconds": value.resume_new_deadline_ms,
            "readDeadlineMilliseconds": value.read_deadline_ms, "readClockBeforeMilliseconds": value.read_clock_before_ms,
            "readClockAfterMilliseconds": value.read_clock_after_ms, "readClockSettledMilliseconds": value.read_clock_settled_ms,
            "prepareAuditedFrames": value.prepare_audited_frames, "readIndex": value.read_index,
            "readFullAudits": value.read_full_audits, "readAuditedFrames": value.read_audited_frames, "readAuditedBytes": value.read_audited_bytes,
            "readPositiveReceiptLookups": value.read_positive_receipt_lookups, "readAddressedFrames": value.read_addressed_frames,
            "readAddressedBytes": value.read_addressed_bytes, "captureError": value.capture_error,
            "requiresFullRequest": value.requires_full_request, "leaseAvailable": value.lease_available,
            "resumeTransferAvailable": value.resume_transfer_available, "resumeLeaseAvailable": value.resume_lease_available]
    }
}
