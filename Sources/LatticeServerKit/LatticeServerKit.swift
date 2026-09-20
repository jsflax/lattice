import Foundation
import Vapor
import Lattice
import NIOConcurrencyHelpers

// MARK: - Internal, opt-in warm ACK path diagnostics

/// Only the selected forensic test installs a probe, keyed by its exact mount
/// URL. Production mounts perform one lookup; nil event paths do no probe work.
enum ACKPathDiagnostics {
    private static let mounts = NIOLockedValueBox<[URL: ACKPathRecorder]>([:])

    static func install(_ recorder: ACKPathRecorder, for storageURL: URL) {
        mounts.withLockedValue { $0[storageURL] = recorder }
    }

    static func recorder(for storageURL: URL) -> ACKPathRecorder? {
        mounts.withLockedValue { $0[storageURL] }
    }

    static func remove(_ recorder: ACKPathRecorder, for storageURL: URL) {
        mounts.withLockedValue {
            if $0[storageURL] === recorder { $0.removeValue(forKey: storageURL) }
        }
    }
}

/// Test-only, exact-mount hooks. The setup gate never blocks an event loop;
/// the ingress notification carries only a byte count, never the frame.
final class RelayIngressTestHooks: Sendable {
    let beforeAsyncSetup: @Sendable () async -> Void
    let didBufferFrame: @Sendable (Int) -> Void
    let didFinishAsyncSetup: @Sendable () -> Void
    let didCloseConnection: @Sendable () -> Void
    let sendCatchUp: (@Sendable (WebSocket, Data, EventLoopPromise<Void>) -> Void)?

    init(beforeAsyncSetup: @escaping @Sendable () async -> Void,
         didBufferFrame: @escaping @Sendable (Int) -> Void,
         didFinishAsyncSetup: @escaping @Sendable () -> Void,
         didCloseConnection: @escaping @Sendable () -> Void = {},
         sendCatchUp: (@Sendable (WebSocket, Data, EventLoopPromise<Void>) -> Void)? = nil) {
        self.beforeAsyncSetup = beforeAsyncSetup
        self.didBufferFrame = didBufferFrame
        self.didFinishAsyncSetup = didFinishAsyncSetup
        self.didCloseConnection = didCloseConnection
        self.sendCatchUp = sendCatchUp
    }
}

enum RelayIngressTesting {
    private static let mounts = NIOLockedValueBox<[URL: RelayIngressTestHooks]>([:])

    static func install(_ hooks: RelayIngressTestHooks, for storageURL: URL) {
        mounts.withLockedValue { $0[storageURL] = hooks }
    }

    static func hooks(for storageURL: URL) -> RelayIngressTestHooks? {
        mounts.withLockedValue { $0[storageURL] }
    }

    static func remove(_ hooks: RelayIngressTestHooks, for storageURL: URL) {
        mounts.withLockedValue {
            if $0[storageURL] === hooks { $0.removeValue(forKey: storageURL) }
        }
    }
}

enum ACKPathRole: Int, Codable, Sendable { case peer, uploader }

/// Integer stage codes keep even a full 256-record snapshot below the output
/// bound in ordinary use. The encoded byte bound is checked independently.
enum ACKPathStage: Int, Codable, Sendable {
    case connectBegin, connectEnd, connectError, clientHandlersAttached
    case routeEntered, handlersScheduled, handlersEntered, handlersComplete
    case extractorBegin, extractorEnd, extractorError, registryAddBegin, registryAddEnd
    case storeOpenBegin, storeOpenEnd, storeOpenFailure
    case goLiveScheduled, goLiveEntered, goLiveComplete, goLiveAbandoned
    case binaryEntered, ingressBuffered, ingressYielded, ingressDiscarded, ingressRefused
    case consumerCreated, consumerStarted, frameDequeued, dequeueRevoked
    case processEntered, processRevoked, frameParsed, frameMalformed, policyRefused
    case applyRequested, applyBodyEntered, applyBodyReturned, applyGateReturned
    case afterApplyBegin, afterApplyEnd
    case ackDecision, ackEmpty, ackEncodeBegin, ackEncodeEnd, ackEncodeFailure
    case ackSendBegin, ackSendReturn
    case clientBinaryEntered, clientDecodeError, clientDecodedAck, clientDecodedNack
    case clientDecodedAudit, clientDecodedRejected, clientDecodedOther, clientWarmAckMatch, clientAckStored
    case warmSelected, warmEncodeBegin, warmEncodeEnd, warmEncodeError
    case warmSendBegin, warmSendReturn, warmSendError, pollBegin, pollEnd
    case connectionClosed, closedDuringSetup, handshakeRefused, extractorRefused, unsafeNameRefused
    case applyFailureClose
    // Append-only: retain existing diagnostic stage codes.
    case setupTaskStarted, watchSubscribeRequested, watchSubscribeEntered, watchSubscribeReturned
    case watchOpenScheduled, watchOpenTaskStarted, watchOpenBegin, watchOpenEnd
    case watchInstallRequested, watchInstallEntered, watchObserverRegistered, watchSubscribePublished
    case watchActivated, catchUpTaskStarted, catchUpReadBegin, catchUpReadEnd
    case catchUpSendBegin, catchUpSendReturn, pushPumpScheduled, pushPumpTaskStarted
    case pushPageBegin, pushPageEnd, pushSendBegin, pushSendReturn, pushClientFirstBinaryProcessed
    case applyAdmissionRequested, applyAdmissionRejected
    // Append-only request/page intervals. Body return is not lane release.
    case applyAdmissionReserved, applyInputCopyBegin, applyInputCopyEnd
    case applyInputPrepared, applyPoolSubmit, applyWorkerEntered, frameParseBegin
    case catchUpPageRequested, catchUpPageWorkerEntered, catchUpPageMaterializeBegin
    case catchUpPageMaterializeEnd, catchUpPageBindingEnd, catchUpPageEncodingEnd, catchUpPageBodyReturned
    case applyWorkerBodyReturned

    var isSetupStage: Bool {
        switch self {
        case .routeEntered, .handlersScheduled, .handlersEntered, .handlersComplete,
             .extractorBegin, .extractorEnd, .extractorError, .registryAddBegin, .registryAddEnd,
             .storeOpenBegin, .storeOpenEnd, .storeOpenFailure,
             .goLiveScheduled, .goLiveEntered, .goLiveComplete, .goLiveAbandoned,
             .closedDuringSetup, .handshakeRefused, .extractorRefused, .unsafeNameRefused,
             .setupTaskStarted, .watchSubscribeRequested, .watchSubscribeEntered,
             .watchSubscribeReturned, .watchOpenScheduled, .watchOpenTaskStarted,
             .watchOpenBegin, .watchOpenEnd, .watchInstallRequested, .watchInstallEntered,
             .watchObserverRegistered, .watchSubscribePublished, .watchActivated,
             .catchUpTaskStarted, .catchUpReadBegin, .catchUpReadEnd,
             .catchUpSendBegin, .catchUpSendReturn,
             .catchUpPageRequested, .catchUpPageWorkerEntered, .catchUpPageMaterializeBegin,
             .catchUpPageMaterializeEnd, .catchUpPageBindingEnd, .catchUpPageEncodingEnd,
             .catchUpPageBodyReturned:
            return true
        default: return false
        }
    }
}

struct ACKPathConnection: Sendable {
    let recorder: ACKPathRecorder
    let id: UUID
    let role: ACKPathRole

    @discardableResult
    func record(_ stage: ACKPathStage, span: UInt64 = 0, bytes: Int = 0,
                count: Int = 0, applied: Int = 0, missing: Int = 0,
                attempts: Int = 0, result: Bool? = nil, matching ids: [UUID]? = nil) -> UInt64 {
        recorder.record(connection: self, stage: stage, span: span, bytes: bytes,
                        count: count, applied: applied, missing: missing,
                        attempts: attempts, result: result, matching: ids)
    }

    func selectWarmID(_ id: UUID, entryCount: Int) {
        recorder.selectWarmID(id, entryCount: entryCount, connection: self)
    }

    func containsWarmID(_ ids: [UUID]) -> Bool? { recorder.containsWarmID(ids) }
}

