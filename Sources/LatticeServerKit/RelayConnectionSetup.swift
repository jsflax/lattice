import Foundation
import Vapor
import Lattice

/// Immutable hand-off. The schema metatypes and processing closure are the same
/// mount/connection values already crossing the existing relay's Sendable boxes.
/// Mutable native state below is accessed ONLY on its canonical per-file IO lane.
struct RelayConnectionSetupInput: @unchecked Sendable {
    let schema: [any Lattice.Model.Type]
    let storageURL: URL
    let fileURL: URL?
    let applyKey: String
    let channel: SyncChannel
    let recoverySource: RecoveryRelayResolvedSource?
    let socket: WebSocket
    let state: ConnectionRelayState
    let sockets: SocketManager
    let watchManager: FileWatchManager?
    let pushContext: MountPushContext?
    let storeConfiguration: (@Sendable (URL) -> Lattice.Configuration)?
    let lastEventId: UUID?
    let processFrame: @Sendable (WebSocket, RelayIngressFrame, Lattice) async -> Void
    let diagnostic: ACKPathConnection?
    let sendCatchUp: (@Sendable (WebSocket, Data, EventLoopPromise<Void>) -> Void)?
    let didFinish: @Sendable () -> Void
    let didObserveRecoverySetup: (@Sendable (RelaySetupAdmissionObservation) -> Void)?
    let didOpenRecoverySetupOwnerForTesting: (@Sendable (Lattice) -> Void)?
}

private enum RelayAutomaticSetupStep: Sendable {
    case busy(until: UInt64)
    case opened(RecoveryRelayAuthorizationTurn)
    case failed(any Error)
}

private enum RelayCatchUpStep: Sendable {
    case stopped
    case floor(Data)
    case page(Data, count: Int, last: Int64?)
    case finished(emptyBoundary: Int64?)
    case failed(any Error)
}

/// Native owner and the SAME results/count for an entire catch-up. No model or
/// query facade crosses into a control callback; only copied bytes and scalars do.
private final class RelayCatchUpReadState {
    // Catch-up and apply share one synchronous turn per channel file. Yield
    // between smaller pages so one history page does not monopolize that lane.
    // This bounds entries per turn, not elapsed time or encoded bytes; one
    // large entry and managed-field encoding still need their full lifetime.
    // 100 also aligns with the existing legacy ACK mutation chunk.
    private static let entriesPerTurn = 100
    let lattice: Lattice
    private let input: RelayConnectionSetupInput
    private var checkedFloor = false
    private var events: TableResults<AuditLog>?
    private var count = 0
    private var offset = 0
    var automaticRoute: RecoveryRelayAutomaticRoute? // frozen once on this IO lane
    var hasSubscription = false
    let probe: ObserverSendBoundaryProbe?

    init(lattice: Lattice, input: RelayConnectionSetupInput, probe: ObserverSendBoundaryProbe?) {
        self.lattice = lattice
        self.input = input
        self.probe = probe
    }

