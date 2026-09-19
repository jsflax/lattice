import Foundation
import Testing
import Vapor
import NIOConcurrencyHelpers
@testable import Lattice
@testable import LatticeServerKit

struct SyncVisibilityParameters: Codable, Sendable {
    let writerCount: Int, opsPerWriter: Int, payloadBytes: Int
    let cadenceNS: UInt64, staggerNS: UInt64
    let warmupPerWriter: Int, quietWarmupOps: Int, quietOps: Int
    let quietCadenceNS: UInt64, drainNS: UInt64
    let driverWorkers: Int

    static let smoke = Self(writerCount: 2, opsPerWriter: 3, payloadBytes: 2048,
        cadenceNS: 40_000_000, staggerNS: 5_000_000, warmupPerWriter: 1, quietWarmupOps: 1,
        quietOps: 1, quietCadenceNS: 1_000_000_000, drainNS: 20_000_000_000, driverWorkers: 2)
    static func full(quietOnly: Bool) -> Self {
        .init(writerCount: quietOnly ? 0 : 8, opsPerWriter: 1000, payloadBytes: 2048,
              cadenceNS: 40_000_000, staggerNS: 5_000_000, warmupPerWriter: 20, quietWarmupOps: 1,
              quietOps: 40, quietCadenceNS: 1_000_000_000, drainNS: 60_000_000_000, driverWorkers: 8)
    }
}

private struct SyncVisibilityReport: Codable {
    let schema = "lattice.sync-public-visibility/1"
    let runID: String, mode: String, profile: String, clock: String
    let complete: Bool
    let metadata: [String: String]
    let effectiveParameters: SyncVisibilityParameters
    let startedNS: UInt64, measurementEpochNS: UInt64?, deadlineNS: UInt64?, finishedNS: UInt64
    let errors: [String]
    let counters: SyncVisibilityCounters
    let overhead: [String: UInt64]
    let receipts: [SyncVisibilityReceipt]
}

/// Both mounts share storage and the relay's process services, but maintain
/// separate socket registries, matching writer/push-watch consumer topology.
private final class SyncVisibilityRelay: @unchecked Sendable {
    let app: Application, storage: URL, port: Int
    let writer: SyncRelayHandle, watcher: SyncRelayHandle
    private struct SetupCounts { var started = 0, finished = 0, closed = 0 }
    private let counts: NIOLockedValueBox<SetupCounts>
    private let hooks: RelayIngressTestHooks

    private init(app: Application, storage: URL, port: Int, writer: SyncRelayHandle,
                 watcher: SyncRelayHandle, counts: NIOLockedValueBox<SetupCounts>, hooks: RelayIngressTestHooks) {
        self.app = app; self.storage = storage; self.port = port
        self.writer = writer; self.watcher = watcher; self.counts = counts; self.hooks = hooks
    }