/// Immutable request identity, never a connection's mutable latest-frame slot.
/// Nil at ordinary mounts; retained only by the already bounded admission job.
/// A zero span means recorder admission failed, so it cannot establish matching.
struct ACKPathAdmission: Sendable {
    let connection: ACKPathConnection
    let span: UInt64
    func record(_ stage: ACKPathStage, bytes: Int = 0, result: Bool? = nil) {
        connection.record(stage, span: span, bytes: bytes, result: result)
    }
}

/// No transport, encoding, formatting, filesystem access, await or task runs
/// under this lock. The only variable-sized input scan (UUID membership) runs
/// outside it after reading the one-time warm selection under the same lock.
/// This probe adds real overhead and does not establish transport causality.
final class ACKPathRecorder: @unchecked Sendable {
    static let recordLimit = 256
    static let outputByteLimit = 64 * 1024
    let testRunID: UUID
    private let processID = ProcessInfo.processInfo.processIdentifier
    private let lock = NSLock()
    private var connections: [UUID: ACKPathRole] = [:]
    private let connectionLimit: Int
    private let retainLatestStages: Bool
    private var rejectedConnections = 0
    private var latestStages: [UUID: Record] = [:]
    private var latestSetupStages: [UUID: Record] = [:]
    private var warmID: UUID?
    private var warmEntryCount = 0
    private var selectionRejected = 0
    private var records: [Record] = []
    private var dropped = 0
    private var closed = false

    struct Record: Codable, Sendable {
        let test: UUID
        let connection: UUID
        let role: ACKPathRole
        let stage: ACKPathStage
        let sequence: UInt64
        let span: UInt64
        let pid: Int32
        let uptime: UInt64
        let bytes: Int
        let count: Int
        let applied: Int
        let missing: Int
        let attempts: Int
        let result: Bool?
        /// nil = unavailable (including connection-only, pre-parse events).
        let warmMatch: Bool?

        enum CodingKeys: String, CodingKey {
            case test = "t", connection = "c", role = "r", stage = "s"
            case sequence = "q", span = "p", pid = "pid", uptime = "ns"
            case bytes = "b", count = "n", applied = "a", missing = "m"
            case attempts = "tries", result = "ok", warmMatch = "warm"
        }
    }

    struct Snapshot: Codable, Sendable {
        let schema: String
        let test: UUID
        let pid: Int32
        let cutoffUptime: UInt64
        let partial: Bool
        let warmID: UUID?
        let warmEntryCount: Int
        let selectionRejected: Int
        let dropped: Int
        var outputOmittedRecords: Int
        var records: [Record]
        let connectionLimit: Int
        let rejectedConnections: Int
        let latestStages: [Record]
        let latestSetupStages: [Record]
    }

    init(testRunID: UUID, connectionLimit: Int = 2, retainLatestStages: Bool = false) {
        precondition((1...8).contains(connectionLimit))
        self.connectionLimit = connectionLimit
        self.retainLatestStages = retainLatestStages
        self.testRunID = testRunID
        records.reserveCapacity(Self.recordLimit)
        connections.reserveCapacity(connectionLimit)
        if retainLatestStages {
            latestStages.reserveCapacity(connectionLimit)
            latestSetupStages.reserveCapacity(connectionLimit)
        }
    }

    func registerConnection(id: UUID, role: ACKPathRole) -> ACKPathConnection? {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return nil }
        guard connections.count < connectionLimit, connections[id] == nil else {
            if rejectedConnections < Int.max { rejectedConnections += 1 }
            return nil
        }
        connections[id] = role
        return ACKPathConnection(recorder: self, id: id, role: role)
    }

    func connection(id: UUID) -> ACKPathConnection? {
        lock.lock(); defer { lock.unlock() }
        guard !closed, let role = connections[id] else { return nil }
        return ACKPathConnection(recorder: self, id: id, role: role)
    }

    fileprivate func containsWarmID(_ ids: [UUID]) -> Bool? {
        lock.lock()
        let selected = closed ? nil : warmID
        lock.unlock()
        return selected.map { ids.contains($0) }
    }

    fileprivate func selectWarmID(_ id: UUID, entryCount: Int, connection: ACKPathConnection) {
        let timestamp = DispatchTime.now().uptimeNanoseconds
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        guard warmID == nil else {
            if selectionRejected < Int.max { selectionRejected += 1 }
            return
        }
        warmID = id
        warmEntryCount = entryCount
        _ = append(connection: connection, stage: .warmSelected, span: 0, timestamp: timestamp,
                   bytes: 0, count: entryCount, applied: 0, missing: 0, attempts: 0,
                   result: nil, warmMatch: nil)
    }

    fileprivate func record(connection: ACKPathConnection, stage: ACKPathStage, span: UInt64,
                            bytes: Int, count: Int, applied: Int, missing: Int, attempts: Int,
                            result: Bool?, matching ids: [UUID]?) -> UInt64 {
        // Event timestamps precede recorder admission. Sequence is append
        // order, not a clock ordering claim across concurrent callbacks.
        let timestamp = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let selected = warmID
        let accepting = !closed
        lock.unlock()
        guard accepting else { return 0 }
        let warmMatch: Bool?
        if let selected, let ids { warmMatch = ids.contains(selected) }
        else { warmMatch = nil }
        lock.lock(); defer { lock.unlock() }
        return append(connection: connection, stage: stage, span: span, timestamp: timestamp,
                      bytes: bytes, count: count, applied: applied, missing: missing,
                      attempts: attempts, result: result, warmMatch: warmMatch)
    }

    /// Caller owns lock; storage was reserved once and can never exceed 256.
    private func append(connection: ACKPathConnection, stage: ACKPathStage, span: UInt64,
                        timestamp: UInt64, bytes: Int, count: Int, applied: Int, missing: Int,
                        attempts: Int, result: Bool?, warmMatch: Bool?) -> UInt64 {
        guard !closed else { return 0 }
        let admitted = records.count < Self.recordLimit
        let sequence = admitted ? UInt64(records.count + 1) : 0
        let record = Record(test: testRunID, connection: connection.id, role: connection.role,
                            stage: stage, sequence: sequence, span: span, pid: processID,
                            uptime: timestamp, bytes: bytes, count: count, applied: applied,
                            missing: missing, attempts: attempts, result: result, warmMatch: warmMatch)
        // Optional fixed-size latest facts survive head-trace overflow. Timestamp
        // comparison avoids an earlier event overwriting a later event at lock admission.
        if retainLatestStages, connections[connection.id] != nil {
            if latestStages[connection.id].map({ $0.uptime <= timestamp }) ?? true {
                latestStages[connection.id] = record
            }
            if stage.isSetupStage,
               latestSetupStages[connection.id].map({ $0.uptime <= timestamp }) ?? true {
                latestSetupStages[connection.id] = record
            }
        }
        guard admitted else {
            if dropped < Int.max { dropped += 1 }
            return 0
        }
        records.append(record)
        return sequence
    }

    /// Closure and append admission share one lock. Exactly one caller gets
    /// a snapshot; callbacks retained after deregistration cannot extend it.
    func closeSnapshot(partial: Bool) -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return nil }
        closed = true
        return Snapshot(schema: "lattice.warm-ack-path/1", test: testRunID, pid: processID,
                        cutoffUptime: DispatchTime.now().uptimeNanoseconds, partial: partial,
                        warmID: warmID, warmEntryCount: warmEntryCount,
                        selectionRejected: selectionRejected, dropped: dropped,
                        outputOmittedRecords: 0, records: records,
                        connectionLimit: connectionLimit, rejectedConnections: rejectedConnections,
                        latestStages: latestStages.values.sorted { $0.uptime < $1.uptime },
                        latestSetupStages: latestSetupStages.values.sorted { $0.uptime < $1.uptime })
    }

    func emitSnapshot(partial: Bool) {
        guard let snapshot = closeSnapshot(partial: partial) else { return }
        Self.emitSnapshot(snapshot)
    }

    static func emitSnapshot(_ captured: Snapshot) {
        var snapshot = captured
        let prefix = "ACK_PATH_DIAGNOSTIC "
        let encoder = JSONEncoder()
        guard var data = try? encoder.encode(snapshot) else {
            print("ACK_PATH_DIAGNOSTIC unavailable encoding_failure test=\(snapshot.test)")
            return
        }
        if prefix.utf8.count + data.count + 1 > Self.outputByteLimit {
            // Never print an oversized trace. Explicit omission invalidates
            // absence conclusions; no second snapshot or completion wait.
            snapshot.outputOmittedRecords = snapshot.records.count
            snapshot.records = []
            guard let summary = try? encoder.encode(snapshot) else { return }
            data = summary
        }
        guard prefix.utf8.count + data.count + 1 <= Self.outputByteLimit else { return }
        print(prefix + String(decoding: data, as: UTF8.self))
    }
}