    func next(pageSpan: UInt64) -> RelayCatchUpStep {
        // Body return precedes capture destruction and the pool's lane release.
        defer { input.diagnostic?.record(.catchUpPageBodyReturned, span: pageSpan) }
        guard !input.socket.isClosed, !input.state.revocation.isRevoked else { return .stopped }
        do {
            if !checkedFloor {
                checkedFloor = true
                // Preserve the fault seam after parked publication and go-live,
                // before floor output or the first catch-up snapshot.
                if let fault = _catchUpFaultForTesting.withLockedValue({ $0 }) {
                    try fault(input.channel.id)
                }
                if let claimed = input.lastEventId, let url = input.fileURL {
                    let floorSuspect = DurableHeadLedger.shared.bootCheck(lattice: lattice, storePath: url.path)
                    let known = !lattice.objects(AuditLog.self).where { $0.globalId == claimed }
                        .snapshot(limit: 1).isEmpty
                    if !known {
                        let head = lattice.objects(AuditLog.self)
                            .sortedBy(\.primaryKey, order: .reverse).snapshot(limit: 1).first
                        let reason = floorSuspect
                            ? "server lost history (durable head regressed at boot)"
                            : "client floor unknown to this channel"
                        relayLog.error("""
                            FLOOR VIOLATION: channel=\(input.channel.id) user=\(input.channel.userId) \
                            claimed=\(claimed) durableHead=\(head?.globalId?.uuidString ?? "nil") \
                            — \(reason); serving explicit full-history replay
                            """)
                        if let encoded = try? JSONEncoder().encode(
                            ServerSentEvent.floorReset(durableHead: head?.globalId, reason: reason)) {
                            return .floor(encoded)
                        }
                    }
                }
            }
            if events == nil {
                input.diagnostic?.record(.catchUpReadBegin, span: pageSpan)
                let captured = lattice.eventsAfter(globalId: input.lastEventId)
                count = captured.count
                events = captured
                input.diagnostic?.record(.catchUpReadEnd, span: pageSpan, count: count)
                if count > 0 {
                    print(">>> Bringing channel \(input.channel.id) connection up to date with \(count) events")
                }
            }
            guard let events else { preconditionFailure("catch-up query was not initialized") }
            if offset < count {
                let end = offset + min(count - offset, Self.entriesPerTurn)
                let page: [AuditLog]
                let sampledLast: Int64?
                if let diagnostic = input.diagnostic {
                    diagnostic.record(.catchUpPageMaterializeBegin, span: pageSpan, count: end - offset)
                    let materialized = Array(events[offset..<end])
                    diagnostic.record(.catchUpPageMaterializeEnd, span: pageSpan, count: materialized.count)
                    sampledLast = materialized.last?.primaryKey
                    page = lattice.lateBindNoHistory(input.state.revocation.filterRecoveryPage(materialized))
                    diagnostic.record(.catchUpPageBindingEnd, span: pageSpan, count: page.count)
                } else {
                    let materialized = Array(events[offset..<end])
                    sampledLast = materialized.last?.primaryKey
                    page = lattice.lateBindNoHistory(input.state.revocation.filterRecoveryPage(materialized))
                }
                let encoded = try JSONEncoder().encode(ServerSentEvent.auditLog(page))
                input.diagnostic?.record(.catchUpPageEncodingEnd, span: pageSpan,
                                          bytes: encoded.count, count: page.count)
                probe?.capture(page: page, route: .catchup)
                let last = input.state.recovery == nil ? page.last?.primaryKey : sampledLast
                offset = end
                return .page(encoded, count: page.count, last: last)
            }
            if count == 0, let lastEventId = input.lastEventId, hasSubscription {
                let boundary = lattice.objects(AuditLog.self)
                    .where { $0.globalId == lastEventId }
                    .snapshot(limit: 1).first?.primaryKey ?? 0
                return .finished(emptyBoundary: boundary)
            }
            return .finished(emptyBoundary: nil)
        } catch { return .failed(error) }
    }
}

/// One connection's setup and catch-up. Every transition is a synchronous control
/// turn. In-flight IO/event-loop/promise callbacks keep this owner alive; it has
/// no self lease or reference from the socket state, hence no idle owner cycle.
/// This does not move the external extractor or the existing async apply consumer.
@RelayControlActor final class RelayConnectionSetup {
    private enum Phase { case initial, opening, authorizingRecovery, subscribing, goLive, reading, sending, finishing, finished }
    private let input: RelayConnectionSetupInput
    private var phase = Phase.initial
    private var native: UnsafeSendableBox<RelayCatchUpReadState>?
    private var boundary: Int64 = 0
    private var subscription: PushSubscription?
    private var authorizationWork: RecoveryRelayAuthorizationWork?
    private var setupWork: RecoveryRelaySetupWork?
    private var setupStop: RecoveryRelaySetupStopObservation?
    private var admission: RelaySetupAdmission?
    private var admissionTimer: RelaySetupAdmissionTimer?
    private var admissionIO = false
    private var admissionObserver: (@Sendable (RelaySetupAdmissionObservation) -> Void)?

    init(input: RelayConnectionSetupInput) { self.input = input }

