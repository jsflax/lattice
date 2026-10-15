import Foundation
import Vapor
import NIOCore
import Lattice
import NIOConcurrencyHelpers
#if canImport(Combine)
import Combine
#endif

/// This parses controls, never canonical data. Only an issued native export may
/// create a cut. The bounded syntax pass rejects duplicate keys before Foundation
/// can collapse them. Legacy mounts also recognize and refuse this namespace.
enum RelayOrdinaryControl: Sendable, Equatable {
    case request(String)
    case historyRequest(String)
    case historyRelationRequest(String)
    case historyProgress(RelayOrdinaryHistoryProgress)
    case modelRequest(request: String, profile: String)
    case receipt(RelayOrdinaryIdentity)

    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 4_096 else { throw RelayOrdinaryError.control }
        var syntax = RelayACKSyntax(data)
        _ = try syntax.scan()
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["latticeOrdinarySync"],
              let body = root["latticeOrdinarySync"] as? [String: Any],
              let version = body["version"] as? NSNumber,
              String(cString: version.objCType) != "c", version.stringValue == "2",
              let kind = body["kind"] as? String else { throw RelayOrdinaryError.control }
        if kind == "modelRequest" {
            guard Set(body.keys) == ["version", "kind", "request", "modelProfile"],
                  let request = body["request"] as? String, request.utf8.count == 36,
                  UUID(uuidString: request) != nil,
                  let profile = body["modelProfile"] as? String,
                  SyncOrdinaryModelProfile.validIdentifier(profile) else { throw RelayOrdinaryError.control }
            return .modelRequest(request: request, profile: profile)
        }
        if kind == "historyProgress" { return .historyProgress(try .init(body)) }
        if kind == "request", body["relation"] != nil {
            guard Set(body.keys) == ["version", "profile", "kind", "request", "relation"],
                  body["profile"] as? String == "paged-history-v1",
                  body["relation"] as? String == "mounted-lineage-frontier-v1",
                  let request = body["request"] as? String, request.utf8.count == 36,
                  UUID(uuidString: request) != nil else { throw RelayOrdinaryError.control }
            return .historyRelationRequest(request)
        }
        if kind == "request", body["profile"] != nil {
            guard Set(body.keys) == ["version", "profile", "kind", "request"],
                  body["profile"] as? String == "paged-history-v1",
                  let request = body["request"] as? String, request.utf8.count == 36,
                  UUID(uuidString: request) != nil else { throw RelayOrdinaryError.control }
            return .historyRequest(request)
        }
        if kind == "request" {
            guard Set(body.keys) == ["version", "kind", "request"],
                  let request = body["request"] as? String, request.utf8.count == 36,
                  UUID(uuidString: request) != nil else { throw RelayOrdinaryError.control }
            return .request(request)
        }
        guard kind == "receipt", Set(body.keys) == ["version", "kind", "source", "epoch", "cut", "contentDigest"] else {
            throw RelayOrdinaryError.control
        }
        return .receipt(try RelayOrdinaryIdentity(body))
    }
}

enum RelayOrdinaryError: Error { case control, capacity, stopped, receipt, header }

/// Weak entries are promoted into one bounded, owning snapshot. Every promotion,
/// including unmatched keys, survives until AFTER the mutex is unlocked. Owner
/// deinit may reenter remove(), so no temporary last owner can die under lock.
/// This shared index is exercised directly by the ARC/reentrant-retirement tests.
final class RelayOrdinaryWeakStoreIndex<Owner: AnyObject>: @unchecked Sendable {
    struct Retained { let owner: Owner; let key: String }
    private struct Entry { weak var owner: Owner?; let key: String }
    private let lock = NIOLock()
    private var entries: [ObjectIdentifier: Entry] = [:]
    private let globalLimit = 64, perStoreLimit = 64

    // Caller holds lock. Each promoted strong local is appended before leaving
    // its iteration; the returned array owns ALL such references through unlock.
    private func snapshotLocked() -> [Retained] {
        var retained: [Retained] = []; retained.reserveCapacity(entries.count)
        var absent: [ObjectIdentifier] = []
        for (identity, entry) in entries {
            if let owner = entry.owner { retained.append(.init(owner: owner, key: entry.key)) }
            else { absent.append(identity) }
        }
        for identity in absent { entries.removeValue(forKey: identity) }
        return retained
    }
    func register(_ owner: Owner, key: String) throws {
        let admission = lock.withLock { () -> (retained: [Retained], accepted: Bool) in
            let retained = snapshotLocked()
            // Return the owning snapshot even on refusal. Throwing from inside
            // this closure would unwind its last references before unlock.
            guard !key.isEmpty, key.utf8.count <= 4_096, entries.count < globalLimit,
                  entries.values.filter({ $0.key == key }).count < perStoreLimit else { return (retained, false) }
            entries[ObjectIdentifier(owner)] = .init(owner: owner, key: key)
            return (retained, true)
        }
        defer { withExtendedLifetime(admission.retained) {} }
        guard admission.accepted else { throw RelayOrdinaryError.capacity }
    }
    func remove(_ owner: Owner) { lock.withLock { _ = entries.removeValue(forKey: ObjectIdentifier(owner)) } }
    func visit(key: String, _ body: (Owner) -> Void) {
        let retained = lock.withLock { snapshotLocked() }
        defer { withExtendedLifetime(retained) {} }
        for entry in retained where entry.key == key { body(entry.owner) }
    }
}