// MARK: - SyncChannel

/// One relay partition: connections sharing a channel id share a server
/// database and fan out frames to each other. The personal topology maps a
/// user to their own channel (`id == userId.uuidString`); group topologies
/// map many users onto one channel.
public struct SyncChannel: Sendable {
    /// Fan-out + storage key. Connections with equal ids relay to each other.
    public let id: String
    /// The authenticated user on THIS connection (revocation kicks target
    /// a specific user's sockets on a channel).
    public let userId: UUID
    /// On-disk database filename under the relay's storage directory.
    /// Defaults to `"<id>.sqlite"` — for the personal wrapper that yields
    /// the historical `<userId>.sqlite`; group mounts using ids like
    /// `"group-<uuid>"` get collision-free names for free.
    public let databaseFileName: String

    public init(id: String, userId: UUID, databaseFileName: String? = nil) {
        self.id = id
        self.userId = userId
        self.databaseFileName = databaseFileName ?? "\(id).sqlite"
    }
}

// MARK: - Write policy

/// Per-channel allowlist of audit operations, enforced server-side before a
/// frame is applied or fanned out. Mechanical frame validation, not relay
/// intelligence: the relay already decodes every frame to apply it.
///
/// A violating frame is answered with `ServerSentEvent.rejected(reason:)`
/// and dropped whole — nothing applied, nothing fanned out, entries left
/// unACKed.
///
/// **Fails CLOSED.** This inspector reads the frame with a different parser
/// (Foundation) than the applier (nlohmann in LatticeCore), so anything the
/// inspector cannot fully understand — an unparsable frame, a non-object
/// array element, a missing/odd `tableName` or `operation` — is treated as
/// a violation rather than waved through. An earlier fail-open version was
/// defeated by prefixing the entry array with a single `0`: the Swift cast
/// to `[[String: Any]]` yielded nil (no violation) while the C++ parser
/// skipped the junk element and applied every real DELETE behind it.
public struct SyncWritePolicy: Sendable {
    public enum Operation: String, Sendable, CaseIterable {
        case insert = "INSERT"
        case update = "UPDATE"
        case delete = "DELETE"
    }

    /// How to treat a table with no entry in `allowedOperations`.
    public enum UnlistedTablePolicy: Sendable {
        /// Unrestricted (back-compat default for single-tenant mounts).
        case allow
        /// Rejected. Correct for shared/multi-tenant channels: the schema
        /// is fixed and known, so anything else is forged.
        case deny
    }

    /// tableName → operations allowed on that table. Matched
    /// case-insensitively: SQLite identifiers are case-insensitive, so a
    /// `"memory"` entry reaches the same table as `"Memory"` and must not
    /// slip past an exact-match lookup.
    public var allowedOperations: [String: Set<Operation>]
    /// Optional cap on DELETE entries per frame across ALL tables — a
    /// mass-deletion brake that still admits legitimate single-row
    /// retractions on tables whose policy allows deletes.
    public var maxDeletesPerFrame: Int?
    /// Treatment of tables absent from `allowedOperations`.
    public var unlistedTables: UnlistedTablePolicy

    /// Lattice-internal tables a client may never write through the relay,
    /// whatever the policy says. `AuditLog` is the dangerous one: the relay
    /// serves it verbatim to catching-up peers (`eventsAfter`), so a forged
    /// INSERT into it launders arbitrary operations — including ones this
    /// policy forbids — into every member's next catch-up.
    static let internalTables: Set<String> = ["auditlog"]

    public init(
        allowedOperations: [String: Set<Operation>],
        maxDeletesPerFrame: Int? = nil,
        unlistedTables: UnlistedTablePolicy = .allow
    ) {
        self.allowedOperations = allowedOperations
        self.maxDeletesPerFrame = maxDeletesPerFrame
        self.unlistedTables = unlistedTables
    }

    /// Case-insensitive lookup over `allowedOperations`.
    private func allowed(forTable table: String) -> Set<Operation>? {
        let key = table.lowercased()
        if let exact = allowedOperations[table] { return exact }
        for (name, ops) in allowedOperations where name.lowercased() == key {
            return ops
        }
        return nil
    }

    /// First violation in the frame, or nil when the frame passes.
    func violation(inFrame data: Data) -> String? {
        violation(inFrame: RelayFrame(data))
    }

    /// Parse-once form: the relay inspects every frame anyway (to know which
    /// globalIds an upload asked it to store, so a shortfall can be nacked),
    /// so the policy reads that same parse instead of re-running its own.
    func violation(inFrame frame: RelayFrame) -> String? {
        guard let parsed = frame.json else {
            // The applier's parser is more permissive than Foundation's
            // (nesting depth, number forms). Anything we cannot read, we
            // cannot vet — refuse it.
            return "frame is not readable JSON"
        }
        guard let root = parsed as? [String: Any] else {
            return "frame is not a JSON object"
        }
        // Not an upload (ack/replayRequest/etc.): nothing to enforce.
        guard let rawEntries = root["auditLog"] else { return nil }
        guard let entries = rawEntries as? [Any] else {
            return "auditLog is not an array"
        }

        var deleteCount = 0
        for element in entries {
            guard let entry = element as? [String: Any] else {
                return "malformed audit entry (not an object)"
            }
            guard let table = entry["tableName"] as? String, !table.isEmpty else {
                return "audit entry is missing a tableName"
            }
            guard let opRaw = entry["operation"] as? String,
                  let op = Operation(rawValue: opRaw.uppercased()) else {
                return "audit entry has an unrecognized operation"
            }
            guard !Self.internalTables.contains(table.lowercased()) else {
                return "writes to the internal table \(table) are never permitted"
            }
            if op == .delete {
                deleteCount += 1
                if let cap = maxDeletesPerFrame, deleteCount > cap {
                    return "frame exceeds the \(cap)-delete limit for this channel"
                }
            }
            if let allowed = allowed(forTable: table) {
                guard allowed.contains(op) else {
                    return "operation \(opRaw) not permitted on \(table) for this channel"
                }
            } else if case .deny = unlistedTables {
                return "table \(table) is not part of this channel's schema"
            }
        }
        return nil
    }
}

// MARK: - Schema handshake

/// Declared-version gate at connect time. When configured, a client whose
/// declared schema version is missing (if required), unparsable, or outside
/// the mount's `mode` is answered with a human-readable text frame and a
/// policy-violation close — a visible, attributable error instead of a
/// silent apply-wedge when wire schemas drift (the W1.0 failure class).
///
/// The declaration is read from the `queryParameterName` query parameter
/// FIRST (browser WebSockets cannot set request headers, so `?schema=` is
/// the only channel a wasm client has — previously every consumer needed a
/// pre-upgrade middleware to lift it into the header), then from the
/// `headerName` header. Query-param admission is OPT-IN: legacy
/// `minimumVersion` mounts stay header-only on upgrade (their admission
/// surface must not silently widen); only mounts that set
/// `queryParameterName` — the exact-mode init does so by default, since its
/// purpose is browser clients — honor the query channel.
public struct SyncSchemaHandshake: Sendable {
    /// How the declared version is matched.
    public enum Mode: Sendable {
        /// Admit any client at or above the version (the historical
        /// semantics): old clients are refused, newer ones trusted.
        case minimum(Int)
        /// Admit ONLY the exact version: refuses below ("upgrade required")
        /// AND above ("server behind client") with distinct legible close
        /// reasons. Correct for wire schemas where the server cannot
        /// interpret frames minted by a newer client.
        case exact(Int)
    }