    func start() {
        guard phase == .initial else { return }
        input.state.nativeReleaseKey = input.applyKey
        input.state.channelId = input.channel.id
        input.diagnostic?.record(.registryAddBegin)
        input.sockets.add(socket: input.socket, channelId: input.channel.id,
                          userId: input.channel.userId, revocation: input.state.revocation)
        input.diagnostic?.record(.registryAddEnd)
        guard isLive else {
            input.diagnostic?.record(.closedDuringSetup)
            input.sockets.remove(socket: input.socket, channelId: input.channel.id)
            finish(); return
        }
        phase = .opening
        let input = input
        let probe: ObserverSendBoundaryProbe?
        if let candidate = input.pushContext?.options._sendBoundaryProbeForTesting,
           candidate.channelID == input.channel.id { probe = candidate }
        else { probe = nil }
        if let recovery = input.state.recovery {
            startAutomatic(recovery, probe: probe)
            return
        }
        RelayExecutionPool.io.submitRequired(for: input.applyKey) {
            try? FileManager.default.createDirectory(at: input.storageURL, withIntermediateDirectories: true)
            let configuration = SyncRelayApplyPolicy.configuration(
                fileURL: input.fileURL, storeConfiguration: input.storeConfiguration)
            input.diagnostic?.record(.storeOpenBegin)
            let opened: UnsafeSendableBox<RelayCatchUpReadState>?
            let turn: RecoveryRelayAuthorizationTurn?
            do {
                let lattice = try Lattice(isolation: nil, for: input.schema, configuration: configuration)
                if let recovery = input.state.recovery {
                    guard let source = input.recoverySource else { throw SyncRecoveryConfigurationError.staleAuthorization }
                    turn = try recovery.open(owner: lattice, channel: input.channel, source: source)
                } else { turn = nil }
                opened = UnsafeSendableBox(RelayCatchUpReadState(lattice: lattice, input: input, probe: probe))
                input.diagnostic?.record(.storeOpenEnd)
            } catch {
                opened = nil; turn = nil
                input.diagnostic?.record(.storeOpenFailure)
            }
            Task { @RelayControlActor in self.opened(opened, turn: turn, probe: probe) }
        }
    }

    private func startAutomatic(_ recovery: RecoveryRelayConnection, probe: ObserverSendBoundaryProbe?) {
        let work: RecoveryRelaySetupWork
        do { work = try recovery.reserveSetup(for: input.applyKey) }
        catch { fail(error); return }
        setupWork = work
        let observer = input.didObserveRecoverySetup
        admissionObserver = observer
        let admission = RelaySetupAdmission()
        self.admission = admission
        let stop = RecoveryRelaySetupStopObservation { [weak self, work, admission] in
            admission.cancel() // Immediate veto, even if control/IO is queued.
            Task { @RelayControlActor [weak self, work] in
                defer { withExtendedLifetime(work) {} }
                self?.automaticStopped()
            }
        }
        setupStop = stop
        recovery.lifetime.observeSetupStop(stop)
        admissionIO = true
        let input = input
        RelayExecutionPool.io.submitRequired(for: input.applyKey) { [work] in
            defer { withExtendedLifetime(work) {} }
            let opened: UnsafeSendableBox<RelayCatchUpReadState>?
            do {
                guard !admission.isCancelled, !input.socket.isClosed, !input.state.revocation.isRevoked else {
                    throw SyncRecoveryConfigurationError.staleAuthorization
                }
                try? FileManager.default.createDirectory(at: input.storageURL, withIntermediateDirectories: true)
                let configuration = SyncRelayApplyPolicy.configuration(
                    fileURL: input.fileURL, storeConfiguration: input.storeConfiguration)
                input.diagnostic?.record(.storeOpenBegin)
                let lattice = try Lattice(isolation: nil, for: input.schema, configuration: configuration)
                guard let source = input.recoverySource else { throw SyncRecoveryConfigurationError.staleAuthorization }
                let state = RelayCatchUpReadState(lattice: lattice, input: input, probe: probe)
                state.automaticRoute = try recovery.automaticRoute(channel: input.channel, source: source)
                // Test-only synchronous borrow, off locks; it cannot replace the
                // owner/route/result. Real mutex holding lives in a test target.
                input.didOpenRecoverySetupOwnerForTesting?(lattice)
                opened = UnsafeSendableBox(state)
                observer?(.init(connectionID: recovery.id, stage: .ownerOpened, owner: ObjectIdentifier(state),
                                budget: nil, onIO: RelayExecutionPool.io.isCurrentWorker))
            } catch {
                opened = nil
                input.diagnostic?.record(.storeOpenFailure)
            }
            Task { @RelayControlActor [work] in
                defer { withExtendedLifetime(work) {} }
                self.automaticOwnerOpened(opened, probe: probe)
            }
        }
    }