/// Same-process routing only. Weak membership carries no source authority;
/// every wake executes the recipient's own checked native capture. Replaced
/// physical stores are refused there and by the first-issued-image guard below.
/// At most64 endpoints globally/per canonical key; no payload or strong callback
/// is retained between calls. Canonical path aliases remain an explicit gap.
private final class RelayOrdinaryWakeRegistry: @unchecked Sendable {
    static let shared = RelayOrdinaryWakeRegistry()
    private let index = RelayOrdinaryWeakStoreIndex<RelayOrdinaryConnection>()
    func register(_ connection: RelayOrdinaryConnection, key: String) throws { try index.register(connection, key: key) }
    func remove(_ connection: RelayOrdinaryConnection) { index.remove(connection) }
    func wake(key: String) { index.visit(key: key) { $0.nudge() } }
}

/// Immutable original acceptance bytes from the actual native source result.
/// One 8 MiB staging charge precedes native receive/Swift copy and survives the
/// real send callback, covering Data plus its separately owned ByteBuffer.
final class RelayOrdinaryUploadAcknowledgment: @unchecked Sendable {
    private var storedAcceptance: OrdinarySyncUploadAcceptance?
    var acceptance: OrdinarySyncUploadAcceptance { storedAcceptance! }
    private var charge: RelayOrdinaryBudget.Charge?
    init(_ acceptance: OrdinarySyncUploadAcceptance, charge: RelayOrdinaryBudget.Charge) {
        self.storedAcceptance = acceptance; self.charge = charge
    }
    func merging(_ value: OrdinarySyncUploadAcceptance) throws -> OrdinarySyncUploadAcceptance { try storedAcceptance!.merging(value) }
    func acknowledgmentData() throws -> Data { try storedAcceptance!.acknowledgmentData() }
    // Final object destruction has exclusive access. Release the real native
    // result lease before another staged upload can use this logical slot.
    deinit { storedAcceptance = nil; charge = nil }
}

private struct RelayOrdinaryPhysicalImage: Equatable {
    let source, epoch: String
    let device, inode: String
    init(_ body: [String: Any], identity: RelayOrdinaryIdentity) throws {
        func number(_ key: String) throws -> String {
            guard let value = body[key] as? String, !value.isEmpty, value.utf8.count <= 20,
                  value == "0" || value.first != "0", value.utf8.allSatisfy({ (48...57).contains($0) }),
                  UInt64(value) != nil else { throw RelayOrdinaryError.header }
            return value
        }
        source = identity.source; epoch = identity.epoch
        device = try number("captureDevice"); inode = try number("captureInode")
    }
}

struct RelayOrdinaryIdentity: Sendable, Equatable {
    let source, epoch, cut, contentDigest: String
    init(_ body: [String: Any]) throws {
        func text(_ key: String, cap: Int) throws -> String {
            guard let value = body[key] as? String, !value.isEmpty,
                  value.utf8.count <= cap, value.utf8.allSatisfy({ (33...126).contains($0) }) else {
                throw RelayOrdinaryError.header
            }
            return value
        }
        source = try text("source", cap: 256)
        epoch = try text("epoch", cap: 20)
        cut = try text("cut", cap: 20)
        contentDigest = try text("contentDigest", cap: 64)
        guard [epoch, cut].allSatisfy({ $0.first != "0" && $0.utf8.allSatisfy({ (48...57).contains($0) }) && UInt64($0) != nil }),
              contentDigest.utf8.count == 64,
              contentDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw RelayOrdinaryError.header
        }
    }

    static func header(_ bytes: Data) throws -> Self {
        // Trusted native producer, already bounded by its issued frame. This is
        // just retained correlation; a decoded header cannot issue an export.
        guard bytes.count <= 4_194_304,
              let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let body = root["latticeOrdinarySync"] as? [String: Any],
              body["kind"] as? String == "cut", (body["version"] as? Int) == 2 else {
            throw RelayOrdinaryError.header
        }
        return try .init(body)
    }
}