    public var headerName: String
    /// Query parameter consulted BEFORE the header. OPT-IN: `nil` (the
    /// legacy `minimumVersion` init's value) disables the query channel
    /// entirely — an upgraded header-only mount must not silently start
    /// admitting via `?schema=`. The exact-mode init defaults it to
    /// `"schema"` (its raison d'être is browser clients, which cannot set
    /// headers); a minimum-mode mount can opt in by setting it explicitly.
    public var queryParameterName: String?
    public var mode: Mode
    /// When false, clients that send no declaration at all are admitted
    /// (legacy tolerance); a declaration that is present but unparsable or
    /// out of range still closes.
    public var requireDeclaration: Bool

    /// Legacy accessor (pre-1.7 this struct was minimum-only). Reads the
    /// version out of either mode; setting forces `.minimum`.
    public var minimumVersion: Int {
        get {
            switch mode {
            case .minimum(let v), .exact(let v): return v
            }
        }
        set { mode = .minimum(newValue) }
    }

    /// Legacy alias for `requireDeclaration` (pre-1.7 name, when the header
    /// was the only declaration channel).
    public var requireHeader: Bool {
        get { requireDeclaration }
        set { requireDeclaration = newValue }
    }

    /// Minimum-version gate (source- AND behavior-compatible with pre-1.7:
    /// header-only — no query-param admission unless the mount opts in by
    /// setting `queryParameterName` afterwards).
    public init(headerName: String = "X-Lattice-Schema", minimumVersion: Int, requireHeader: Bool = true) {
        self.headerName = headerName
        self.queryParameterName = nil
        self.mode = .minimum(minimumVersion)
        self.requireDeclaration = requireHeader
    }

    /// Exact-version gate: refuses both older and newer clients.
    public init(exactVersion: Int, queryParameter: String? = "schema",
                headerName: String = "X-Lattice-Schema",
                requireDeclaration: Bool = true) {
        self.headerName = headerName
        self.queryParameterName = queryParameter
        self.mode = .exact(exactVersion)
        self.requireDeclaration = requireDeclaration
    }

    /// Reason to refuse this request, or nil to admit.
    func refusal(for req: Request) -> String? {
        // Query parameter first: it is the only declaration channel a
        // browser client has, and a client that sends both means the same
        // value anyway (skew between them is a client bug — the query wins
        // deterministically rather than silently).
        let declared: (raw: String, source: String)?
        if let name = queryParameterName, let value = req.query[String.self, at: name] {
            declared = (value, "?\(name)")
        } else if let value = req.headers.first(name: headerName) {
            declared = (value, "\(headerName) header")
        } else {
            declared = nil
        }
        let requirement: String
        switch mode {
        case .minimum(let v): requirement = ">= \(v)"
        case .exact(let v): requirement = "== \(v)"
        }
        guard let declared else {
            let channels = queryParameterName
                .map { "send ?\($0)= or the \(headerName) header" }
                ?? "send the \(headerName) header"
            return requireDeclaration
                ? "missing schema declaration (server requires schema \(requirement); \(channels))"
                : nil
        }
        guard let version = Int(declared.raw) else {
            return "unparsable schema declaration in \(declared.source): '\(declared.raw)'"
        }
        switch mode {
        case .minimum(let minimum):
            guard version >= minimum else {
                return "client schema \(version) below server minimum \(minimum) — upgrade required"
            }
        case .exact(let exact):
            if version < exact {
                return "client schema \(version) below server schema \(exact) — upgrade required"
            }
            if version > exact {
                return "client schema \(version) ahead of server schema \(exact) — server behind client, refusing to admit a newer schema"
            }
        }
        return nil
    }
}

// MARK: - Socket registry

/// One-way flag a connection consults before doing any work. Revocation
/// MUST NOT depend on the peer completing the WebSocket close handshake:
/// `close(code:)` only *sends* a close frame, and a hostile client that
/// never replies keeps `isClosed == false` (Vapor sets no server-side ping
/// timeout), so a "kicked" socket would otherwise keep applying frames to
/// the shared database and fanning them out to the members who remain.
final class RevocationFlag: @unchecked Sendable {
    private let lock = NIOLock()
    private var revoked = false
    var isRevoked: Bool { lock.withLock { revoked } }
    func revoke() { lock.withLock { revoked = true } }
}

@RelayControlActor final class SocketManager {
    nonisolated init() {}
    struct Entry {
        let socket: WebSocket
        let userId: UUID
        let revocation: RevocationFlag
    }

    private var channels: [String: [Entry]] = [:]

    func sockets(channelId: String) -> [WebSocket] {
        // Revoked entries are excluded from fan-out immediately, even while
        // their transport lingers.
        channels[channelId, default: []]
            .filter { !$0.revocation.isRevoked }
            .map(\.socket)
    }

    func connectionCount(channelId: String) -> Int {
        reap(channelId: channelId)
        return channels[channelId, default: []].count
    }

    /// Every live (channelId, userId) pair, for periodic re-authorization
    /// sweeps. Reaps dead transports first so the sweep never wastes an
    /// auth check on a socket that already went away.
    func activeConnections() -> [(channelId: String, userId: UUID)] {
        for channelId in channels.keys { reap(channelId: channelId) }
        return channels.flatMap { channelId, entries in
            entries.filter { !$0.revocation.isRevoked }
                .map { (channelId: channelId, userId: $0.userId) }
        }
    }

    func add(socket: WebSocket, channelId: String, userId: UUID, revocation: RevocationFlag) {
        reap(channelId: channelId)
        channels[channelId, default: []].append(
            Entry(socket: socket, userId: userId, revocation: revocation))
    }

    func remove(socket: WebSocket, channelId: String) {
        channels[channelId]?.removeAll { $0.socket === socket }
        if channels[channelId]?.isEmpty == true { channels[channelId] = nil }
    }

    private func reap(channelId: String) {
        channels[channelId]?.removeAll { $0.socket.isClosed }
        if channels[channelId]?.isEmpty == true { channels[channelId] = nil }
    }

    /// Revoke + close one user's connections on a channel (membership
    /// removal). The revocation flag is the authoritative part — the close
    /// frame and the ping-timeout are best-effort transport cleanup. Entries
    /// stay registered until their `onClose` fires so a lingering hostile
    /// socket remains visible to `connectionCount` and to later kicks.
    func disconnect(channelId: String, userId: UUID) {
        for entry in channels[channelId, default: []] where entry.userId == userId {
            entry.revocation.revoke()
            forceClose(entry.socket)
        }
    }

    /// Revoke + close every connection on a channel (channel deletion; also
    /// the post-purge nudge that forces reconnect-and-catch-up).
    func disconnectAll(channelId: String) {
        for entry in channels[channelId, default: []] {
            entry.revocation.revoke()
            forceClose(entry.socket)
        }
    }

    /// Politely close, then drop the transport if the peer never answers:
    /// `pingInterval` starts server-side pings whose unanswered-pong path
    /// closes the channel outright.
    private func forceClose(_ socket: WebSocket) {
        socket.pingInterval = .seconds(5)
        _ = socket.close(code: .goingAway)
    }
}

/// Operational handle over a configured relay: revocation kicks and
/// visibility. Returned by `configureSyncRelay`; safe to hold anywhere.
public struct SyncRelayHandle: Sendable {
    let manager: SocketManager
    /// Present on observer-push mounts (`observerPush != nil`): the
    /// PROCESS-WIDE watch-group owner (`FileWatchManager.shared` — every
    /// push mount shares it, so mounts over one file share one watcher).
    /// Internal — exposed for key-scoped teardown observability in tests
    /// (`hasGroup(forFile:)` / `subscriberCount(forFile:)`), not part of the
    /// public surface.
    let pushManager: FileWatchManager?

    init(manager: SocketManager, pushManager: FileWatchManager? = nil) {
        self.manager = manager
        self.pushManager = pushManager
    }

    /// Kick one user's live connections on a channel (membership removal).
    public func disconnect(channelId: String, userId: UUID) async {
        await manager.disconnect(channelId: channelId, userId: userId)
    }