    private func automaticOwnerOpened(_ opened: UnsafeSendableBox<RelayCatchUpReadState>?, probe: ObserverSendBoundaryProbe?) {
        precondition(phase == .opening && admissionIO)
        admissionIO = false
        native = opened
        guard opened != nil else { self.opened(nil, turn: nil, probe: probe); return }
        guard isLive, let admission, !admission.isCancelled else { finish(); return }
        // Construction is never retried. The fixed capture budget begins before
        // its first IO enqueue, so subsequent keyed-queue delay counts against it.
        admission.start()
        attemptAutomatic(probe: probe)
    }

    private func attemptAutomatic(probe: ObserverSendBoundaryProbe?) {
        precondition(phase == .opening && !admissionIO && admissionTimer == nil)
        guard isLive, let admission, !admission.isCancelled, let native, let work = setupWork,
              let recovery = input.state.recovery else { finish(); return }
        admissionIO = true
        let observer = admissionObserver
        let diagnostic = input.diagnostic
        observer?(.init(connectionID: recovery.id, stage: .attemptQueued, owner: nil,
                        budget: admission.snapshot, onIO: RelayExecutionPool.io.isCurrentWorker))
        RelayExecutionPool.io.submitRequired(for: input.applyKey) { [work] in
            defer { withExtendedLifetime(work) {} }
            let step: RelayAutomaticSetupStep
            do {
                guard admission.beginAttempt(), let state = native.valueIfPresent, let route = state.automaticRoute else {
                    throw SyncRecoveryConfigurationError.staleAuthorization
                }
                observer?(.init(connectionID: recovery.id, stage: .attemptEntered, owner: ObjectIdentifier(state),
                                budget: admission.snapshot, onIO: RelayExecutionPool.io.isCurrentWorker))
                if let turn = try recovery.openAutomatic(owner: state.lattice, route: route,
                                                         admissible: { admission.admissible() }) {
                    diagnostic?.record(.storeOpenEnd)
                    observer?(.init(connectionID: recovery.id, stage: .admitted, owner: ObjectIdentifier(state),
                                    budget: admission.snapshot, onIO: RelayExecutionPool.io.isCurrentWorker))
                    step = .opened(turn)
                } else if let next = admission.busyReturned() {
                    observer?(.init(connectionID: recovery.id, stage: .busy, owner: ObjectIdentifier(state),
                                    budget: admission.snapshot, onIO: RelayExecutionPool.io.isCurrentWorker))
                    step = .busy(until: next)
                } else { throw SyncRecoveryConfigurationError.staleAuthorization }
            } catch {
                diagnostic?.record(.storeOpenFailure)
                observer?(.init(connectionID: recovery.id, stage: .failed, owner: native.valueIfPresent.map { ObjectIdentifier($0) },
                                budget: admission.snapshot, onIO: RelayExecutionPool.io.isCurrentWorker))
                step = .failed(error)
            }
            Task { @RelayControlActor [work] in
                defer { withExtendedLifetime(work) {} }
                self.automaticReturned(step, probe: probe)
            }
        }
    }