/// Process-wide logical ownership budgets. A cut slot is reserved BEFORE native
/// capture; a staging slot BEFORE Data/ByteBuffer allocation. Native's separate
/// immutable capture accounting remains authoritative. Eight MiB covers the
/// independent <=4MiB Data and <=4MiB ByteBuffer, not allocator/RSS overhead or
/// transport internals. No borrowed input or native receipt releases a charge.
final class RelayOrdinaryBudget: @unchecked Sendable {
    static let shared = RelayOrdinaryBudget()
    enum Kind { case endpoint, cut, staging }
    struct Snapshot: Equatable { let endpoints, cuts, staging, stagingBytes: Int }
    final class Charge: @unchecked Sendable {
        private let budget: RelayOrdinaryBudget
        private let endpoint: Bool
        private let lease: RelayOrdinaryAdmission.Lease?
        fileprivate init(_ budget: RelayOrdinaryBudget, endpoint: Bool = false, lease: RelayOrdinaryAdmission.Lease? = nil) {
            self.budget = budget; self.endpoint = endpoint; self.lease = lease
        }
        deinit { if endpoint { budget.releaseEndpoint() } }
    }
    private let lock = NIOLock()
    private var endpoints = 0
    private let endpointLimit: Int
    private let admission: RelayOrdinaryAdmission
    init(endpoints: Int = 64, cuts: Int = 4, staging: Int = 4) {
        precondition((1...64).contains(endpoints))
        endpointLimit = endpoints; admission = .init(cuts: cuts, staging: staging)
    }
    var snapshot: Snapshot {
        let count = lock.withLock { endpoints }, owned = admission.snapshot
        return .init(endpoints: count, cuts: owned.activeCuts, staging: owned.activeStaging, stagingBytes: owned.activeStaging * 8_388_608)
    }
    var waiting: RelayOrdinaryAdmission.Snapshot { admission.snapshot }
    func reserve(_ kind: Kind) throws -> Charge {
        switch kind {
        case .endpoint:
            let accepted = lock.withLock { guard endpoints < endpointLimit else { return false }; endpoints += 1; return true }
            guard accepted else { throw RelayOrdinaryError.capacity }
            return Charge(self, endpoint: true)
        case .cut: return Charge(self, lease: try admission.reserve(.cut))
        case .staging: return Charge(self, lease: try admission.reserve(.staging))
        }
    }
    func request(_ kind: RelayOrdinaryAdmission.Kind,
                 _ completion: @escaping @Sendable (Result<Charge, RelayOrdinaryAdmission.Failure>) -> Void) -> RelayOrdinaryAdmission.Request {
        admission.request(kind) { [self] result in
            completion(result.map { Charge(self, lease: $0) })
        }
    }
    private func releaseEndpoint() { lock.withLock { precondition(endpoints > 0); endpoints -= 1 } }
}

// Exact-key test injection only; no authority or changed production defaults.
// Removed services remain retained through unlock to permit reentrant cleanup.
enum RelayOrdinaryBudgetTesting {
    private static let services = NIOLockedValueBox<[String: RelayOrdinaryBudget]>([:])
    static func install(_ service: RelayOrdinaryBudget, for key: String) throws {
        let installed = services.withLockedValue { values in
            guard values.count < 64, values[key] == nil else { return false }
            values[key] = service; return true
        }
        guard installed else { throw RelayOrdinaryError.capacity }
    }
    static func service(for key: String) -> RelayOrdinaryBudget? { services.withLockedValue { $0[key] } }
    static func remove(_ service: RelayOrdinaryBudget, for key: String) {
        let retained = services.withLockedValue { values -> RelayOrdinaryBudget? in
            guard values[key] === service else { return nil }
            return values.removeValue(forKey: key)
        }
        withExtendedLifetime(retained) {}
    }
}

/// Single current cut. Matching receipt and actual final write completion are
/// independent facts. A receipt may race the final write callback, but cannot
/// release native ownership before that callback. No AuditLog ACK is generated.
struct RelayOrdinaryReceiptState {
    private(set) var identity: RelayOrdinaryIdentity?
    private(set) var finalWriteSubmitted = false
    private(set) var finalWriteCompleted = false
    private(set) var received = false
    mutating func begin(_ identity: RelayOrdinaryIdentity) { precondition(self.identity == nil); self.identity = identity }
    mutating func finalSubmitted() { precondition(identity != nil); finalWriteSubmitted = true }
    mutating func finalCompleted() { precondition(finalWriteSubmitted); finalWriteCompleted = true }
    mutating func receive(_ identity: RelayOrdinaryIdentity) throws {
        guard self.identity == identity, finalWriteSubmitted, !received else { throw RelayOrdinaryError.receipt }
        received = true
    }
    var settled: Bool { identity != nil && received && finalWriteCompleted }
}