    /// Kick every connection on a channel (channel deletion / post-purge).
    public func disconnectAll(channelId: String) async {
        await manager.disconnectAll(channelId: channelId)
    }

    public func connectionCount(channelId: String) async -> Int {
        await manager.connectionCount(channelId: channelId)
    }

    /// Every live (channelId, userId) pair across the relay — the input to
    /// a periodic re-authorization sweep. Tokens are typically checked only
    /// at the WebSocket handshake, so without a sweep an admin revoking a
    /// token (or a membership) leaves the live socket connected until it
    /// happens to reconnect.
    public func activeConnections() async -> [(channelId: String, userId: UUID)] {
        await manager.activeConnections()
    }

    /// §1.7.2 PRE-STOP DRAIN: checkpoint one store through the governor — the host's
    /// graceful-shutdown hook (and any admin drain endpoint) calls this for every open
    /// channel store BEFORE the process exits, so the epoch's committed frames are
    /// integrated into the main db rather than left to boot-time WAL recovery (which at
    /// least one production restart failed to run). Safe on wedged files: the governed
    /// checkpoint returns could-not-run and disturbs nothing — but its WEDGE ALARM will
    /// have fired long before shutdown, which is the signal NOT to restart that process.
    public func drainForShutdown(lattice: Lattice, storeURL: URL) {
        RelayCheckpointGovernor.shared.checkpoint(lattice: lattice, storePath: storeURL.path)
    }
}

// MARK: - Relay