    static func make(directory: URL) async throws -> SyncVisibilityRelay {
        let storage = directory.appendingPathComponent("relay", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        var environment = try Environment.detect(); environment.arguments = ["vapor"]
        let app = try await Application.make(environment)
        let counts = NIOLockedValueBox(SetupCounts())
        let hooks = RelayIngressTestHooks(beforeAsyncSetup: { counts.withLockedValue { $0.started += 1 } },
            didBufferFrame: { _ in }, didFinishAsyncSetup: { counts.withLockedValue { $0.finished += 1 } },
            didCloseConnection: { counts.withLockedValue { $0.closed += 1 } })
        RelayIngressTesting.install(hooks, for: storage)
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0
        app.http.server.configuration.shutdownTimeout = .milliseconds(500)
        @Sendable func channel(_ request: Request) async throws -> SyncChannel {
            guard let store = request.parameters.get("store"), ["hot", "quiet"].contains(store),
                  let token = request.headers.bearerAuthorization?.token,
                  let user = UUID(uuidString: token) else { throw Abort(.unauthorized) }
            return .init(id: store, userId: user, databaseFileName: "\(store).sqlite")
        }
        let writer = Lattice.configureSyncRelay(on: app.routes, path: ["writer", ":store"],
            for: [SyncVisibilityObject.self], storageURL: storage,
            writePolicy: .init(allowedOperations: [SyncVisibilityObject.entityName: [.insert]], unlistedTables: .deny),
            channelExtractor: channel)
        let watcher = Lattice.configureSyncRelay(on: app.routes, path: ["watch", ":store"],
            for: [SyncVisibilityObject.self], storageURL: storage,
            writePolicy: .init(allowedOperations: [:], unlistedTables: .deny),
            observerPush: .init(reconcileInterval: nil), channelExtractor: channel)
        do {
            try await app.startup()
            guard let assigned = app.http.server.shared.localAddress?.port else {
                throw SyncVisibilityFailure.invalid("relay has no bound loopback port")
            }
            return SyncVisibilityRelay(app: app, storage: storage, port: assigned, writer: writer,
                                       watcher: watcher, counts: counts, hooks: hooks)
        } catch {
            try? await app.asyncShutdown(); RelayIngressTesting.remove(hooks, for: storage); throw error
        }
    }

    var setupSettled: Bool { counts.withLockedValue { $0.started > 0 && $0.started == $0.finished } }

    func shutdown(recorder: SyncVisibilityRecorder) async {
        for stream in ["hot", "quiet"] {
            await writer.disconnectAll(channelId: stream); await watcher.disconnectAll(channelId: stream)
        }
        do { try await app.asyncShutdown() } catch { recorder.error("relay shutdown: \(error)") }
        let deadline = SyncVisibilityClock.now() + 10_000_000_000
        while !counts.withLockedValue({ $0.started == $0.finished && $0.closed >= $0.started }) && SyncVisibilityClock.now() < deadline {
            do { try await Task.sleep(nanoseconds: 1_000_000) }
            catch { recorder.error("relay cleanup wait cancelled"); break }
        }
        if !counts.withLockedValue({ $0.started == $0.finished && $0.closed >= $0.started }) {
            recorder.error("relay setup/socket cleanup fence incomplete")
        }
        RelayIngressTesting.remove(hooks, for: storage)
        // Closed-count is an ingress event, not the later control/loop/IO
        // native-detach fence. Do not unregister the governor, shut shared
        // services down, or unlink files while those owners may still exist.
        // Full profiles require one externally isolated process per run.
    }
}

@Suite("SDK public sync visibility", .serialized)
struct SyncPublicVisibilityTests {
    @Test(.timeLimit(.minutes(2)))
    func smallPublicVisibilityQualification() async throws {
        try await run(mode: "smoke", profile: "loaded", parameters: .smoke)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LATTICE_SYNC_VISIBILITY_PERF"] == "1"),
          .timeLimit(.minutes(5)))
    func offeredLoadPublicVisibilityProfile() async throws {
        let profile = ProcessInfo.processInfo.environment["LATTICE_SYNC_VISIBILITY_PROFILE"] ?? "loaded"
        guard ["loaded", "quiet-only"].contains(profile) else {
            throw SyncVisibilityFailure.invalid("profile must be loaded or quiet-only")
        }
        try await run(mode: "full", profile: profile, parameters: .full(quietOnly: profile == "quiet-only"))
    }