    private func automaticReturned(_ step: RelayAutomaticSetupStep, probe: ObserverSendBoundaryProbe?) {
        precondition(phase == .opening && admissionIO)
        admissionIO = false
        guard isLive, let admission, !admission.isCancelled else { finish(); return }
        switch step {
        case .failed(let error): fail(error)
        case .opened(let turn):
            // The pre-effect boundary already admitted this attempt. A later
            // deadline cannot undo enrollment or turn a successful result into
            // another attempt; ordinary exact-route liveness remains required.
            opened(native, turn: turn, probe: probe)
        case .busy(let deadline):
            guard let work = setupWork else { preconditionFailure("automatic setup lost its charge") }
            precondition(admissionTimer == nil)
            admissionTimer = RelaySetupAdmissionTimer(deadline: deadline) { [self, work] in
                Task { @RelayControlActor [work] in
                    defer { withExtendedLifetime(work) {} }
                    self.automaticTimerDrained(probe: probe)
                }
            }
            if let connectionID = input.state.recovery?.id {
                admissionObserver?(.init(connectionID: connectionID, stage: .waiting, owner: nil,
                                         budget: admission.snapshot, onIO: RelayExecutionPool.io.isCurrentWorker))
            }
        }
    }

    private func automaticTimerDrained(probe: ObserverSendBoundaryProbe?) {
        precondition(phase == .opening && admissionTimer != nil && !admissionIO)
        admissionTimer = nil
        if let connectionID = input.state.recovery?.id {
            admissionObserver?(.init(connectionID: connectionID, stage: .timerDrained, owner: nil,
                                     budget: admission?.snapshot, onIO: RelayExecutionPool.io.isCurrentWorker))
        }
        guard isLive, let admission, !admission.isCancelled else { finish(); return }
        attemptAutomatic(probe: probe)
    }

    private func automaticStopped() {
        guard admission != nil, phase == .opening else { return }
        admission?.cancel()
        if let admissionTimer { admissionTimer.cancel() }
        else if !admissionIO { finish() }
    }

    private func releaseAutomaticSetup() {
        precondition(!admissionIO && admissionTimer == nil)
        admission?.complete()
        if let stop = setupStop { input.state.recovery?.lifetime.removeSetupStop(stop) }
        setupStop = nil; admission = nil
        setupWork = nil
    }

    private var isLive: Bool {
        !input.socket.isClosed && !input.state.revocation.isRevoked && !input.state.isRefused
    }

    private func opened(_ opened: UnsafeSendableBox<RelayCatchUpReadState>?, turn: RecoveryRelayAuthorizationTurn?, probe: ObserverSendBoundaryProbe?) {
        precondition(phase == .opening)
        native = opened
        guard opened != nil else {
            print(">>> Could not open lattice for url: \(String(describing: input.fileURL))")
            input.sockets.remove(socket: input.socket, channelId: input.channel.id)
            input.state.sealIngress(.setupRefused, socket: input.socket)
            input.socket.close(promise: nil)
            finish(); return
        }
        guard isLive else { finish(); return }
        if let recovery = input.state.recovery, let turn {
            let work: RecoveryRelayAuthorizationWork
            do { work = try recovery.reserveAuthorization() }
            catch { fail(error); return }
            authorizationWork = work
            // Authorization owns the mount slot before setup custody drops.
            releaseAutomaticSetup()
            phase = .authorizingRecovery
            // External auth never runs while an IO worker or native lock is
            // held. A closed connection retains its finite mount charge until
            // this actual callback settles; close cannot recycle the budget.
            Task.detached {
                let answer: Result<Data, any Error>
                do { answer = .success(try await recovery.authorize(turn, work: work)) }
                catch { answer = .failure(error) }
                Task { @RelayControlActor in self.authorizationReturned(answer, probe: probe) }
            }
            return
        }
        subscribe(probe: probe)
    }

    private func authorizationReturned(_ answer: Result<Data, any Error>, probe: ObserverSendBoundaryProbe?) {
        precondition(phase == .authorizingRecovery)
        guard isLive else { finish(); return }
        switch answer {
        case .failure(let error): fail(error)
        case .success(let bytes):
            let input = input
            RelayExecutionPool.io.submitRequired(for: input.applyKey) {
                let error: (any Error)?
                do {
                    guard let recovery = input.state.recovery else { throw SyncRecoveryConfigurationError.staleAuthorization }
                    try recovery.finish(bytes); error = nil
                } catch let failure { error = failure }
                Task { @RelayControlActor in self.authorizationConsumed(error, probe: probe) }
            }
        }
    }