extension Lattice {
    /// Configures the sync relay WebSocket endpoint on the given route group.
    ///
    /// This is the only thing LatticeServerKit provides — auth, migrations,
    /// and route protection are the consuming application's responsibility.
    /// The `channelExtractor` is the relay's authorization boundary: it maps
    /// an upgraded request to the channel it may join (throw to refuse).
    ///
    /// - Parameters:
    ///   - routes: A `RoutesBuilder` (typically already behind auth middleware)
    ///   - path: Route path for the WebSocket endpoint (e.g. `["sync"]` or
    ///     `["sync", "group", ":groupID"]`)
    ///   - schema: The Lattice model types to sync on this mount
    ///   - storageURL: Directory for per-channel databases (created if needed)
    ///   - writePolicy: Optional per-table operation allowlist for uploads
    ///   - handshake: Optional declared-schema gate at connect
    ///   - storeConfiguration: Optional per-mount factory for the
    ///     `Lattice.Configuration` used to open each channel's database,
    ///     given that channel's file URL. `nil` (the default) opens with
    ///     `.init(fileURL:)` — target schema version 1, which is correct
    ///     for files the relay itself created. A mount whose files are
    ///     produced/migrated by another opener (e.g. a projector writing at
    ///     a versioned schema) MUST supply the same `migration:` dictionary
    ///     here, or the raw open refuses the file's higher `user_version`.
    ///     The returned configuration must keep `fileURL` at the given URL.
    ///   - observerPush: Opt-in live push of committed changes to this
    ///     mount's sockets (see `SyncObserverPush`). Any commit to a
    ///     channel's file — a relay apply on any mount sharing the file, an
    ///     in-process co-writer, or (best-effort) another process — is
    ///     pushed as ordinary `ServerSentEvent.auditLog` catch-up frames,
    ///     exactly-once and commit-ordered per socket. Intended for deny-all
    ///     watch mounts; `nil` (the default) keeps pre-1.7 behavior exactly.
    ///     Watch groups live on ONE process-wide manager: push mounts over
    ///     the same channel file share one watcher `Lattice` and one commit
    ///     observer (the group's watcher open + reconcile tick come from the
    ///     first subscriber's mount; `pageSize` follows each socket's own
    ///     mount).
    ///     Note: a push-enabled mount does NOT fan client frames to
    ///     same-channel peers (delivery is the pump's job; on a watch mount
    ///     the only client frames are acks, and echoing every observer's ack
    ///     to every other observer is N² frames per commit).
    ///   - channelExtractor: Maps the request to its `SyncChannel`
    @discardableResult
    public static func configureSyncRelay(
        on routes: any RoutesBuilder,
        path: [PathComponent] = ["sync"],
        for schema: [any Lattice.Model.Type],
        storageURL: URL,
        writePolicy: SyncWritePolicy? = nil,
        handshake: SyncSchemaHandshake? = nil,
        storeConfiguration: (@Sendable (URL) -> Lattice.Configuration)? = nil,
        observerPush: SyncObserverPush? = nil,
        channelExtractor: @escaping @Sendable (Request) async throws -> SyncChannel
    ) -> SyncRelayHandle {
        let sockets = SocketManager()
        let ackPathRecorder = ACKPathDiagnostics.recorder(for: storageURL)
        let ingressHooks = RelayIngressTesting.hooks(for: storageURL)
        let applyAdmission = RelayApplyAdmissionTesting.service(for: storageURL) ?? .shared
        let ingressAdmission = RelayIngressAdmissionTesting.service(for: storageURL) ?? .shared
        nonisolated(unsafe) let schema = schema
        // ONE watch manager per PROCESS: push-enabled mounts share
        // `FileWatchManager.shared`, so two push mounts over the same
        // channel file share one watcher Lattice and one commit observer.
        // Mount-specific configuration rides each subscribe call in the
        // context below; `nil` on legacy mounts (zero new work anywhere).
        let watchManager: FileWatchManager? = observerPush != nil ? .shared : nil
        let pushContext = observerPush.map {
            MountPushContext(schema: schema, storeConfiguration: storeConfiguration, options: $0)
        }
        // Select Vapor's synchronous upgrade overload. Its async overload
        // starts a Task before invoking our closure, while WebSocketKit's
        // initial onBinary is still a no-op. Install ingress before returning
        // from upgrade, then move only setup work into the async task below.
        let onUpgrade: @Sendable (Request, WebSocket) -> Void = { [ackPathRecorder, ingressHooks] req, ws in
            precondition(ws.eventLoop.inEventLoop)
            let ackPath = ackPathRecorder.flatMap { recorder -> ACKPathConnection? in
                guard let raw = req.headers.first(name: "X-Lattice-Diagnostic-Connection")
                        ?? req.headers.first(name: "X-Test-User"),
                      let id = UUID(uuidString: raw) else { return nil }
                return recorder.connection(id: id)
            }
            ackPath?.record(.routeEntered)
            // Per-connection state, confined to the socket's event loop.
            // Frames that arrive before the (slow — schema ensure, epoch
            // migrations) per-channel lattice open finishes are BUFFERED and
            // replayed in arrival order the moment it's live. Previously the
            // open ran before handler registration, and WebSocketKit silently
            // drops frames with no onBinary registered — a client that
            // uploaded within the open window lost that frame, its entries
            // sat unACKed until the resend/reconnect, and the relay tests
            // that await that first delivery hung (the intermittent CI hang
            // class). ONE `Lattice` REFERENCE per connection, held for the
            // socket's lifetime (a fresh Lattice per frame raced the weak
            // instance cache and segfaulted under real bursts — exit 139).
            //
            // NOT one SQLite connection per socket: every relay-shaped open of
            // the same file+schema aliases ONE cached `swift_lattice`
            // (LatticeCache::get_or_create) and therefore ONE
            // FULLMUTEX-serialized SQLite connection — leaked per-connection
            // Lattices retain that shared instance rather than adding
            // connections. That is why concurrent applies on a channel
            // contend inside `begin_transaction` (they are siblings on one
            // connection, not rivals for a file lock) and why 1.7.1
            // serializes them per file instead. The instance cache does NOT
            // key on `busyTimeoutMs`, so the first open of a file installs the
            // budget every later aliased handle runs with.
            let state = ConnectionRelayState(ingress: ingressAdmission.makeAccount())

            // Handlers go live IMMEDIATELY — synchronously on the socket's
            // event loop, BEFORE any await (handshake, extractor, open). The
            // old userIdExtractor was synchronous, so upgrade→registration
            // had no suspension point; the async channelExtractor would
            // otherwise reopen the frame-drop window. Until go-live, frames
            // only buffer. `state.channelId` is late-bound: nil means this
            // connection never registered with the SocketManager, so onClose
            // has nothing to deregister; `state.process` is installed at
            // go-live alongside the lattice.
            ackPath?.record(.handlersScheduled)
            ackPath?.record(.handlersEntered)
            ws.onText { ws, str in
                print("🧦", "Received String Event", str)
            }
            ws.onBinary { [ackPath] ws, bb in
                ackPath?.record(.binaryEntered, bytes: bb.readableBytes)
                // Revoked or refused: consume and discard. Never apply,
                // never ack, never fan out, never buffer.
                guard !state.revocation.isRevoked, !state.isRefused else {
                    if state.revocation.isRevoked { state.ingress.seal(.revoked) }
                    ackPath?.record(.ingressDiscarded, bytes: bb.readableBytes)
                    return
                }
                do {
                    let frame = try state.ingress.copyFrame(bb)
                    // A stronger stop may race the owned copy. Its charge is
                    // retained until this envelope and any captures disappear.
                    guard !state.revocation.isRevoked, !state.applyAdmissionStopped.isRevoked,
                          !(state.isRefused && state.lattice == nil) else { return }
                    if state.lattice != nil, let cont = state.applyContinuation {
                        state.yieldIngress(frame, to: cont, socket: ws, diagnostic: ackPath)
                    } else {
                        state.buffered.append(frame)
                        ackPath?.record(.ingressBuffered, bytes: frame.byteCount,
                                        count: state.ingress.snapshot.inputBytes)
                        ingressHooks?.didBufferFrame(frame.byteCount)
                    }
                } catch {
                    ackPath?.record(.ingressRefused, bytes: bb.readableBytes,
                                    count: state.ingress.snapshot.inputBytes)
                    // Live ingress overflow preserves the already accepted
                    // stream's drain. Pre-open envelopes have no applier yet.
                    state.sealIngress((error as? RelayIngressStopReason) ?? .streamInvariant, socket: ws)
                    ws.pingInterval = .seconds(5)
                    _ = ws.close(code: .policyViolation)
                }
            }
            ws.onClose.whenComplete { [ackPath] _ in
                state.sealIngress(.closed, socket: ws)
                ackPath?.record(.connectionClosed)
                ingressHooks?.didCloseConnection()
                Task { @RelayControlActor in
                    if let channelId = state.channelId {
                        sockets.remove(socket: ws, channelId: channelId)
                    }
                    // Observer push: drop this socket's subscription
                    // (idempotent — the pump's send-failure path may have
                    // beaten us here). Group teardown when the last
                    // subscriber leaves happens inside the manager, with
                    // the watcher released off-loop.
                    if let sub = state.pushSubscription {
                        watchManager?.unsubscribe(sub)
                    }
                    // Detach the per-connection lattice ON the loop (state
                    // is loop-confined) but RELEASE it OFF the loop:
                    // ~lattice_db tears down sync threads, and running
                    // that inline in `execute` stalls the shared event
                    // loop for every other connection (observed as
                    // time-limit storms in the in-process relay tests).
                    ws.eventLoop.execute {
                        // Stop the apply pipeline: finish drains the
                        // stream; the consumer exits after the in-flight
                        // apply (revocation gates any queued remainder).
                        state.applyContinuation?.finish()
                        state.applyContinuation = nil
                        state.applyConsumer = nil
                        let box = state.lattice.map(UnsafeSendableBox.init)
                        state.lattice = nil
                        state.process = nil
                        state.buffered.removeAll()
                        if let box {
                            RelayExecutionPool.io.submitRequired(for: state.nativeReleaseKey) { box.clear() }
                        }
                    }
                }
            }
            ackPath?.record(.handlersComplete)

            Task { [ackPath, ingressHooks] in
                ackPath?.record(.setupTaskStarted)
                var setupHandedOff = false
                defer { if !setupHandedOff { ingressHooks?.didFinishAsyncSetup() } }
                await ingressHooks?.beforeAsyncSetup()
                // Schema handshake: version skew closes with an explicit,
                // attributable reason instead of the silent apply-wedge class.
                if let refusal = handshake?.refusal(for: req) {
                    ackPath?.record(.handshakeRefused)
                    print(">>> Sync handshake refused: \(refusal)")
                    state.sealIngress(.setupRefused, socket: ws)
                    try? await ws.send("schema-handshake: \(refusal)")
                    ws.pingInterval = .seconds(5)   // drop a peer that ignores the close
                    try? await ws.close(code: .policyViolation)
                    return
                }

                let channel: SyncChannel
                ackPath?.record(.extractorBegin)
                do {
                    channel = try await channelExtractor(req)
                    ackPath?.record(.extractorEnd)
                } catch {
                    ackPath?.record(.extractorError)
                    ackPath?.record(.extractorRefused)
                    print(">>> Could not authorize sync connection: \(error)")
                    state.sealIngress(.setupRefused, socket: ws)
                    ws.pingInterval = .seconds(5)
                    try? await ws.close()
                    return
                }

                // Defense in depth against path traversal: channel ids commonly
                // embed request-controlled path parameters (Vapor percent-decodes
                // them, so an encoded `../` can reach here past an extractor that
                // forgot to validate). The database name must be a single path
                // component inside storageURL.
                guard !channel.databaseFileName.isEmpty,
                      !channel.databaseFileName.contains("/"),
                      !channel.databaseFileName.contains("\\"),
                      !channel.databaseFileName.hasPrefix(".") else {
                    ackPath?.record(.unsafeNameRefused)
                    print(">>> Refusing unsafe database filename for channel \(channel.id)")
                    state.sealIngress(.setupRefused, socket: ws)
                    ws.pingInterval = .seconds(5)
                    try? await ws.close(code: .policyViolation)
                    return
                }

                let latticeURL: URL? = storageURL
                    .appending(path: channel.databaseFileName)
                // Apply-serialization key: the SAME canonical channel-file key
                // the observer-push watch groups use, so two mounts over one file
                // (writer + watch, or two writer mounts) share one apply queue
                // rather than inventing a second path normalization. The
                // channel-id fallback is unreachable in practice (the URL is
                // always built above) and only exists so the key is never empty.
                let applyKey = latticeURL.map { FileWatchManager.canonicalKey(for: $0) }
                    ?? "channel:\(channel.id)"

                @Sendable func processFrame(_ ws: WebSocket, _ ingressFrame: RelayIngressFrame, _ lattice: Lattice) async {
                    defer { withExtendedLifetime(ingressFrame) {} }
                    ackPath?.record(.processEntered, bytes: ingressFrame.byteCount)
                    // Authoritative revocation: a kicked connection stops
                    // affecting the channel immediately, even if its transport
                    // lingers because the peer never answered the close frame.
                    guard !state.revocation.isRevoked, !state.applyAdmissionStopped.isRevoked else {
                        ackPath?.record(.processRevoked)
                        return
                    }
                    // This request owns its facade through native return and
                    // publication. The box is immutable throughout the request;
                    // only the file's admitted worker performs this apply.
                    let applyOwner = UnsafeSendableBox(lattice)
                    let admissionSpan = ackPath?.record(.applyAdmissionRequested, bytes: ingressFrame.byteCount) ?? 0
                    let admissionDiagnostic: ACKPathAdmission?
                    if let ackPath { admissionDiagnostic = .init(connection: ackPath, span: admissionSpan) }
                    else { admissionDiagnostic = nil }
                    do {
                        try await applyAdmission.withAdmission(for: applyKey, frame: ingressFrame,
                                                               diagnostic: admissionDiagnostic, operation: { data in
                            processRelayApplyOnWorker(data: data, lattice: applyOwner.value, channel: channel,
                                                      policy: writePolicy, revocation: state.revocation,
                                                      diagnostic: ackPath, needsFanOut: watchManager == nil,
                                                      admissionSpan: admissionSpan)
                        }, completion: { processed in
                            let frame: RelayAppliedFrame
                            switch processed {
                            case .revoked:
                                ackPath?.record(.processRevoked)
                                return
                            case .refused(let reason):
                                print(">>> Sync frame rejected on \(channel.id): \(reason)")
                                if let encoded = try? JSONEncoder().encode(ServerSentEvent.rejected(reason: reason)) {
                                    ws.send(ByteBuffer(data: encoded))
                                }
                                return
                            case .applied(let applied): frame = applied
                            }
                            let outcome = frame.outcome
                            let frameSpan = frame.span
                            ackPath?.record(.applyGateReturned, span: frameSpan, count: frame.requestedIds.count,
                                            applied: outcome.applied.count, missing: outcome.unapplied.count,
                                            attempts: outcome.attempts, matching: outcome.applied)

                            // §1.7.2 governor: apply-coupled checkpoint (threshold- or time-due), OUTSIDE the
                            // apply gate so the slot hold is never extended — RelayCheckpoint.swift carries the
                            // starvation mechanism and the wedge-alarm law.
                            if let url = latticeURL {
                                ackPath?.record(.afterApplyBegin, span: frameSpan)
                                RelayCheckpointGovernor.shared.afterApply(lattice: applyOwner.value, storePath: url.path)
                                ackPath?.record(.afterApplyEnd, span: frameSpan)
                            }

                            // B3.8: never ack an empty apply — in particular incoming
                            // ACK frames used to be re-acked (ack-of-ack ping-pong, one
                            // empty bookkeeping round trip per client download ack,
                            // forever).
                            ackPath?.record(.ackDecision, span: frameSpan, applied: outcome.applied.count,
                                            missing: outcome.unapplied.count, matching: outcome.applied)
                            if !outcome.applied.isEmpty {
                                ackPath?.record(.ackEncodeBegin, span: frameSpan)
                                if let encoded = try? JSONEncoder().encode(ServerSentEvent.ack(outcome.applied)) {
                                    ackPath?.record(.ackEncodeEnd, span: frameSpan, bytes: encoded.count)
                                    ackPath?.record(.ackSendBegin, span: frameSpan, bytes: encoded.count)
                                    ws.send(ByteBuffer(data: encoded))
                                    // Existing synchronous send-call return, not write completion.
                                    ackPath?.record(.ackSendReturn, span: frameSpan)
                                } else {
                                    ackPath?.record(.ackEncodeFailure, span: frameSpan)
                                }
                            } else {
                                ackPath?.record(.ackEmpty, span: frameSpan)
                            }

                            // The silent-drop hole, closed. Before 1.7.1 a frame whose
                            // apply came back short produced NOTHING: no ack (the id list
                            // was empty), no nack (there was no nack), and no log line
                            // (nothing threw, so the print-only catch never ran). Now the
                            // shortfall is loud and the client is told exactly which
                            // entries to resend.
                            if !outcome.unapplied.isEmpty {
                                relayLog.error("""
                                    relay apply INCOMPLETE: channel=\(channel.id) user=\(channel.userId) \
                                    sqlite=\(outcome.errorClass.rawValue) frameBytes=\(frame.byteCount) \
                                    requested=\(frame.requestedIds.count) applied=\(outcome.applied.count) \
                                    unapplied=\(outcome.unapplied.count) attempts=\(outcome.attempts) \
                                    elapsedMs=\(Int(outcome.elapsedMs)) — nacking\
                                    \(outcome.lastError.map { " error=\($0)" } ?? "")
                                    """)
                                if let encoded = try? JSONEncoder().encode(
                                    ServerSentEvent.nack(ids: outcome.unapplied, reason: outcome.nackReason)) {
                                    ws.send(ByteBuffer(data: encoded))
                                }
                            } else if let error = outcome.lastError {
                                if frame.malformed || frame.claimsUpload {
                                    // An UPLOAD this relay could not parse (or whose
                                    // entries yielded no extractable globalIds) failed
                                    // terminally. There is nothing to nack BY ID — and
                                    // this used to log as bookkeeping noise while the
                                    // sender's entries were LOST. Be loud and CLOSE: a
                                    // native writer redials and resends; a browser
                                    // writer at least sees the break instead of a
                                    // healthy socket over a dropped frame.
                                    relayLog.error("""
                                        relay apply failed on a frame it could not parse as an upload: \
                                        channel=\(channel.id) user=\(channel.userId) \
                                        sqlite=\(outcome.errorClass.rawValue) frameBytes=\(frame.byteCount) \
                                        attempts=\(outcome.attempts) elapsedMs=\(Int(outcome.elapsedMs)) \
                                        — closing so the client redials error=\(error)
                                        """)
                                    ackPath?.record(.applyFailureClose, span: frameSpan)
                                    try? await ws.close(code: .unexpectedServerError)
                                } else {
                                    // A non-upload frame (an ack's bookkeeping write) that
                                    // failed: nothing to nack — the client's entries are
                                    // already durable — but never silent.
                                    relayLog.warning("""
                                        relay bookkeeping apply failed: channel=\(channel.id) \
                                        user=\(channel.userId) sqlite=\(outcome.errorClass.rawValue) \
                                        frameBytes=\(frame.byteCount) attempts=\(outcome.attempts) \
                                        elapsedMs=\(Int(outcome.elapsedMs)) error=\(error)
                                        """)
                                }
                            }

                            // Legacy same-channel audit-data fan-out: writer mounts
                            // keep healthy uploads byte-for-byte, and local-only ACK
                            // bookkeeping is excluded below. On push-enabled mounts
                            // it is skipped entirely: delivery is the pump's job
                            // (commit-ordered, cursor-deduped), uploads are policy-refused
                            // anyway, and fanning every frame would echo each observer's
                            // ack to every other observer — N² frames per commit.
                            //
                            // Fan out ONLY what the channel database actually holds. A
                            // frame that failed to apply used to be fanned out anyway:
                            // live peers applied entries the relay store never got, so
                            // catch-up replay could never deliver them to anyone who
                            // reconnected or joined later — permanent divergence between
                            // live observers and the channel of record (program-plan
                            // sync-M7, reproduced during this incident). A PARTIAL apply
                            // fans the applied subset; a total failure fans nothing.
                            // Download ACKs have already updated this relay's
                            // synchronization bookkeeping in receive. Forwarding
                            // them to every peer adds no audit data and makes a
                            // room's acknowledgment traffic grow quadratically.
                            // Preserve upload/unknown/replay forwarding, including
                            // Core's auditLog-before-ack decoder precedence.
                            guard watchManager == nil, !frame.isAcknowledgment else { return }
                            let recipients = await sockets.sockets(channelId: channel.id).filter { $0 !== ws }
                            guard !recipients.isEmpty else { return }
                            let fanOut: ByteBuffer?
                            if outcome.isComplete {
                                fanOut = ingressFrame.makeLegacyFanoutBuffer()
                            } else if let reduced = frame.partialFanOut {
                                fanOut = ByteBuffer(data: reduced)
                            } else {
                                fanOut = nil
                            }
                            guard let fanOut else { return }
                            for socket in recipients {
                                socket.send(fanOut)
                            }
                        })
                    } catch {
                        // This frame never entered native apply. Leave it unACKed
                        // and close so upload/bookkeeping can replay on reconnect.
                        ackPath?.record(.applyAdmissionRejected, bytes: ingressFrame.byteCount)
                        // Later upstream frames have not been service-admitted.
                        // Leave them unACKed for replay, rather than applying
                        // around the refused frame on this connection.
                        state.sealIngress(.applyRefused, socket: ws, stopQueued: true)
                        ws.pingInterval = .seconds(5)
                        ws.close(code: .policyViolation, promise: nil)
                    }
                }

                // Authorization remains an external async boundary. Internal
                // setup/catch-up now advances through direct control callbacks;
                // this task never awaits its native or socket completions.
                let lastEventId = try? req.query.get(UUID?.self, at: "last-event-id")
                let input = RelayConnectionSetupInput(
                    schema: schema, storageURL: storageURL, fileURL: latticeURL,
                    applyKey: applyKey, channel: channel, socket: ws, state: state,
                    sockets: sockets, watchManager: watchManager, pushContext: pushContext,
                    storeConfiguration: storeConfiguration, lastEventId: lastEventId,
                    processFrame: processFrame, diagnostic: ackPath,
                    sendCatchUp: ingressHooks?.sendCatchUp,
                    didFinish: { ingressHooks?.didFinishAsyncSetup() })
                setupHandedOff = true
                Task { @RelayControlActor in
                    RelayConnectionSetup(input: input).start()
                }

            }
        }
        routes.webSocket(path, maxFrameSize: WebSocketMaxFrameSize(integerLiteral: 300 * 1024 * 1024),
                         shouldUpgrade: { $0.eventLoop.makeSucceededFuture(HTTPHeaders?.some([:])) },
                         onUpgrade: onUpgrade)
        return SyncRelayHandle(manager: sockets, pushManager: watchManager)
    }