/// All native and mutable protocol state is confined to the same canonical IO
/// lane as setup/apply. Off-lane entrypoints only set lock-backed veto/coalescing
/// flags and enqueue a bounded turn. The socket completion retains its envelope;
/// retirement never manufactures write settlement or returns that charge early.
final class RelayOrdinaryConnection: @unchecked Sendable {
    private let socket: WebSocket, revocation: RevocationFlag
    private let key: String
    private let budget: RelayOrdinaryBudget
    private var endpoint: RelayOrdinaryBudget.Charge?
    private let stopped = RevocationFlag()
    private let retirementQueued = NIOLockedValueBox(false)
    private let onRefusal: @Sendable () -> Void
    private let queuedWake = NIOLockedValueBox(false)
    private var owner: Lattice?
    private let modelAuthorization: RelayOrdinaryModelAuthorization?
    private let observeChanges: Bool
    private var selectedModels: RelayOrdinaryModelSelection?
    private var pendingModelOffer: (request: String, profile: String)?
    private var modelOfferWriting = false, modelOfferCompleted = false
    // One finite UUID only, bounded by the already charged endpoint count (64).
    // A request racing the actual model-offer write callback is not a cut or
    // upload authorization. It advances only after BOTH original send witnesses.
    private enum PendingEffect { case scalar(String), history(String) }
    private var pendingEffectRequest: PendingEffect?
    private var historyProducer: RelayOrdinaryHistoryProducer?
    private var observation: AnyCancellable?
    private var capacityObservation: AnyCancellable?
    private let queuedCapacityWake = NIOLockedValueBox(false)
    private var nativeWaiting = false
    private var export: OwnedOrdinarySyncExport?
    private var cutCharge: RelayOrdinaryBudget.Charge?
    private var receipt = RelayOrdinaryReceiptState()
    private var issuedPhysicalImage: RelayOrdinaryPhysicalImage?
    private let negotiationAccepted = NIOLockedValueBox(false)
    private var dirty = false, writing = false
    private var nextFrame = 0
    private var pendingCut: RelayOrdinaryAdmission.Request?
    private var pendingFrame: RelayOrdinaryAdmission.Request?
    private let ingressWait = RelayOrdinaryAdmissionSlot()
    private var pendingOffer: String?
    private var scalarEffectRequested = false
    private var originalEffectOffer: Envelope?
    // A queue timeout is a refusal, never completed work. Active native/send
    // ownership is not revoked by it; those owners keep their real witnesses.
    private var cutTimeout: Scheduled<Void>?, frameTimeout: Scheduled<Void>?
    private static let admissionWait: TimeAmount = .seconds(30)

    // Called on the IO lane. The endpoint charge precedes retaining the owner.
    init(lattice: Lattice, socket: WebSocket, key: String, revocation: RevocationFlag,
         modelAuthorization: RelayOrdinaryModelAuthorization? = nil,
         observeChanges: Bool = false, budget: RelayOrdinaryBudget? = nil, onRefusal: @escaping @Sendable () -> Void) throws {
        let budget = budget ?? RelayOrdinaryBudgetTesting.service(for: key) ?? .shared
        endpoint = try budget.reserve(.endpoint)
        self.budget = budget; self.owner = lattice; self.socket = socket
        self.key = key; self.revocation = revocation; self.onRefusal = onRefusal
        self.modelAuthorization = modelAuthorization; self.observeChanges = observeChanges
        try modelAuthorization?.validateUse(socket: socket, key: key, revocation: revocation)
        if observeChanges && modelAuthorization == nil {
            // The same actual discovered model set selects observation and
            // capture. Core validates root/generated table mappings. Register
            // before any request can publish the first cut, avoiding a watch
            // gap; callbacks only enqueue a coalesced IO intent.
            observation = try lattice.observeOrdinarySyncChanges { [weak self] in self?.nudge() }
        }
        capacityObservation = try Lattice.observeOrdinaryExportCapacity { [weak self] in self?.capacityReleased() }
        try RelayOrdinaryWakeRegistry.shared.register(self, key: key)
    }
    deinit { RelayOrdinaryWakeRegistry.shared.remove(self) }
    /// Invoked only after actual nonempty native acceptance, including an
    /// identical-original duplicate. This wakes sender, push mounts and other
    /// same-key mounts even when no row mutation produced an observer event.
    static func repairAfterAcceptedUpload(key: String) { RelayOrdinaryWakeRegistry.shared.wake(key: key) }

