import Foundation

/// Opt-in failure DATA only; no source/currentness/permission or success fact.
/// This standalone classifier never receives request/owner/socket/file inputs.
enum RelayCheckedSetupFailureDiagnostic {
    enum Stage: String { case authorizationValidation, checkedOwnerOpen, normalOwnerOpen, modelGateCreation,
        ordinaryConnectionCreation, ordinaryStateInstall, recoveryOpen, catchUpStateCreation }
    enum Kind: String { case mountedConfiguration, mountedOpenRefused, exportCapacity, observationCapacity,
        exportRefused, exportOther, modelConfiguration, modelControl, modelStopped, modelEffectUnavailable,
        ordinaryControl, ordinaryCapacity, ordinaryStopped, ordinaryReceipt, ordinaryHeader, other }
    static var enabled: Bool { ProcessInfo.processInfo.environment["LATTICE_CHECKED_MOUNTED_SETUP_DIAGNOSTIC"] == "1" }
    static let prefix = "LATTICE_CHECKED_MOUNTED_SETUP_FAILURE "
    // Exact engine error literals. Nothing from a native message is emitted.
    static let reasons: [(String, String)] = [
        ("fingerprintCookie", "checked mounted server fingerprint/cookie differs; no repair"),
        ("schemaVersion", "checked mounted server positive version differs; no migration"),
        ("exportCapacity", "ordinary export capacity exhausted"),
        ("writerBusy", "checked mounted server native writer busy"),
        ("quiescentConfiguration", "checked mounted server quiescent existing configuration required"),
        ("actualCatalogOwner", "checked mounted server actual no-context catalog owner required"),
        ("closedRelationshipScope", "ordinary projection requires a closed relationship scope"),
        ("actualSchema", "ordinary projected schema:"),
        ("localProducer", "local producer retention/history/reset integration is not active"),
        ("physicalFile", "checked mounted server physical file changed"),
        ("nativeRead", "checked mounted server main READ unavailable"),
        ("callerTransaction", "checked mounted server refuses caller transaction or retired writer")
    ]
    static func row(stage: Stage, kind: Kind, nativeMessage: String? = nil) -> [String: Any] {
        var codes: [String] = []
        var size = 0
        if let nativeMessage {
            size = min(nativeMessage.utf8.count, 8193)
            if size <= 8192 && !nativeMessage.utf8.contains(0) {
                codes = reasons.filter { nativeMessage.contains($0.1) }.map { $0.0 }
            }
            if codes.isEmpty { codes = [size > 8192 ? "oversized" : "unclassified"] }
        }
        return ["format": "lattice-checked-mounted-setup-failure/1", "stage": stage.rawValue,
                "errorType": kind.rawValue, "nativeBytes": size, "nativeReasons": codes]
    }
    static func record(stage: Stage, kind: Kind, nativeMessage: String? = nil) {
        guard enabled else { return }
        let value = row(stage: stage, kind: kind, nativeMessage: nativeMessage)
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           data.count <= 2048, let text = String(data: data, encoding: .utf8) {
            print(prefix + text)
        }
    }
}