    private func authorizationConsumed(_ error: (any Error)?, probe: ObserverSendBoundaryProbe?) {
        precondition(phase == .authorizingRecovery)
        authorizationWork = nil
        if let error { fail(error); return }
        guard isLive else { finish(); return }
        subscribe(probe: probe)
    }

    private func subscribe(probe: ObserverSendBoundaryProbe?) {
        phase = .subscribing
        if let manager = input.watchManager, let context = input.pushContext, let url = input.fileURL {
            input.diagnostic?.record(.watchSubscribeRequested)
            manager.subscribe(fileURL: url, context: context, socket: input.socket,
                              revocation: input.state.revocation, sendBoundaryProbe: probe,
                              setupDiagnostic: input.diagnostic) { sub in
                self.subscribed(sub)
            }
        } else { subscribed(nil) }
    }

    private func subscribed(_ sub: PushSubscription?) {
        precondition(phase == .subscribing)
        subscription = sub
        input.state.pushSubscription = sub
        if input.watchManager != nil {
            input.diagnostic?.record(.watchSubscribeReturned, result: sub != nil)
        }
        guard isLive else { finish(); return }
        guard let native else { preconditionFailure("setup lost its native owner") }
        phase = .goLive
        let input = input
        input.diagnostic?.record(.goLiveScheduled)
        input.socket.eventLoop.execute {
            let ws = input.socket, state = input.state, ackPath = input.diagnostic
            ackPath?.record(.goLiveEntered)
            guard !ws.isClosed, !state.revocation.isRevoked, !state.isRefused else {
                ackPath?.record(.goLiveAbandoned)
                state.buffered.removeAll()
                state.abandoned = true
                Task { @RelayControlActor in self.goLiveReturned(false) }
                return
            }
            // Transfer the same owned envelopes in order, with no new charge.
            let processFrame = input.processFrame
            state.process = processFrame
            let lattice = native.value.lattice
            let (stream, cont) = AsyncStream<RelayIngressFrame>.makeStream(
                bufferingPolicy: .bufferingOldest(state.ingress.streamCapacity))
            let ingress = state.ingress
            cont.onTermination = { [weak state, weak ws, ingress] termination in
                // finish() still owns and drains queued envelopes. Treating its
                // .finished notification as cancellation would discard writes.
                guard case .cancelled = termination else { return }
                ingress.seal(.consumerCancelled)
                guard let state, let ws else { return }
                state.sealIngress(.consumerCancelled, socket: ws, stopQueued: true)
                ws.eventLoop.execute {
                    state.applyContinuation = nil
                    state.buffered.removeAll()
                    ws.close(code: .goingAway, promise: nil)
                }
            }
            state.applyContinuation = cont
            state.applyConsumer = Task.detached { [ackPath] in
                ackPath?.record(.consumerStarted)
                for await frame in stream {
                    defer { withExtendedLifetime(frame) {} }
                    ackPath?.record(.frameDequeued, bytes: frame.byteCount)
                    guard !state.revocation.isRevoked else {
                        ackPath?.record(.dequeueRevoked, bytes: frame.byteCount)
                        continue
                    }
                    await processFrame(ws, frame, lattice)
                }
            }
            ackPath?.record(.consumerCreated)
            for frame in state.buffered {
                state.yieldIngress(frame, to: cont, socket: ws, diagnostic: ackPath)
            }
            state.buffered.removeAll()
            state.lattice = native.value.lattice
            ws.pingInterval = .seconds(30)
            ackPath?.record(.goLiveComplete)
            Task { @RelayControlActor in self.goLiveReturned(true) }
        }
    }

    private func goLiveReturned(_ installed: Bool) {
        precondition(phase == .goLive)
        guard installed, isLive else { finish(); return }
        // This marker now describes the first explicit control catch-up turn,
        // not admission of a nested generic Task or a native query body.
        input.diagnostic?.record(.catchUpTaskStarted)
        readNext()
    }