    /// Personal-topology wrapper preserving the original API and on-disk
    /// layout: each user is their own channel, stored as `<userId>.sqlite`.
    public static func configureSyncRelay(
        on routes: any RoutesBuilder,
        for schema: [any Lattice.Model.Type],
        storageURL: URL,
        userIdExtractor: @escaping @Sendable (Request) throws -> UUID
    ) {
        _ = configureSyncRelay(
            on: routes,
            path: ["sync"],
            for: schema,
            storageURL: storageURL
        ) { req in
            let userId = try userIdExtractor(req)
            return SyncChannel(id: userId.uuidString, userId: userId)
        }
    }
}

extension Data: DataProtocol {
}


/// Holds a non-Sendable value captured by the relay's @Sendable socket
/// callbacks. Access is serialized by the connection's event loop; `clear()`
/// releases on close.
final class UnsafeSendableBox<T>: @unchecked Sendable {
    private var stored: T?
    init(_ value: T) { self.stored = value }
    var value: T { stored! }
    /// Non-trapping read for callers that can lose a release race and must
    /// exit cleanly instead (the observer-push pump path): `nil` after
    /// `clear()`.
    var valueIfPresent: T? { stored }
    func clear() { stored = nil }
}

/// Per-connection relay state. All access is confined to the socket's event
/// loop (handler bodies and the `execute` hops that mutate it), so the
/// unchecked-Sendable is a loop-confinement claim, not a locking one.
/// `lattice == nil` means "still opening": frames buffer in arrival order
/// and are replayed the moment the per-channel lattice goes live.
final class ConnectionRelayState: @unchecked Sendable {
    let ingress: RelayIngressAccount
    init(ingress: RelayIngressAccount = RelayIngressAdmission.shared.makeAccount()) {
        self.ingress = ingress
    }
    var lattice: Lattice?
    /// Installed at go-live: the frame processor bound to this connection's
    /// channel (handlers register before the channel is known).
    var process: ((WebSocket, RelayIngressFrame, Lattice) async -> Void)?
    var buffered: [RelayIngressFrame] = []

