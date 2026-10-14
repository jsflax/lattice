import Foundation
import CoreFoundation
import Vapor
@_spi(LatticeServer) import Lattice
import NIOConcurrencyHelpers
#if canImport(Combine)
import Combine
#endif

/// Passive peer progress, never a receipt or source/route/currentness issuer.
/// Decoding happens only after the owning ordinary control duplicate-key scan.
struct RelayOrdinaryHistoryProgress: Sendable, Equatable {
    let source, epoch, cut, stage: String
    let nextPage: Int
    let previousDigest: String
    let stagedComplete: Bool
    init(_ body: [String: Any]) throws {
        guard Set(body.keys) == ["version", "profile", "kind", "source", "epoch", "cut", "stage", "nextPage", "previousDigest", "stagedComplete"],
              let version = body["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.stringValue == "2",
              body["profile"] as? String == "paged-history-v1",
              body["kind"] as? String == "historyProgress" else { throw RelayOrdinaryError.control }
        func uuid(_ key: String) throws -> String {
            guard let text = body[key] as? String, text.utf8.count == 36,
                  UUID(uuidString: text) != nil else { throw RelayOrdinaryError.control }
            return text
        }
        func decimal(_ key: String, positive: Bool) throws -> String {
            guard let text = body[key] as? String, text.utf8.count <= 19,
                  let number = Int64(text), number >= (positive ? 1 : 0), String(number) == text else { throw RelayOrdinaryError.control }
            return text
        }
        source = try uuid("source"); stage = try uuid("stage")
        epoch = try decimal("epoch", positive: true); cut = try decimal("cut", positive: true)
        let next = try decimal("nextPage", positive: false)
        guard let page = Int(next), page <= 65_536,
              let digest = body["previousDigest"] as? String,
              digest.isEmpty || (digest.utf8.count == 64 && digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })),
              let complete = body["stagedComplete"] as? NSNumber,
              CFGetTypeID(complete) == CFBooleanGetTypeID() else { throw RelayOrdinaryError.control }
        nextPage = page; previousDigest = digest; stagedComplete = complete.boolValue
    }
}

/// Owns only one genuine history export on the existing canonical IO lane.
/// Authenticated typed model selection is supplied by the actual owning mount
/// factory; a wire effect/profile or copied progress cannot construct it.
final class RelayOrdinaryHistoryProducer: @unchecked Sendable {
    private let socket: WebSocket, key: String, revocation: RevocationFlag
    private let budget: RelayOrdinaryBudget
    // Real endpoint charge is retained through outstanding send callbacks, even
    // after the owning connection drops its ordinary state on retirement.
    private let endpoint: RelayOrdinaryBudget.Charge
    private var modelSelection: RelayOrdinaryModelSelection?
    private let onRefusal: @Sendable () -> Void
    private let stopped = RevocationFlag()
    private var capacityObservation: AnyCancellable?
    private let queuedCapacityWake = NIOLockedValueBox(false)
    private var nativeWaiting = false
    private var export: OwnedOrdinaryHistoryExport?
    private var cutCharge: RelayOrdinaryBudget.Charge?
    private var pendingCut: RelayOrdinaryAdmission.Request?, pendingFrame: RelayOrdinaryAdmission.Request?
    private var cutTimer: Scheduled<Void>?, frameTimer: Scheduled<Void>?, episodeTimer: Scheduled<Void>?
    private var episodeDeadline: NIODeadline?
    private var originalEffectOffer: Envelope?
    private var offer: String?
    private let request: String, relationRequested: Bool
    private var relationSent = false
    private var writing = false, offered = false, stagedComplete = false
    private var index = 0
    private struct Expected {
        let source, epoch, cut, stage: String
        let nextPage: Int, previousDigest: String
        let complete: Bool
        func matches(_ progress: RelayOrdinaryHistoryProgress) -> Bool {
            source == progress.source && epoch == progress.epoch && cut == progress.cut && stage == progress.stage &&
            nextPage == progress.nextPage && previousDigest == progress.previousDigest && complete == progress.stagedComplete
        }
    }
    private var expected: Expected?
    private var progressReceived = false, writeCompleted = false
    private static let admissionWait: TimeAmount = .seconds(30)