    private func readNext() {
        guard isLive else { finish(); return }
        guard let native else { preconditionFailure("catch-up lost its native owner") }
        phase = .reading
        let hasSubscription = subscription != nil
        let diagnostic = input.diagnostic
        let pageSpan = diagnostic?.record(.catchUpPageRequested) ?? 0
        RelayExecutionPool.io.submitRequired(for: input.applyKey) {
            diagnostic?.record(.catchUpPageWorkerEntered, span: pageSpan)
            let prepared: RelayCatchUpStep
            if let state = native.valueIfPresent {
                state.hasSubscription = hasSubscription
                prepared = state.next(pageSpan: pageSpan)
            } else {
                diagnostic?.record(.catchUpPageBodyReturned, span: pageSpan)
                prepared = .stopped
            }
            Task { @RelayControlActor in self.prepared(prepared) }
        }
    }

    private func prepared(_ prepared: RelayCatchUpStep) {
        precondition(phase == .reading)
        guard isLive else { finish(); return }
        switch prepared {
        case .stopped: finish()
        case .failed(let error): fail(error)
        case .finished(let emptyBoundary):
            boundary = emptyBoundary ?? boundary
            if let sub = subscription { input.watchManager?.activate(sub, cursor: boundary) }
            finish(keepSubscription: true)
        case .floor(let bytes): send(bytes, pageCount: nil, last: nil)
        case .page(let bytes, let count, let last): send(bytes, pageCount: count, last: last)
        }
    }

    private func send(_ bytes: Data, pageCount: Int?, last: Int64?) {
        phase = .sending
        if let pageCount { input.diagnostic?.record(.catchUpSendBegin, bytes: bytes.count, count: pageCount) }
        let promise = input.socket.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenComplete { result in
            Task { @RelayControlActor in self.sent(result, isPage: pageCount != nil, last: last) }
        }
        if let recovery = input.state.recovery {
            recovery.send(bytes, promise: promise)
        } else if let send = input.sendCatchUp { send(input.socket, bytes, promise) }
        else { input.socket.send(raw: bytes, opcode: .binary, promise: promise) }
    }

    private func sent(_ result: Result<Void, Error>, isPage: Bool, last: Int64?) {
        precondition(phase == .sending)
        guard case .success = result else {
            if case .failure(let error) = result { fail(error) }
            return
        }
        if isPage {
            input.diagnostic?.record(.catchUpSendReturn)
            boundary = last ?? boundary
        }
        guard isLive else { finish(); return }
        readNext()
    }

    private func fail(_ error: any Error) {
        print("Error bringing channel connection up to date: \(error.localizedDescription)")
        input.state.sealIngress(.setupRefused, socket: input.socket)
        input.socket.pingInterval = .seconds(5)
        input.socket.close(code: .unexpectedServerError, promise: nil)
        finish()
    }

    private func finish(keepSubscription: Bool = false) {
        guard phase != .finishing, phase != .finished else { return }
        phase = .finishing
        authorizationWork = nil
        if !keepSubscription { input.state.recovery?.retire(for: input.applyKey) }
        if !keepSubscription, let sub = subscription {
            input.state.pushSubscription = nil
            input.watchManager?.unsubscribe(sub)
        }
        subscription = nil
        let native = native
        self.native = nil
        // Do not release setup custody until its retained owner is cleared on
        // IO. Already-copied stop/control/cancel callbacks retain their own copy.
        let setupWork = setupWork
        let observer = admissionObserver
        let connectionID = input.state.recovery?.id
        let budget = admission?.snapshot
        releaseAutomaticSetup()
        admissionObserver = nil
        // Final query/native releases are serialized with the last native page.
        // No IO worker waits for a socket or for a control-actor completion.
        RelayExecutionPool.io.submitRequired(for: input.applyKey) {
            defer { withExtendedLifetime(setupWork) {} }
            native?.clear()
            if let connectionID { observer?(.init(connectionID: connectionID, stage: .ownerReleased,
                                                  owner: nil, budget: budget, onIO: RelayExecutionPool.io.isCurrentWorker)) }
            Task { @RelayControlActor [setupWork] in
                defer { withExtendedLifetime(setupWork) {} }
                self.phase = .finished
                self.input.didFinish()
            }
        }
    }
}