    private func directory(mode: String) throws -> URL {
        let localdev = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("localdev", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let raw: URL
        if let path = ProcessInfo.processInfo.environment["LATTICE_SYNC_VISIBILITY_RUN_DIR"] {
            guard path.hasPrefix("/") else {
                throw SyncVisibilityFailure.invalid("LATTICE_SYNC_VISIBILITY_RUN_DIR must be absolute and under ~/localdev")
            }
            raw = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            guard mode != "full" else {
                throw SyncVisibilityFailure.invalid("full profile requires a new absolute LATTICE_SYNC_VISIBILITY_RUN_DIR under ~/localdev")
            }
            raw = localdev.appendingPathComponent("lattice-sync-visibility-runs/smoke-\(UUID().uuidString)", isDirectory: true)
        }
        let target = raw.standardizedFileURL.resolvingSymlinksInPath()
        guard target.path.hasPrefix(localdev.path + "/"), !FileManager.default.fileExists(atPath: target.path) else {
            throw SyncVisibilityFailure.invalid("evidence directory must be new and under ~/localdev")
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    private func waitForVisibility(_ recorder: SyncVisibilityRecorder, phase: String, deadline: UInt64) async throws {
        while !recorder.allVisible(phase: phase) && SyncVisibilityClock.now() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        recorder.freeze(phase: phase)
        if !recorder.allVisible(phase: phase) { throw SyncVisibilityFailure.invalid("\(phase) public visibility deadline") }
    }

    private func run(mode: String, profile: String, parameters p: SyncVisibilityParameters) async throws {
        let directory = try directory(mode: mode), runID = UUID().uuidString
        let started = SyncVisibilityClock.now()
        var expected: [SyncVisibilityExpected] = []
        expected.reserveCapacity(p.writerCount * (p.opsPerWriter + p.warmupPerWriter) + p.quietOps + p.quietWarmupOps)
        for stream in ["hot", "quiet"] {
            for writer in 0..<(stream == "hot" ? p.writerCount : 1) {
                for phase in ["warmup", "measured"] {
                    let count = stream == "hot" ? (phase == "warmup" ? p.warmupPerWriter : p.opsPerWriter)
                        : (phase == "warmup" ? p.quietWarmupOps : p.quietOps)
                    for sequence in 0..<count {
                        expected.append(.init(runID: runID, stream: stream, phase: phase,
                                              writer: writer, sequence: sequence, bytes: p.payloadBytes))
                    }
                }
            }
        }
        let recorder = SyncVisibilityRecorder(expected: expected)
        let pool = RelayExecutionPool(workerCount: p.driverWorkers, name: "visibility.driver")
        var relay: SyncVisibilityRelay?, clients: [SyncVisibilityClient] = []
        var writers: [String: SyncVisibilityClient] = [:]
        var measurementEpoch: UInt64?, observationDeadline: UInt64?
        var metadata = ["platform": ProcessInfo.processInfo.operatingSystemVersionString,
            "placement": "one process; loopback relay; independent file-backed SDK clients",
            "processorCount": String(ProcessInfo.processInfo.processorCount),
            "metrics": "raw receipts only; no speed or goal pass assertion",
            "refusalsFramesQueuesRSSWAL": "not instrumented; unknown, not zero",
            "cleanupScope": "client reads drained and close returned; setup/socket events and app shutdown; total relay native/transport/cache destruction not asserted; files retained",
            "processIsolation": "fresh external process per full profile required; runner must authenticate exit separately",
            "sourceGraphAuthentication": "declared metadata; requires external build/clock qualification"]
        let env = ProcessInfo.processInfo.environment
        for key in ["SDK_REVISION", "CORE_REVISION", "BUILD_ID", "HOST_ID", "RUN_GROUP", "RUN_ORDER", "LOGGING"] {
            metadata[key] = env["LATTICE_SYNC_VISIBILITY_" + key] ?? "unspecified"
        }
        var overhead: [String: UInt64] = [:]
        do {
            if mode == "full" {
                guard SyncVisibilityClock.hasProbe else { throw SyncVisibilityFailure.invalid("full profile requires reviewed native probe and Swift/C/C++ LATTICE_SYNC_COMMIT_PROBE flags") }
                guard !metadata.values.contains("unspecified") else { throw SyncVisibilityFailure.invalid("full profile requires all declared graph/build/host/run/logging metadata") }
            }
            // Small separate primitive-cost sample; no claim to measure complete
            // observer/read cost or the WAL instrumentation's overhead.
            let scratch = SyncVisibilityRecorder(expected: [expected[0]])
            var clockCosts = [UInt64](), recordCosts = [UInt64]()
            clockCosts.reserveCapacity(256); recordCosts.reserveCapacity(256)
            for _ in 0..<256 {
                var start = SyncVisibilityClock.now(); clockCosts.append(SyncVisibilityClock.now() - start)
                start = SyncVisibilityClock.now(); scratch.offered(0); recordCosts.append(SyncVisibilityClock.now() - start)
            }
            clockCosts.sort(); recordCosts.sort()
            overhead = ["sampleCount": 256, "clockPairP50NS": clockCosts[127], "clockPairP95NS": clockCosts[243],
                        "offeredRecorderPrimitiveP50NS": recordCosts[127], "offeredRecorderPrimitiveP95NS": recordCosts[243]]
            let mounted = try await SyncVisibilityRelay.make(directory: directory); relay = mounted
            let clientDirectory = directory.appendingPathComponent("clients", isDirectory: true)
            try FileManager.default.createDirectory(at: clientDirectory, withIntermediateDirectories: true)
            for stream in ["hot", "quiet"] where stream == "quiet" || p.writerCount > 0 {
                for writer in 0..<(stream == "hot" ? p.writerCount : 1) {
                    let key = "\(stream)-writer-\(writer)"
                    let configuration = Lattice.Configuration(fileURL: clientDirectory.appendingPathComponent("\(key).sqlite"),
                        authorizationToken: UUID().uuidString, wssEndpoint: URL(string: "ws://127.0.0.1:\(mounted.port)/writer/\(stream)"))
                    let client = try await syncVisibilityOnWorker(pool: pool, key: key) {
                        try SyncVisibilityClient(key: key, stream: stream, configuration: configuration, recorder: recorder, watches: false)
                    }
                    clients.append(client); writers[key] = client
                }
                let key = "\(stream)-watcher"
                let configuration = Lattice.Configuration(fileURL: clientDirectory.appendingPathComponent("\(key).sqlite"),
                    authorizationToken: UUID().uuidString, wssEndpoint: URL(string: "ws://127.0.0.1:\(mounted.port)/watch/\(stream)"),
                    syncTuning: .init(registersAsObserver: true))
                let client = try await syncVisibilityOnWorker(pool: pool, key: key) {
                    try SyncVisibilityClient(key: key, stream: stream, configuration: configuration, recorder: recorder, watches: true)
                }
                clients.append(client)
            }
            let warmEpoch = SyncVisibilityClock.now(), warmDeadline = warmEpoch + 30_000_000_000
            for index in expected.indices where expected[index].phase == "warmup" {
                recorder.schedule(index, at: warmEpoch, deadline: warmDeadline)
            }
            await offer(phase: "warmup", epoch: warmEpoch, deadline: warmDeadline, parameters: p,
                        recorder: recorder, writers: writers, pool: pool)
            try await waitForVisibility(recorder, phase: "warmup", deadline: warmDeadline)
            while !mounted.setupSettled && SyncVisibilityClock.now() < warmDeadline { try await Task.sleep(nanoseconds: 2_000_000) }
            guard mounted.setupSettled else { throw SyncVisibilityFailure.invalid("setup release fence did not settle") }
            let epoch = SyncVisibilityClock.now() + 100_000_000
            let hotEnd = p.writerCount == 0 ? 0 : UInt64(p.opsPerWriter - 1) * p.cadenceNS + UInt64(p.writerCount - 1) * p.staggerNS
            let quietEnd = UInt64(p.quietOps - 1) * p.quietCadenceNS
            let deadline = epoch + max(hotEnd, quietEnd) + p.drainNS
            measurementEpoch = epoch; observationDeadline = deadline
            for index in expected.indices where expected[index].phase == "measured" {
                let value = expected[index]
                let offset = value.stream == "hot" ? UInt64(value.sequence) * p.cadenceNS + UInt64(value.writer) * p.staggerNS
                    : UInt64(value.sequence) * p.quietCadenceNS
                recorder.schedule(index, at: epoch + offset, deadline: deadline)
            }
            await offer(phase: "measured", epoch: epoch, deadline: deadline, parameters: p,
                        recorder: recorder, writers: writers, pool: pool)
            try await waitForVisibility(recorder, phase: "measured", deadline: deadline)
        } catch { recorder.error(String(describing: error)) }
        recorder.freeze(phase: "warmup"); recorder.freeze(phase: "measured")
        // Await each driver completion before callback admission closes. Native
        // owner close happens on a big-stack worker, never inside its observer.
        for client in clients {
            do { try await syncVisibilityOnWorker(pool: pool, key: client.key) { client.stopAndClose() } }
            catch { recorder.error("client cleanup: \(error)") }
        }
        if let relay { await relay.shutdown(recorder: recorder) }
        writers.removeAll(); clients.removeAll(); relay = nil
        await pool.shutdown()
        let (receipts, counters, errors) = recorder.snapshot()
        let originsValid = !SyncVisibilityClock.hasProbe || validOrigins(receipts)
        let complete = errors.isEmpty && originsValid && counters.unknownOperation == 0 && counters.valueMismatch == 0
            && counters.diagnosticOverflow == 0 && counters.malformedObservation == 0 && receipts.allSatisfy {
                $0.offeredNS != nil && $0.writeStartNS != nil && $0.writeReturnNS != nil && $0.writeError == nil
                && $0.firstExactReadNS != nil && $0.valueMatch == true && !$0.timedOut
                && $0.observedID == $0.id && $0.readerStoreID == "clients/\($0.stream)-watcher.sqlite"
            }
        let report = SyncVisibilityReport(runID: runID, mode: mode, profile: profile, clock: SyncVisibilityClock.name,
            complete: complete, metadata: metadata, effectiveParameters: p, startedNS: started,
            measurementEpochNS: measurementEpoch, deadlineNS: observationDeadline, finishedNS: SyncVisibilityClock.now(),
            errors: errors, counters: counters, overhead: overhead, receipts: receipts)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let output = directory.appendingPathComponent("receipts.json")
        try encoder.encode(report).write(to: output, options: .atomic)
        print("SDK public visibility receipts: \(output.path); complete=\(complete); mode=\(mode); no performance verdict")
        #expect(complete, "Public visibility/origin/cleanup incomplete; inspect retained receipts.json")
    }

    private func validOrigins(_ receipts: [SyncVisibilityReceipt]) -> Bool {
        guard receipts.allSatisfy({ receipt in
            guard receipt.armStatus == 0, receipt.probeStatus == 0,
                  receipt.probeOperationID == receipt.token, receipt.probeAttemptID == 1,
                  let start = receipt.writeStartNS, let armed = receipt.probeArmedNS,
                  let committed = receipt.postcommitNS, let returned = receipt.writeReturnNS,
                  let visible = receipt.firstExactReadNS,
                  let owner = receipt.probeOwnerID, let connection = receipt.probeConnectionID,
                  let thread = receipt.probeThreadID else { return false }
            // Preserve raw negative intervals in JSON, but fail origin
            // qualification rather than clamping or dropping those operations.
            return owner != 0 && connection != 0 && thread != 0 && start <= armed
                && armed <= committed && committed <= returned && committed <= visible
        }) else { return false }
        let owners = Dictionary(grouping: receipts, by: \.writerStoreID)
        guard owners.values.allSatisfy({ rows in
            Set(rows.compactMap(\.probeOwnerID)).count == 1 && Set(rows.compactMap(\.probeConnectionID)).count == 1
        }) else { return false }
        // Physical writers must remain distinct across independently opened files.
        return Set(owners.values.compactMap { $0.first?.probeOwnerID }).count == owners.count
            && Set(owners.values.compactMap { $0.first?.probeConnectionID }).count == owners.count
    }

    private func offer(phase: String, epoch: UInt64, deadline: UInt64, parameters p: SyncVisibilityParameters,
                       recorder: SyncVisibilityRecorder, writers: [String: SyncVisibilityClient], pool: RelayExecutionPool) async {
        let lanes = Dictionary(grouping: recorder.expected.indices.filter { recorder.expected[$0].phase == phase }) {
            "\(recorder.expected[$0].stream)-writer-\(recorder.expected[$0].writer)"
        }
        await withTaskGroup(of: Void.self) { group in
            for (key, indices) in lanes {
                guard let writer = writers[key] else { recorder.error("missing writer lane \(key)"); continue }
                group.addTask {
                    for index in indices {
                        let value = recorder.expected[index]
                        let offset: UInt64 = phase == "warmup" ? 0 : value.stream == "hot"
                            ? UInt64(value.sequence) * p.cadenceNS + UInt64(value.writer) * p.staggerNS
                            : UInt64(value.sequence) * p.quietCadenceNS
                        let scheduled = epoch + offset
                        do {
                            let now = SyncVisibilityClock.now()
                            if scheduled > now { try await Task.sleep(nanoseconds: scheduled - now) }
                            guard !Task.isCancelled, SyncVisibilityClock.now() < deadline else {
                                recorder.error("driver deadline/cancellation; remaining \(key) receipts stay unoffered and timed out"); return
                            }
                            recorder.offered(index)
                            try await syncVisibilityOnWorker(pool: pool, key: key) { writer.write(index: index, recorder: recorder) }
                        } catch { recorder.error("driver \(key): \(error)"); return }
                    }
                }
            }
        }
    }
}