    private final class UploadEnvelope: @unchecked Sendable {
        // Event-loop confined. Both facts are required even if NIO completes a
        // failed send synchronously before socket.send returns.
        private var delivery: RelayOrdinaryUploadAcknowledgment?
        private var data: Data?
        var buffer: ByteBuffer?
        private var returned = false, completed = false
        init(_ delivery: RelayOrdinaryUploadAcknowledgment) throws {
            self.delivery = delivery
            data = try delivery.acknowledgmentData()
            buffer = ByteBuffer(data: data!)
        }
        func sendReturned() { returned = true; releaseIfSettled() }
        func sendCompleted() { completed = true; releaseIfSettled() }
        private func releaseIfSettled() {
            guard returned && completed else { return }
            buffer = nil; data = nil; delivery = nil
        }
    }
    func sendUploadAcknowledgment(_ delivery: RelayOrdinaryUploadAcknowledgment) {
        socket.eventLoop.execute {
            guard self.acceptsUploads else { return }
            let envelope: UploadEnvelope
            do { envelope = try UploadEnvelope(delivery) }
            catch {
                RelayExecutionPool.io.submitRequired(for: self.key) { self.refuse() }
                return
            }
            let promise = self.socket.eventLoop.makePromise(of: Void.self)
            defer { envelope.sendReturned() }
            promise.futureResult.whenComplete { result in
                // Real transport completion, never the synchronous send return.
                envelope.sendCompleted()
                if case .failure = result {
                    RelayExecutionPool.io.submitRequired(for: self.key) { self.refuse() }
                }
            }
            guard self.acceptsUploads else { promise.fail(RelayOrdinaryError.stopped); return }
            self.socket.send(envelope.buffer!, promise: promise)
        }
    }
    private var live: Bool { !stopped.isRevoked && !revocation.isRevoked && !socket.isClosed }
    func hasSuccessfulOriginalOffer(for issuer: RelayOrdinaryModelAuthorization, selection: RelayOrdinaryModelSelection) -> Bool {
        RelayExecutionPool.io.isExecuting(for: key) && live && modelAuthorization === issuer &&
        issuer.ownsOriginalTransport(socket: socket, key: key, revocation: revocation) &&
        selectedModels === selection && scalarEffectRequested && originalEffectOffer?.actualSuccessfulEnding == true &&
        (pendingFrame == nil || pendingFrame?.expired == false) && (pendingCut == nil || pendingCut?.expired == false)
    }
    func hasCurrentAdmittedOriginal(for issuer: RelayOrdinaryModelAuthorization) -> Bool {
        guard let selection = selectedModels else { return false }
        return hasSuccessfulOriginalOffer(for: issuer, selection: selection)
    }
    // Read at the actual admitted apply operation, not when ingress is queued.
    var acceptsUploads: Bool { live && negotiationAccepted.withLockedValue { $0 } }

    // Owning IO only. The history producer receives this same immutable issuer
    // value at effect admission, never a profile string or reconstructed model list.
    func modelSelectionForEffect() throws -> RelayOrdinaryModelSelection {
        guard RelayExecutionPool.io.isCurrentWorker, live, let selectedModels else { throw RelayOrdinaryError.control }
        try selectedModels.withCurrentOwner { _, _ in () }
        return selectedModels
    }
    func modelSelectionForUpload() throws -> RelayOrdinaryModelSelection? {
        guard RelayExecutionPool.io.isCurrentWorker, acceptsUploads else { throw RelayOrdinaryError.control }
        if modelAuthorization == nil { return nil } // Existing direct legacy fixtures only.
        return try modelSelectionForEffect()
    }
    private func selectModels(_ identifier: String?) throws {
        guard selectedModels == nil, let owner, let modelAuthorization else { throw RelayOrdinaryError.control }
        let selection = try modelAuthorization.resolve(identifier: identifier, owner: owner, key: key)
        // Native validates the closed schema and real physical tables. Observer
        // installation precedes the first capture, on the SAME owning IO lane.
        if observeChanges {
            observation = try selection.withCurrentOwner { lattice, models in
                try lattice.observeOrdinarySyncChanges(models: models) { [weak self] in self?.nudge() }
            }
        }
        selectedModels = selection
    }
    private func acceptEffectRequest(_ request: String) throws {
        guard historyProducer == nil, !scalarEffectRequested, !negotiationAccepted.withLockedValue({ $0 }), !writing, export == nil else { throw RelayOrdinaryError.control }
        if modelAuthorization != nil && selectedModels == nil { try selectModels(nil) }
        if selectedModels?.profileIdentifier.isEmpty == false {
            guard modelOfferCompleted else { throw RelayOrdinaryError.control }
        }
        scalarEffectRequested = true; dirty = true
        pendingOffer = request
        requestFrameCapacity()
    }