    init(socket: WebSocket, key: String, revocation: RevocationFlag,
         budget: RelayOrdinaryBudget, endpoint: RelayOrdinaryBudget.Charge, modelSelection: RelayOrdinaryModelSelection,
         request: String, relationRequested: Bool = false, onRefusal: @escaping @Sendable () -> Void) throws {
        self.socket = socket; self.key = key; self.revocation = revocation
        self.budget = budget; self.endpoint = endpoint; self.modelSelection = modelSelection; self.offer = request; self.onRefusal = onRefusal
        self.request = request; self.relationRequested = relationRequested
        guard RelayExecutionPool.io.isCurrentWorker else { throw RelayOrdinaryError.control }
        if relationRequested { _ = try modelSelection.historyRelationRoute() }
        // Register-before-capture; this is only a retry hint, never SQL/authority.
        capacityObservation = try Lattice.observeOrdinaryExportCapacity { [weak self] in self?.capacityReleased() }
    }
    private var live: Bool {
        !stopped.isRevoked && !revocation.isRevoked && !socket.isClosed &&
        (episodeDeadline == nil || NIODeadline.now() < episodeDeadline!)
    }
    func hasSuccessfulOriginalOffer(for issuer: RelayOrdinaryModelAuthorization, selection: RelayOrdinaryModelSelection) -> Bool {
        RelayExecutionPool.io.isExecuting(for: key) && live && modelSelection === selection && selection.hasIssuer(issuer) &&
        issuer.ownsOriginalTransport(socket: socket, key: key, revocation: revocation) &&
        originalEffectOffer?.actualSuccessfulEnding == true &&
        (pendingCut == nil || pendingCut?.expired == false) && (pendingFrame == nil || pendingFrame?.expired == false)
    }
    func hasCurrentAdmittedOriginal(for issuer: RelayOrdinaryModelAuthorization) -> Bool {
        guard let selection = modelSelection else { return false }
        return hasSuccessfulOriginalOffer(for: issuer, selection: selection)
    }
    func begin() { precondition(RelayExecutionPool.io.isCurrentWorker); guard live else { refuse(); return }; requestFrameCapacity() }
    func receive(_ progress: RelayOrdinaryHistoryProgress) throws {
        guard RelayExecutionPool.io.isCurrentWorker, live, let modelSelection, let expected, !progressReceived, expected.matches(progress) else { throw RelayOrdinaryError.receipt }
        try modelSelection.withCurrentOwner { _, _ in () }
        progressReceived = true
        advanceIfReady()
    }
    func retire() {
        precondition(RelayExecutionPool.io.isCurrentWorker)
        stopped.revoke()
        let cut = pendingCut, frame = pendingFrame
        pendingCut = nil; pendingFrame = nil; offer = nil
        cutTimer?.cancel(); cutTimer = nil; frameTimer?.cancel(); frameTimer = nil
        episodeTimer?.cancel(); episodeTimer = nil
        cut?.cancel(); frame?.cancel()
        capacityObservation?.cancel(); capacityObservation = nil; nativeWaiting = false
        // An admitted envelope separately retains its genuine page/export/charges
        // until actual send return AND completion. Retirement is no completion.
        export = nil; cutCharge = nil; modelSelection = nil; expected = nil
    }
    private func refuse() {
        guard !stopped.isRevoked else { return }
        retire(); onRefusal()
    }
    private func requestCut() {
        guard live, offered, !writing, export == nil, pendingCut == nil else { if !live { refuse() }; return }
        let request = budget.request(.cut) { [weak self] result in
            guard let self else { return }
            RelayExecutionPool.io.submitRequired(for: self.key) {
                guard self.live else { self.refuse(); return }
                guard case .success(let charge) = result else { self.refuse(); return }
                self.cutCharge = charge; self.captureWithCapacity()
            }
        }
        pendingCut = request
        cutTimer = socket.eventLoop.scheduleTask(in: Self.admissionWait) { [weak self, weak request] in
            guard let self, let request else { return }
            RelayExecutionPool.io.submitRequired(for: self.key) { if self.pendingCut === request { self.refuse() } }
        }
        request.begin()
    }
    private func captureWithCapacity() {
        guard live, cutCharge != nil, export == nil, let pendingCut, !pendingCut.expired else { refuse(); return }
        do {
            guard let modelSelection else { throw RelayOrdinaryError.stopped }
            let captured = try modelSelection.captureCurrentMountedHistory(observingLineage: relationRequested)
            // Refuse late publication on the SAME original admission deadline;
            // this check cannot interrupt the native SQL operation itself.
            guard live, !pendingCut.expired else { throw RelayOrdinaryError.stopped }
            nativeWaiting = false; self.pendingCut = nil; cutTimer?.cancel(); cutTimer = nil
            export = captured; index = 0
            requestFrameCapacity()
        } catch OrdinarySyncExportError.exportCapacity { nativeWaiting = true }
        catch { refuse() }
    }
    private func capacityReleased() {
        guard !stopped.isRevoked else { return }
        let submit = queuedCapacityWake.withLockedValue { flag in if flag { return false }; flag = true; return true }
        guard submit else { return }
        RelayExecutionPool.io.submitRequired(for: key) {
            self.queuedCapacityWake.withLockedValue { $0 = false }
            guard self.live else { self.refuse(); return }
            if self.nativeWaiting { self.captureWithCapacity() }
        }
    }
    private func requestFrameCapacity() {
        guard live else { refuse(); return }
        guard !writing, pendingFrame == nil, expected == nil, !stagedComplete else { return }
        let request = budget.request(.staging) { [weak self] result in
            guard let self else { return }
            RelayExecutionPool.io.submitRequired(for: self.key) {
                let expired = self.pendingFrame?.expired != false
                self.pendingFrame = nil; self.frameTimer?.cancel(); self.frameTimer = nil
                guard self.live else { self.refuse(); return }
                guard !expired, case .success(let charge) = result else { self.refuse(); return }
                self.prepareFrame(charge)
            }
        }
        pendingFrame = request
        frameTimer = socket.eventLoop.scheduleTask(in: Self.admissionWait) { request.cancel() }
        request.begin()
    }
    private func prepareFrame(_ charge: RelayOrdinaryBudget.Charge) {
        guard live, !writing else { refuse(); return }
        do {
            guard let modelSelection else { throw RelayOrdinaryError.stopped }
            try modelSelection.withCurrentOwner { _, _ in () }
            if let request = offer {
                offer = nil
                // Original native history effect offer: no upload flags, model
                // names, changed canonical bytes or synthetic receipt fields.
                let bytes = try JSONSerialization.data(withJSONObject: ["latticeOrdinarySync": ["version": 2, "profile": "paged-history-v1", "kind": "offer", "request": request]])
                send(bytes, charge: charge, page: nil, offer: true)
                return
            }
            guard let export, let cutCharge, index < export.frameCount else { throw RelayOrdinaryError.stopped }
            if relationRequested && !relationSent {
                guard index == 0 else { throw RelayOrdinaryError.header }
                let route = try modelSelection.historyRelationRoute()
                let nativeBytes = try modelSelection.withCurrentOwner { _, _ in try export.mountedSourceRelationObservation() }
                guard let facts = try JSONSerialization.jsonObject(with: nativeBytes) as? [String: Any] else { throw RelayOrdinaryError.header }
                // The SAME native cut is retained through this control, header,
                // pages and passive stagedComplete wait. The actual request and
                // authenticated selection/socket supply every route fact here.
                let body: [String: Any] = ["version": 2, "profile": "paged-history-v1", "kind": "historyRelation",
                    "relation": "mounted-lineage-frontier-v1", "request": request,
                    "modelProfile": route.profile, "principal": route.principal,
                    "serverChannel": route.channel, "group": route.group.map { $0 as Any } ?? NSNull(), "facts": facts]
                let bytes = try JSONSerialization.data(withJSONObject: ["latticeOrdinarySync": body])
                guard live, bytes.count <= 262_144 else { throw RelayOrdinaryError.header }
                // Reuse this original first-frame grant after actual send return
                // AND completion. No second admission wait, page index shift,
                // peer progress expectation or negotiation/episode renewal.
                send(bytes, charge: charge, page: nil, export: export, cutCharge: cutCharge,
                     offer: false, relationContinuation: charge)
                return
            }
            if index == 0 {
                // One original300s absolute transfer episode. A canceled task
                // may already have queued its turn; no page/offer resets it.
                let deadline = NIODeadline.now() + .seconds(300)
                episodeDeadline = deadline
                episodeTimer = socket.eventLoop.scheduleTask(deadline: deadline) { [weak self] in
                    guard let self else { return }
                    RelayExecutionPool.io.submitRequired(for: self.key) { if self.episodeDeadline == deadline { self.refuse() } }
                }
            }
            let page = try modelSelection.withCurrentOwner { _, _ in try export.page(at: index) }
            let bytes = try page.data() // Actual staging8MiB grant precedes Data and ByteBuffer.
            guard live else { throw RelayOrdinaryError.stopped }
            let digest = index == 0 ? "" : SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            expected = .init(source: export.sourceID, epoch: String(export.epoch), cut: String(export.cut),
                             stage: export.stageID, nextPage: index, previousDigest: digest, complete: index + 1 == export.frameCount)
            progressReceived = false; writeCompleted = false
            send(bytes, charge: charge, page: page, export: export, cutCharge: cutCharge, offer: false)
        } catch { refuse() }
    }
    private final class Envelope: @unchecked Sendable {
        private var page: OwnedOrdinaryHistoryPage?, export: OwnedOrdinaryHistoryExport?
        private var cutCharge: RelayOrdinaryBudget.Charge?, stagingCharge: RelayOrdinaryBudget.Charge?
        private var data: Data?
        private(set) var buffer: ByteBuffer?
        private var returned = false, settled = false
        private var completion: Result<Void, Error>?
        private(set) var actualSuccessfulEnding: Bool?
        init(_ data: Data, _ charge: RelayOrdinaryBudget.Charge, page: OwnedOrdinaryHistoryPage?,
             export: OwnedOrdinaryHistoryExport?, cutCharge: RelayOrdinaryBudget.Charge?) {
            self.page = page; self.export = export; self.cutCharge = cutCharge; self.stagingCharge = charge; self.data = data
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data); self.buffer = buffer
        }
        func sendReturned() -> Result<Void, Error>? { returned = true; return releaseIfSettled() }
        func sendCompleted(_ result: Result<Void, Error>) -> Result<Void, Error>? {
            precondition(completion == nil && !settled); completion = result; return releaseIfSettled()
        }
        private func releaseIfSettled() -> Result<Void, Error>? {
            guard returned, !settled, let completion else { return nil }
            settled = true; self.completion = nil
            if case .success = completion { actualSuccessfulEnding = true } else { actualSuccessfulEnding = false }
            return completion
        }
        func releasePayload() {
            // Canonical IO after final event-loop use and prepare turn retirement.
            data = nil; buffer = nil; page = nil; export = nil; cutCharge = nil; stagingCharge = nil
        }
    }
    private func send(_ bytes: Data, charge: RelayOrdinaryBudget.Charge, page: OwnedOrdinaryHistoryPage?,
                      export: OwnedOrdinaryHistoryExport? = nil, cutCharge: RelayOrdinaryBudget.Charge? = nil, offer: Bool,
                       relationContinuation: RelayOrdinaryBudget.Charge? = nil) {
        precondition(!writing && bytes.count <= 4_194_304)
        guard !offer || originalEffectOffer == nil else { refuse(); return }
        writing = true
        let envelope = Envelope(bytes, charge, page: page, export: export, cutCharge: cutCharge)
        if offer {
            originalEffectOffer = envelope
        }
        socket.eventLoop.execute {
            let promise = self.socket.eventLoop.makePromise(of: Void.self)
            let finish: @Sendable (Result<Void, Error>) -> Void = { result in
                RelayExecutionPool.io.submitRequired(for: self.key) {
                    envelope.releasePayload()
                    self.writing = false
                    guard self.live else { self.refuse(); return }
                    guard case .success = result else { self.refuse(); return }
                    if let relationContinuation {
                        self.relationSent = true
                        self.prepareFrame(relationContinuation) // SAME grant; no extra wait or index.
                    } else if offer {
                        do {
                            guard let selection = self.modelSelection else { throw RelayOrdinaryError.stopped }
                            try selection.admitOriginalHistoryOffer(self)
                            self.offered = true; self.requestCut()
                        } catch { self.refuse() }
                    }
                    else { self.writeCompleted = true; self.advanceIfReady() }
                }
            }
            defer { if let result = envelope.sendReturned() { finish(result) } }
            promise.futureResult.whenComplete { result in if let result = envelope.sendCompleted(result) { finish(result) } }
            // Off-lane read touches only real socket/revocation publication. The
            // IO-confined episodeDeadline is checked on prepare/finish/receive.
            guard !self.stopped.isRevoked, !self.revocation.isRevoked, !self.socket.isClosed else { promise.fail(RelayOrdinaryError.stopped); return }
            self.socket.send(envelope.buffer!, promise: promise)
        }
    }
    private func advanceIfReady() {
        guard live else { refuse(); return }
        guard let expected, progressReceived, writeCompleted, !writing else { return }
        self.expected = nil
        if expected.complete {
            // Durable passive staging only. Do not issue a canonical receipt,
            // enable uploads, prune history or capture another cut. The existing
            // absolute episode still requires actual final install/retirement.
            stagedComplete = true
            return
        }
        index += 1
        requestFrameCapacity()
    }
}
