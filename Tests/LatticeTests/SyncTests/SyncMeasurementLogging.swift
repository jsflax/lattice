import Foundation
@testable import Lattice

/// Explicit setup for the selected visibility fixture only. This does not
/// alter BaseTest or production defaults. The public nil setter selects stderr;
/// there is no public sink getter, so the receipt does not claim sink readback.
enum SyncMeasurementLogging {
    static let policy = "lattice.visibility.logging/1;native=off;native-sink=stderr;observer-worker=off;ack-path=off;sql-dump=absent;swift-log-env=absent"

    static func installIfRequested() throws -> [String: String]? {
        let env = ProcessInfo.processInfo.environment
        // Ordinary suite invocations retain their original process logger.
        guard let requested = env["LATTICE_SYNC_VISIBILITY_LOGGING_POLICY"] else { return nil }
        guard requested == policy else { throw SyncVisibilityFailure.invalid("unknown measurement logging policy") }
        for key in ["LATTICE_DUMP_SQL", "LOG_LEVEL"] {
            guard env[key] == nil else { throw SyncVisibilityFailure.invalid("measurement requires absent \(key)") }
        }
        for key in ["LATTICE_ACK_PATH_DIAGNOSTICS", "LATTICE_OBSERVER_WORKER_DIAGNOSTICS"] {
            guard env[key] == nil || env[key] == "0" else {
                throw SyncVisibilityFailure.invalid("measurement requires disabled \(key)")
            }
        }
        Lattice.setLogLevel(.off)
        Lattice.setLogFile(nil)
        let observed = lattice_get_log_level().rawValue
        guard observed == 0 else { throw SyncVisibilityFailure.invalid("native logging off setter did not take effect") }
        return ["LOGGING": policy,
            "nativeLoggingLevelAtStart": String(observed),
            "nativeLoggingSink": "stderr; nil FILE setter returned; no sink getter",
            "nativeLoggingVerification": "level readback at start/end; not continuous monitoring",
            "diagnosticControls": "observer-worker=0;ack-path=0;sql-dump=absent",
            "swiftLogging": "LOG_LEVEL absent; pinned library defaults retained"]
    }

    static func finish(metadata: inout [String: String]) throws {
        let observed = lattice_get_log_level().rawValue
        metadata["nativeLoggingLevelAtEnd"] = String(observed)
        guard observed == 0 else { throw SyncVisibilityFailure.invalid("native logging level changed during visibility fixture") }
    }
}