    private func acceptHistoryEffectRequest(_ request: String, relationRequested: Bool = false) throws {
        guard historyProducer == nil, !scalarEffectRequested, !negotiationAccepted.withLockedValue({ $0 }), !writing,
              export == nil, let endpoint else { throw RelayOrdinaryError.control }
        if modelAuthorization != nil && selectedModels == nil { try selectModels(nil) }
        let selection = try modelSelectionForEffect() // Actual authenticated factory only.
        if !selection.profileIdentifier.isEmpty { guard modelOfferCompleted else { throw RelayOrdinaryError.control } }
        let producer = try RelayOrdinaryHistoryProducer(socket: socket, key: key, revocation: revocation,
            budget: budget, endpoint: endpoint, modelSelection: selection, request: request, relationRequested: relationRequested,
            onRefusal: { [weak self] in self?.refuse() })
        historyProducer = producer; dirty = false
        // History effect never enables original uploads. modelOffer alone did
        // not enable them either; original scalar/ACK/RESULT bytes remain exact.
        producer.begin()
    }
    func receive(_ control: RelayOrdinaryControl) async {
        // The existing input/request admission remains charged until this IO
        // turn returns. Decoded controls cannot accumulate an uncharged queue
        // behind a busy native lane. This never waits for a socket write.
        await withCheckedContinuation { continuation in
            RelayExecutionPool.io.submitRequired(for: key) {
                self.consume(control)
                continuation.resume()
            }
        }
    }
    func nudge() {
        guard !stopped.isRevoked else { return }
        let submit = queuedWake.withLockedValue { value in
            if value { return false }; value = true; return true
        }
        guard submit else { return }
        RelayExecutionPool.io.submitRequired(for: key) {
            self.queuedWake.withLockedValue { $0 = false }
            guard self.live else { self.releaseNative(); return }
            self.dirty = true
            self.startIfReady()
        }
    }
    func retire() {
        stopped.revoke() // Immediate publication veto; never waits on the IO queue.
        ingressWait.stop() // Cancel outside every registry/account mutex.
        let submit = retirementQueued.withLockedValue { value in
            if value { return false }; value = true; return true
        }
        guard submit else { return }
        RelayExecutionPool.io.submitRequired(for: key) { self.releaseNative() }
    }
    private func releaseNative() {
        // Always on canonical IO, before dropping the actual backend owner.
        // Already-admitted callbacks see stopped/revoked and cannot publish.
        RelayOrdinaryWakeRegistry.shared.remove(self)
        ingressWait.stop()
        let cut = pendingCut, frame = pendingFrame
        pendingCut = nil; pendingFrame = nil; pendingOffer = nil
        pendingModelOffer = nil; pendingEffectRequest = nil
        cutTimeout?.cancel(); cutTimeout = nil; frameTimeout?.cancel(); frameTimeout = nil
        cut?.cancel(); frame?.cancel()
        capacityObservation?.cancel(); capacityObservation = nil; nativeWaiting = false
        observation?.cancel(); observation = nil
        historyProducer?.retire(); historyProducer = nil
        export = nil; cutCharge = nil; selectedModels = nil; owner = nil
        receipt = .init(); dirty = false
        if !writing { endpoint = nil }
    }
    private func refuse() {
        stopped.revoke(); releaseNative()
        onRefusal() // Seals ingress and vetoes queued native applies as well.
        socket.eventLoop.execute {
            self.socket.pingInterval = .seconds(5)
            self.socket.close(code: .policyViolation, promise: nil)
        }
    }
    private func consume(_ control: RelayOrdinaryControl) {
        guard live else { releaseNative(); return }
        do {
            switch control {
            case .modelRequest(let request, let profile):
                guard !negotiationAccepted.withLockedValue({ $0 }), !writing, pendingFrame == nil,
                      historyProducer == nil, export == nil, selectedModels == nil, pendingModelOffer == nil else { throw RelayOrdinaryError.control }
                try selectModels(profile)
                pendingModelOffer = (request, profile)
                requestFrameCapacity()
            case .request(let request):
                if modelOfferWriting {
                    guard pendingEffectRequest == nil, !negotiationAccepted.withLockedValue({ $0 }),
                          selectedModels?.profileIdentifier.isEmpty == false else { throw RelayOrdinaryError.control }
                    pendingEffectRequest = .scalar(request)
                } else { try acceptEffectRequest(request) }
            case .historyRelationRequest(let request):
                guard historyProducer == nil else { throw RelayOrdinaryError.control }
                try acceptHistoryEffectRequest(request, relationRequested: true)
            case .historyRequest(let request):
                guard historyProducer == nil else { throw RelayOrdinaryError.control }
                if modelOfferWriting {
                    guard pendingEffectRequest == nil, !negotiationAccepted.withLockedValue({ $0 }),
                          selectedModels?.profileIdentifier.isEmpty == false else { throw RelayOrdinaryError.control }
                    pendingEffectRequest = .history(request)
                } else { try acceptHistoryEffectRequest(request) }
            case .historyProgress(let progress):
                guard let historyProducer else { throw RelayOrdinaryError.control }
                try historyProducer.receive(progress)
            case .receipt(let identity):
                guard historyProducer == nil else { throw RelayOrdinaryError.control }
                try receipt.receive(identity)
                settleIfReady()
            }
        } catch { refuse() }
    }
    /// Await before entering the per-file apply service. The caller retains its
    /// charged RelayIngressFrame and allocates no native/Data result while queued.
    func reserveInputStaging() async throws -> RelayOrdinaryBudget.Charge {
        try await reserveInput { completion in self.budget.request(.staging, completion) }
    }
    func reserveInputNativeTurn() async throws -> RelayOrdinaryAdmission.Lease {
        try await reserveInput { completion in RelayOrdinaryAdmission.nativeIntake.request(.cut, completion) }
    }
    private func reserveInput<Value: Sendable>(
        _ makeRequest: (@escaping @Sendable (Result<Value, RelayOrdinaryAdmission.Failure>) -> Void) -> RelayOrdinaryAdmission.Request
    ) async throws -> Value {
        try await withTaskCancellationHandler {
            guard live, !Task.isCancelled else { throw RelayOrdinaryError.stopped }
            let requestBox = NIOLockedValueBox<RelayOrdinaryAdmission.Request?>(nil)
            let timerBox = NIOLockedValueBox<Scheduled<Void>?>(nil)
            defer {
                let request = requestBox.withLockedValue { value in let old = value; value = nil; return old }
                if let request { ingressWait.clear(request) }
                let timer = timerBox.withLockedValue { value in let old = value; value = nil; return old }
                timer?.cancel()
            }
            let charge = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
                let request = makeRequest { result in
                    switch result {
                    case .success(let charge): continuation.resume(returning: charge)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
                requestBox.withLockedValue { $0 = request }
                timerBox.withLockedValue { $0 = socket.eventLoop.scheduleTask(in: Self.admissionWait) { request.cancel() } }
                if ingressWait.install(request) { request.begin() }
            }
            guard live, !Task.isCancelled else { throw RelayOrdinaryError.stopped }
            guard requestBox.withLockedValue({ $0?.expired == false }) else { throw RelayOrdinaryAdmission.Failure.timedOut }
            return charge
        } onCancel: { self.ingressWait.stop() }
    }
    private func startIfReady() {
        guard live else { releaseNative(); return }
        guard negotiationAccepted.withLockedValue({ $0 }), pendingOffer == nil,
              dirty, !writing, export == nil, cutCharge == nil, pendingCut == nil else { return }
        let request = budget.request(.cut) { [weak self] result in
            guard let self else { return }
            RelayExecutionPool.io.submitRequired(for: self.key) {
                guard self.live else { self.releaseNative(); return }
                guard case .success(let charge) = result else { self.refuse(); return }
                self.cutCharge = charge
                self.captureWithCapacity()
            }
        }
        pendingCut = request
        cutTimeout = socket.eventLoop.scheduleTask(in: Self.admissionWait) { [weak self, weak request] in
            guard let self, let request else { return }
            RelayExecutionPool.io.submitRequired(for: self.key) {
                // A canceled timer can already have enqueued its IO turn. It
                // must never refuse a later ticket on this same connection.
                if self.pendingCut === request { self.refuse() }
            }
        }
        request.begin()
    }
    private func capacityReleased() {
        guard !stopped.isRevoked else { return }
        let submit = queuedCapacityWake.withLockedValue { value in if value { return false }; value = true; return true }
        guard submit else { return }
        RelayExecutionPool.io.submitRequired(for: key) {
            self.queuedCapacityWake.withLockedValue { $0 = false }
            guard self.live else { self.releaseNative(); return }
            if self.nativeWaiting { self.captureWithCapacity() }
        }
    }
    private func captureWithCapacity() {
        guard live, cutCharge != nil, export == nil else { return }
        guard let pendingCut, !pendingCut.expired else { refuse(); return }
        do {
            guard let owner else { throw RelayOrdinaryError.stopped }
            let captured: OwnedOrdinarySyncExport
            if let selectedModels {
                captured = try selectedModels.withCurrentOwner { lattice, models in try lattice.captureOrdinarySyncExport(models: models) }
            } else {
                guard modelAuthorization == nil else { throw RelayOrdinaryError.control }
                captured = try owner.captureOrdinarySyncExport()
            }
            nativeWaiting = false; self.pendingCut = nil; cutTimeout?.cancel(); cutTimeout = nil
            export = captured; dirty = false; nextFrame = 0
            sendNext()
        } catch OrdinarySyncExportError.exportCapacity {
            // Register-before-capture closes the missed-release window. A hint
            // queues a later IO turn; no polling, IO sleep or repeated SQL.
            nativeWaiting = true
        } catch { refuse() }
    }
    private func sendNext() {
        guard live else { releaseNative(); return }
        guard !writing, let export, nextFrame < export.frameCount else { return }
        requestFrameCapacity()
    }
    private func requestFrameCapacity() {
        guard live, !writing, pendingFrame == nil else { return }
        let request = budget.request(.staging) { [weak self] result in
            guard let self else { return }
            RelayExecutionPool.io.submitRequired(for: self.key) {
                let expired = self.pendingFrame?.expired != false
                self.pendingFrame = nil; self.frameTimeout?.cancel(); self.frameTimeout = nil
                guard self.live else { self.releaseNative(); return }
                guard !expired, case .success(let charge) = result else { self.refuse(); return }
                self.prepareFrame(charge)
            }
        }
        pendingFrame = request
        frameTimeout = socket.eventLoop.scheduleTask(in: Self.admissionWait) { request.cancel() }
        request.begin()
    }
    private func prepareFrame(_ charge: RelayOrdinaryBudget.Charge) {
        guard live, !writing else { releaseNative(); return }
        do {
            if let offer = pendingModelOffer {
                pendingModelOffer = nil
                let bytes = try JSONSerialization.data(withJSONObject: ["latticeOrdinarySync": ["version": 2, "kind": "modelOffer", "request": offer.request, "modelProfile": offer.profile]])
                modelOfferWriting = true
                send(bytes, charge: charge, final: false, offer: false, modelOffer: true)
                return
            }
            if let request = pendingOffer {
                pendingOffer = nil
                let bytes = try JSONSerialization.data(withJSONObject: ["latticeOrdinarySync": ["version": 2, "kind": "offer", "request": request, "uploadObservation": 1, "uploadAcknowledgment": 1]])
                send(bytes, charge: charge, final: false, offer: true)
                return
            }
            guard let export, nextFrame < export.frameCount else { throw RelayOrdinaryError.stopped }
            let bytes = try export.frame(at: nextFrame) // Only after the actual staging grant.
            if nextFrame == 0 {
                guard let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      let body = root["latticeOrdinarySync"] as? [String: Any],
                      body["kind"] as? String == "cut", body["version"] as? Int == 2 else { throw RelayOrdinaryError.header }
                let identity = try RelayOrdinaryIdentity(body)
                let physical = try RelayOrdinaryPhysicalImage(body, identity: identity)
                if let original = issuedPhysicalImage, original != physical { throw RelayOrdinaryError.header }
                issuedPhysicalImage = physical
                receipt.begin(identity)
            }
            nextFrame += 1
            let final = nextFrame == export.frameCount
            if final { receipt.finalSubmitted() }
            send(bytes, charge: charge, final: final, offer: false)
        } catch { refuse() }
    }
    private final class Envelope: @unchecked Sendable {
        // Fence state is event-loop confined. A synchronous promise callback
        // can run inside send(), so completion alone cannot release its live
        // ByteBuffer argument. Payload disposal stays on canonical IO, after
        // both facts: no event-loop payload access follows that handoff.
        private var data: Data?
        private(set) var buffer: ByteBuffer?
        private var charge: RelayOrdinaryBudget.Charge?
        private var returned = false, settled = false
        private var completion: Result<Void, Error>?
        private(set) var actualSuccessfulEnding: Bool?
        init(_ data: Data, _ charge: RelayOrdinaryBudget.Charge) {
            self.data = data; self.charge = charge
            // Independent transport bytes: never lend native or Data storage.
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data); self.buffer = buffer
        }
        func sendReturned() -> Result<Void, Error>? {
            returned = true
            return releaseIfSettled()
        }
        func sendCompleted(_ result: Result<Void, Error>) -> Result<Void, Error>? {
            precondition(completion == nil && !settled)
            completion = result
            return releaseIfSettled()
        }
        private func releaseIfSettled() -> Result<Void, Error>? {
            guard returned, !settled, let completion else { return nil }
            settled = true; self.completion = nil
            if case .success = completion { actualSuccessfulEnding = true } else { actualSuccessfulEnding = false }
            // Retirement, socket close and elapsed time do not enter this fence.
            return completion
        }
        func releasePayload() {
            // Canonical IO only, after the event-loop's final payload access and
            // the preceding prepareFrame turn/captures have actually retired.
            data = nil; buffer = nil; charge = nil
        }
    }
    private func send(_ bytes: Data, charge: RelayOrdinaryBudget.Charge, final: Bool, offer: Bool, modelOffer: Bool = false) {
        precondition(!writing && bytes.count <= 4_194_304)
        guard !offer || originalEffectOffer == nil else { refuse(); return }
        writing = true
        let envelope = Envelope(bytes, charge)
        if offer {
            originalEffectOffer = envelope // SAME actual return/completion witness.
        }
        socket.eventLoop.execute {
            let promise = self.socket.eventLoop.makePromise(of: Void.self)
            let finish: @Sendable (Result<Void, Error>) -> Void = { result in
                RelayExecutionPool.io.submitRequired(for: self.key) {
                    envelope.releasePayload() // Actual completion AND send return.
                    self.writing = false
                    guard self.live else { self.releaseNative(); return }
                    guard case .success = result else { self.refuse(); return }
                    if modelOffer {
                        self.modelOfferWriting = false; self.modelOfferCompleted = true
                        if let request = self.pendingEffectRequest {
                            self.pendingEffectRequest = nil
                            do {
                                switch request {
                                case .scalar(let request): try self.acceptEffectRequest(request)
                                case .history(let request): try self.acceptHistoryEffectRequest(request)
                                }
                            } catch { self.refuse() }
                        }
                    } else if offer {
                        do {
                            if let selection = self.selectedModels { try selection.admitOriginalScalarOffer(self) }
                            else { guard self.modelAuthorization == nil else { throw RelayOrdinaryError.control } }
                            self.negotiationAccepted.withLockedValue { $0 = true }
                            self.startIfReady()
                        } catch { self.refuse() }
                    }
                    else if final { self.receipt.finalCompleted(); self.settleIfReady() }
                    else { self.sendNext() }
                }
            }
            // Also covers the pre-send live veto: promise.fail() is a genuine
            // completion and this scope then returns without making a write.
            defer { if let result = envelope.sendReturned() { finish(result) } }
            promise.futureResult.whenComplete { result in
                if let result = envelope.sendCompleted(result) { finish(result) }
            }
            guard self.live else { promise.fail(RelayOrdinaryError.stopped); return }
            self.socket.send(envelope.buffer!, promise: promise)
        }
    }
    private func settleIfReady() {
        guard receipt.settled else { return }
        export = nil; cutCharge = nil; receipt = .init()
        startIfReady() // At most one coalesced later intent, no payload queue.
    }
}