    /// Post-go-live apply pipeline (B3.2): frames are enqueued from the event
    /// loop and applied by ONE detached consumer per connection, so a slow
    /// apply no longer stalls every other socket sharing the loop. The
    /// continuation is loop-confined like the rest of the mutable state;
    /// lifetime accounting is lock-backed, never reset on close. The consumer
    /// receives everything it needs as captured arguments and re-checks `revocation`
    /// (lock-backed) at dequeue.
    var applyContinuation: AsyncStream<RelayIngressFrame>.Continuation?
    var applyConsumer: Task<Void, Never>?

    /// Sealing prevents new copies but never releases an outstanding charge.
    /// Normal close/ingress overflow finishes and drains accepted live work;
    /// only an explicit stronger stop skips its queued remainder.
    func sealIngress(_ reason: RelayIngressStopReason, socket: WebSocket, stopQueued: Bool = false) {
        ingress.seal(reason)
        isRefused = true
        if stopQueued { applyAdmissionStopped.revoke() }
        socket.eventLoop.execute {
            if self.lattice == nil { self.buffered.removeAll() }
            self.applyContinuation?.finish()
        }
    }

    func yieldIngress(_ frame: RelayIngressFrame,
                      to continuation: AsyncStream<RelayIngressFrame>.Continuation,
                      socket: WebSocket, diagnostic: ACKPathConnection?) {
        precondition(socket.eventLoop.inEventLoop)
        switch continuation.yield(frame) {
        case .enqueued:
            diagnostic?.record(.ingressYielded, bytes: frame.byteCount, count: ingress.snapshot.inputBytes)
        case .terminated where ingress.snapshot.firstReason != nil:
            // A normal seal may race a reserved copy. Returning this envelope
            // releases only its own charge; accepted queued work still drains.
            diagnostic?.record(.ingressDiscarded, bytes: frame.byteCount)
        case .dropped, .terminated:
            // The reservation includes every stream element and the consumer,
            // so a drop indicates an invariant violation, never success.
            sealIngress(.streamInvariant, socket: socket, stopQueued: true)
            socket.pingInterval = .seconds(5)
            socket.close(code: .policyViolation, promise: nil)
        @unknown default:
            sealIngress(.streamInvariant, socket: socket, stopQueued: true)
            socket.close(code: .policyViolation, promise: nil)
        }
    }

    /// Same per-file IO lane as setup/catch-up; a pre-authorization close
    /// has no native owner and uses only this connection's unique fallback.
    private let nativeReleaseKeyBox = NIOLockedValueBox<String>("unopened:" + UUID().uuidString)
    var nativeReleaseKey: String {
        get { nativeReleaseKeyBox.withLockedValue { $0 } }
        set { nativeReleaseKeyBox.withLockedValue { $0 = newValue } }
    }

    /// Late-bound channel id. Written/read by setup and close control turns;
    /// kept in a lock for existing cross-executor diagnostics, not in loop
    /// confinement. nil = never registered with the SocketManager.
    private let channelIdBox = NIOLockedValueBox<String?>(nil)
    var channelId: String? {
        get { channelIdBox.withLockedValue { $0 } }
        set { channelIdBox.withLockedValue { $0 = newValue } }
    }

    /// Set by the SocketManager on revocation; consulted before any apply,
    /// ack, or fan-out (the close frame alone is not authoritative).
    let revocation = RevocationFlag()
    /// Native-service refusal stops this connection's later upstream frames.
    /// Separate from the old ingress cap, whose already accepted stream drains.
    let applyAdmissionStopped = RevocationFlag()

    /// Observer-push subscription (push-enabled mounts only). Written by the
    /// setup control turn after the per-connection open and read by the
    /// close control turn — lock-backed like `channelId`, not loop-confined.
    /// nil = never subscribed (legacy mount, or watcher open failure).
    private let pushSubscriptionBox = NIOLockedValueBox<PushSubscription?>(nil)
    var pushSubscription: PushSubscription? {
        get { pushSubscriptionBox.withLockedValue { $0 } }
        set { pushSubscriptionBox.withLockedValue { $0 = newValue } }
    }

    /// Set when the connection is refused (handshake/authorization/unsafe
    /// name): the binary handler then discards instead of buffering, so a
    /// peer that ignores the close frame cannot pin memory.
    private let refusedBox = NIOLockedValueBox<Bool>(false)
    var isRefused: Bool {
        get { refusedBox.withLockedValue { $0 } }
        set { refusedBox.withLockedValue { $0 = newValue } }
    }

    /// Set on the go-live hop when the connection died (or was revoked)
    /// during the lattice open. The go-live completion hands the unopened
    /// catch-up owner back to control, which queues its final release on IO.
    private let abandonedBox = NIOLockedValueBox<Bool>(false)
    var abandoned: Bool {
        get { abandonedBox.withLockedValue { $0 } }
        set { abandonedBox.withLockedValue { $0 = newValue } }
    }
}

/// TEST-ONLY (internal — `@testable` reach only) fault injection for the
/// connect-time catch-up error path, which is otherwise unreachable from a
/// test: nothing a client can send makes the catch-up encode or send throw
/// on demand. When non-nil it is called once per connection at the top of
/// the catch-up task — AFTER the parked push subscription is registered,
/// BEFORE any frame is sent — with that connection's channel id, so a test
/// can scope the fault to its own channel (this box is process-global and
/// suites run in parallel). Nil in production: one lock-protected read per
/// connection, alongside the catch-up query.
let _catchUpFaultForTesting = NIOLockedValueBox<(@Sendable (String) throws -> Void)?>(nil)
