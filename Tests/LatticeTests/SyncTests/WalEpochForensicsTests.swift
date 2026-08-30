import Foundation
import Combine
import Testing
@testable import Lattice
@testable import LatticeServerKit

// ============================================================================
// WAL-epoch durability forensics — "days of relay writes invisible to fresh
// readers; a machine restart discarded the un-checkpointed epoch" (joyjet +
// orbital prod, Aug 2026).
//
// Field evidence this harness reproduces and discriminates:
//   (1) LIVE-WRITER INVISIBILITY — while the relay process holds and writes a
//       channel file, a FRESH sqlite3 connection reads only content through
//       the last process boot; VACUUM INTO backups capture the stale view.
//   (2) IDLE files read fine (14.9MB WAL + 4KB main serves all 632 rows).
//   (3) RESTART DISCARD (joyjet) vs RECOVERY (orbital) after kill/restart.
//   (4) CHECKPOINT STARVATION — mains untouched for a week+ of writes; the
//       dtor's passive checkpoint (db.cpp:151) never runs on killed servers.
//
// Mechanism citations (pinned core, LatticeCore at .build/checkouts):
//   * db.cpp:83-88     — relay write connection: journal_mode=WAL,
//                        cache_size=50000 (~200MB), mmap_size=300MB.
//   * db.cpp:133-153   — the ONLY unconditional checkpoint is the DESTRUCTOR's
//                        PASSIVE one; kill -9 / SIGKILL'd servers never run it.
//   * lattice.cpp:204  — setup_change_hook installs a CUSTOM sqlite3_wal_hook
//                        on every file-backed write connection. SQLite's
//                        autocheckpoint (default 1000 frames) is implemented
//                        AS the wal hook, so installing lattice's hook
//                        UNREGISTERS autocheckpointing. The replacement only
//                        sets an eviction flag past 16MB (lattice.hpp:2893)
//                        which is drained by read-generation maintenance the
//                        relay never triggers → nothing ever checkpoints a
//                        relay channel store while the process lives.
//   * db.cpp:737-797   — begin_transaction = BEGIN IMMEDIATE with the
//                        configured busy budget (relay: 2s).
//   * sync.cpp:2830-2883 — mark_audit_entries_synced JOINS an already-open
//                        transaction (own_transaction=false → it never
//                        commits); any code path that BEGINs on the shared
//                        channel connection and fails to COMMIT wedges every
//                        aliased handle's writes into one never-committed
//                        transaction (the instance cache aliases every
//                        relay-shaped open of a file to ONE connection —
//                        pinned by BusySafeApplyForensicsTests).
//   * lattice.hpp:3934-3945 — while the write connection is in a transaction,
//                        same-thread reads route THROUGH the write connection
//                        (read-your-writes), so in-process readers and
//                        relay fan-out see a wedged epoch that no fresh
//                        external connection can.
//
// The tests below measure, from a genuinely SEPARATE process
// (/usr/bin/sqlite3, fresh connection per probe), what is visible/durable at
// each stage. Kill -9 semantics use the WalEpochWriterChild executable
// (Sources/WalEpochWriterChild) holding the exact relay-shaped configuration
// (`SyncRelayApplyPolicy.configuration` → Configuration(fileURL:) +
// busyTimeoutMs=2000, RelayApply.swift:115-124).
//
// Env knobs:
//   FORENSIC_WAL_MB   target live WAL size in MB for the growth stages (default 8)
// ============================================================================

/// Payload-bearing row for WAL growth. The child target declares an
/// identically-named model, so both processes address the same table.
@Model class WalEpochBlob {
    var seq: Int = 0
    var payload: String = ""

    init(seq: Int, payload: String) {
        self.seq = seq
        self.payload = payload
    }
}

// MARK: - External probe plumbing (fresh process per probe)

/// Runs /usr/bin/sqlite3 as a FRESH process (fresh connection, fresh wal-index
/// attach) and returns stdout/stderr. `readonly` mirrors an operator's
/// `sqlite3 -readonly` probe; the default mirrors a plain `sqlite3 file` open.
@discardableResult
private func sqlite3Run(_ dbPath: String, _ sql: String,
                        readonly: Bool = false,
                        timeout: TimeInterval = 30) -> (out: String, err: String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    var args: [String] = []
    if readonly { args.append("-readonly") }
    args += ["-cmd", ".timeout 2000", dbPath, sql]
    proc.arguments = args
    let outPipe = Pipe(), errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe
    do { try proc.run() } catch { return ("", "spawn-failed: \(error)") }
    let deadline = Date().addingTimeInterval(timeout)
    while proc.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    if proc.isRunning { kill(proc.processIdentifier, SIGKILL); proc.waitUntilExit() }
    let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return (out.trimmingCharacters(in: .whitespacesAndNewlines),
            err.trimmingCharacters(in: .whitespacesAndNewlines))
}

private func fileBytes(_ path: String) -> Int64 {
    (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64 ?? -1) ?? -1
}

private func walPath(_ url: URL) -> String { url.path + "-wal" }
private func shmPath(_ url: URL) -> String { url.path + "-shm" }

/// One external snapshot of a channel file: sizes plus fresh-connection row
/// counts (plain and -readonly), all from separate processes.
private struct ChannelProbe {
    var mainBytes: Int64 = -1
    var walBytes: Int64 = -1
    var shmBytes: Int64 = -1
    var rows = -1          // SimpleSyncObject rows, fresh plain connection
    var maxValue = -2      // max(value), fresh plain connection
    var blobs = -1         // WalEpochBlob rows, fresh plain connection
    var roRows = -1        // SimpleSyncObject rows, fresh -readonly connection
    var err = ""
}

private func probeChannel(_ url: URL, label: String) -> ChannelProbe {
    var p = ChannelProbe()
    p.mainBytes = fileBytes(url.path)
    p.walBytes = fileBytes(walPath(url))
    p.shmBytes = fileBytes(shmPath(url))
    let sql = """
    SELECT count(*) || '|' || COALESCE(max(value), -1) FROM SimpleSyncObject;
    SELECT count(*) FROM WalEpochBlob;
    """
    let plain = sqlite3Run(url.path, sql)
    let lines = plain.out.split(separator: "\n").map(String.init)
    if lines.count >= 1 {
        let parts = lines[0].split(separator: "|").map(String.init)
        p.rows = Int(parts.first ?? "") ?? -1
        p.maxValue = Int(parts.count > 1 ? parts[1] : "") ?? -2
    }
    if lines.count >= 2 { p.blobs = Int(lines[1]) ?? -1 }
    p.err = plain.err
    let ro = sqlite3Run(url.path, "SELECT count(*) FROM SimpleSyncObject;", readonly: true)
    p.roRows = Int(ro.out) ?? -1
    if p.err.isEmpty { p.err = ro.err }
    print("""
    FORENSIC probe[\(label)]: main=\(p.mainBytes)B wal=\(p.walBytes)B shm=\(p.shmBytes)B \
    fresh_rows=\(p.rows) fresh_max=\(p.maxValue) fresh_blobs=\(p.blobs) ro_rows=\(p.roRows)\
    \(p.err.isEmpty ? "" : " err=\(p.err)")
    """)
    return p
}

/// What a restart-that-lost-the-WAL would serve: rows readable from a copy of
/// the MAIN file alone (no -wal/-shm beside it).
private func mainOnlyRows(_ url: URL) -> Int {
    let copy = FileManager.default.temporaryDirectory
        .appending(path: "mainonly-\(String.random(length: 10)).sqlite")
    defer { try? FileManager.default.removeItem(at: copy) }
    do { try FileManager.default.copyItem(at: url, to: copy) } catch { return -1 }
    let r = sqlite3Run(copy.path, "SELECT count(*) FROM SimpleSyncObject;")
    return Int(r.out) ?? -1
}

/// The stale-backup reproduction: VACUUM INTO from a fresh connection, then
/// count the backup's rows.
private func vacuumIntoRows(_ url: URL) -> Int {
    let backup = FileManager.default.temporaryDirectory
        .appending(path: "vacuum-\(String.random(length: 10)).sqlite")
    defer { try? FileManager.default.removeItem(at: backup) }
    let r = sqlite3Run(url.path, "VACUUM INTO '\(backup.path)';", timeout: 60)
    if !r.err.isEmpty { print("FORENSIC vacuum-into err: \(r.err)") }
    let c = sqlite3Run(backup.path, "SELECT count(*) FROM SimpleSyncObject;")
    return Int(c.out) ?? -1
}

/// The ops lever under test (goal C): PRAGMA wal_checkpoint from a fresh
/// external process. Returns SQLite's (busy, log, checkpointed) triple.
private func externalCheckpoint(_ url: URL, mode: String) -> (busy: Int, log: Int, ckpt: Int, raw: String) {
    let r = sqlite3Run(url.path, "PRAGMA wal_checkpoint(\(mode));", timeout: 60)
    let parts = r.out.split(separator: "|").map(String.init)
    let triple = (busy: Int(parts.count > 0 ? parts[0] : "") ?? -1,
                  log: Int(parts.count > 1 ? parts[1] : "") ?? -1,
                  ckpt: Int(parts.count > 2 ? parts[2] : "") ?? -1,
                  raw: r.out + (r.err.isEmpty ? "" : " err=\(r.err)"))
    print("FORENSIC external wal_checkpoint(\(mode)): busy=\(triple.busy) log=\(triple.log) checkpointed=\(triple.ckpt)")
    return triple
}

private func poll(timeout: TimeInterval, _ predicate: @escaping @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return predicate()
}

// MARK: - Writer child (kill -9 semantics need a real separate process)

/// Spawns Sources/WalEpochWriterChild — a separate process holding the
/// relay-shaped handle — and tracks its stdout protocol.
private final class WriterChild: @unchecked Sendable {
    let process = Process()
    private let out = Pipe()
    private let errAcc = LockedBox("")
    private let outAcc = LockedBox("")

    static var binaryURL: URL {
        // swift test builds executable target deps next to the xctest bundle.
        Bundle(for: WalEpochForensicsTests.self).bundleURL
            .deletingLastPathComponent()
            .appending(path: "WalEpochWriterChild")
    }

    init(dbURL: URL, mode: String, extra: [String] = []) throws {
        process.executableURL = Self.binaryURL
        process.arguments = [dbURL.path, mode] + extra
        process.standardOutput = out
        let errPipe = Pipe()
        process.standardError = errPipe
        // Deregister on EOF (empty availableData): a killed child's pipe
        // otherwise re-fires the handler in a hot loop — enough spinning
        // handlers across sequential kill tests starve waitUntilExit and
        // wedge the suite.
        out.fileHandleForReading.readabilityHandler = { [outAcc] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            outAcc.withLock { $0 += String(decoding: d, as: UTF8.self) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [errAcc] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            errAcc.withLock { $0 += String(decoding: d, as: UTF8.self) }
        }
        try process.run()
    }

    var transcript: String { outAcc.withLock { $0 } }
    var stderrTail: String { String(errAcc.withLock { $0 }.suffix(500)) }

    /// Highest N seen on lines "<prefix> N".
    func lastCount(prefix: String) -> Int {
        transcript.split(separator: "\n")
            .filter { $0.hasPrefix(prefix + " ") }
            .compactMap { Int($0.dropFirst(prefix.count + 1)) }
            .max() ?? 0
    }

    func sawLine(prefix: String) -> Bool {
        transcript.split(separator: "\n").contains { $0.hasPrefix(prefix) }
    }

    /// SIGKILL — the restart-semantics event under test. No cleanup runs in
    /// the child (no dtor, no passive checkpoint), exactly like a killed
    /// server process.
    ///
    /// Deliberately NOT `waitUntilExit()`: with the harness's constant churn
    /// of short-lived sqlite3 probe processes, NSTask's SIGCHLD bookkeeping
    /// can lose the reap race and strand `waitUntilExit` forever on a child
    /// that is already dead (observed as a full-suite wedge inside
    /// -[NSConcreteTask waitUntilExit]). SIGKILL is not ignorable — the
    /// child is dead-or-zombie the moment it lands and holds no locks or
    /// fds either way — so a bounded poll for the transcript to settle is
    /// both sufficient and hang-proof.
    func killNine() {
        kill(process.processIdentifier, SIGKILL)
        var lastLen = -1
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let len = outAcc.withLock { $0.count }
            if len == lastLen && !process.isRunning { break }
            lastLen = len
            Thread.sleep(forTimeInterval: 0.05)
        }
        out.fileHandleForReading.readabilityHandler = nil
    }

    func terminateIfRunning() {
        if process.isRunning { killNine() }
    }
}

// MARK: - Shared fixtures

/// Seeds `rows` committed SimpleSyncObject rows through a SCOPED relay-shaped
/// handle, then lets it close (the dtor's passive checkpoint runs → this is
/// the "content through the last process boot" that lives in/near MAIN).
private func seedBaseline(_ url: URL, rows: Int) throws {
    let l = try Lattice(for: [SimpleSyncObject.self, WalEpochBlob.self],
                        configuration: SyncRelayApplyPolicy.configuration(fileURL: url, storeConfiguration: nil))
    for i in 0..<rows {
        try l.add(SimpleSyncObject(value: i, floatValue: Float(i)))
    }
}

/// Adds payload rows on `lattice` until the -wal file reaches `targetBytes`.
/// Every add is its own committed transaction. Returns blobs written.
@discardableResult
private func growWal(_ lattice: Lattice, url: URL, targetBytes: Int64,
                     startSeq: Int, payloadBytes: Int = 16_384) throws -> Int {
    var written = 0
    let payload = String(repeating: "x", count: payloadBytes)
    while fileBytes(walPath(url)) < targetBytes && written < 5_000 {
        try lattice.add(WalEpochBlob(seq: startSeq + written, payload: payload))
        written += 1
    }
    return written
}

private func forensicTempDir(_ tag: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "wal-epoch-\(tag)-\(String.random(length: 10))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private var targetWalMB: Int64 {
    Int64(ProcessInfo.processInfo.environment["FORENSIC_WAL_MB"] ?? "") ?? 8
}

// ============================================================================
// The suite
// ============================================================================

@Suite("WalEpochForensics", .serialized, .timeLimit(.minutes(10)))
final class WalEpochForensicsTests: BaseTest {

    // MARK: - (A) Live-writer visibility

    /// A1 — BASELINE. A relay-shaped handle committing row-per-transaction
    /// writes: what does a fresh external connection see at each stage, and
    /// does ANYTHING checkpoint the growing WAL into main while the process
    /// lives? (lattice.cpp:204's custom wal hook displaced SQLite's
    /// autocheckpoint, so the prediction is: fresh readers see every commit —
    /// invisibility is NOT baseline WAL behavior — but main never advances.)
    @Test func freshProcessReadersSeeLiveCommittedWrites() async throws {
        let dir = try forensicTempDir("a1")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "channel.sqlite")

        let lattice = try Lattice(for: [SimpleSyncObject.self, WalEpochBlob.self],
                                  configuration: SyncRelayApplyPolicy.configuration(fileURL: url, storeConfiguration: nil))

        // Stage 1: 50 small committed writes.
        for i in 0..<50 { try lattice.add(SimpleSyncObject(value: i, floatValue: Float(i))) }
        let inProcess1 = lattice.objects(SimpleSyncObject.self).count
        let s1 = probeChannel(url, label: "A1 after 50 commits")

        // Stage 2: grow the WAL to ~2MB with committed payload writes.
        let blobs2 = try growWal(lattice, url: url, targetBytes: 2 << 20, startSeq: 0)
        let s2 = probeChannel(url, label: "A1 wal>=2MB (\(blobs2) blob commits)")

        // Stage 3: grow to the FORENSIC_WAL_MB target (default 8MB).
        let blobs3 = try growWal(lattice, url: url, targetBytes: targetWalMB << 20, startSeq: blobs2)
        let s3 = probeChannel(url, label: "A1 wal>=\(targetWalMB)MB (+\(blobs3) blob commits)")
        let mainOnly3 = mainOnlyRows(url)
        print("FORENSIC A1: in_process_rows=\(inProcess1) main_only_rows=\(mainOnly3) main_growth=\(s3.mainBytes - s1.mainBytes)B")

        // Visibility: every committed write must be visible to fresh
        // connections. If these fail, live-WAL frames themselves are
        // externally invisible and the field's mechanism is baseline SQLite
        // state — they are the discriminating measurement.
        #expect(inProcess1 == 50)
        #expect(s1.rows == 50, "fresh reader sees \(s1.rows)/50 committed rows")
        #expect(s1.roRows == 50, "readonly fresh reader sees \(s1.roRows)/50")
        #expect(s2.blobs == blobs2, "fresh reader sees \(s2.blobs)/\(blobs2) blob commits")
        #expect(s3.blobs == blobs2 + blobs3)

        // Checkpoint starvation (field evidence 4): the custom wal hook
        // displaced autocheckpoint, so the WAL grows past every default
        // autocheckpoint boundary while main stays at its initial size.
        #expect(s3.walBytes >= targetWalMB << 20,
                Comment(rawValue: "wal only \(s3.walBytes)B — something checkpointed during "
                + "continuous writes (autocheckpoint alive after all?)"))
        print("FORENSIC A1 verdict: starvation_reproduced=\(s3.mainBytes == s1.mainBytes && s3.walBytes >= targetWalMB << 20)")
    }

    /// A2 — held observation machinery. Same stages as A1 with an `observe`
    /// token, a draining `changeStream` task, and a re-read Results facade
    /// alive the whole time — the relay's observer-push shape. Measures
    /// whether any of those pins fresh-reader visibility or checkpointability.
    @Test func freshReadersUnderHeldObservationAndResults() async throws {
        let dir = try forensicTempDir("a2")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "channel.sqlite")

        let lattice = try Lattice(for: [SimpleSyncObject.self, WalEpochBlob.self],
                                  configuration: SyncRelayApplyPolicy.configuration(fileURL: url, storeConfiguration: nil))
        let observed = LockedBox(0)
        let token = lattice.observe { batch in observed.withLock { $0 += batch.count } }
        defer { token.cancel() }
        let streamed = LockedBox(0)
        let stream = lattice.changeStream
        let streamTask = Task {
            for try await batch in stream {
                streamed.withLock { $0 += batch.count }
            }
        }
        defer { streamTask.cancel() }

        let results = lattice.objects(SimpleSyncObject.self)
        for i in 0..<50 { try lattice.add(SimpleSyncObject(value: i, floatValue: Float(i))) }
        let held1 = results.count
        let s1 = probeChannel(url, label: "A2 after 50 commits (observed)")

        let blobs = try growWal(lattice, url: url, targetBytes: 4 << 20, startSeq: 0)
        let held2 = results.count
        let s2 = probeChannel(url, label: "A2 wal>=4MB (\(blobs) blob commits, observed)")
        _ = await poll(timeout: 5) { observed.withLock { $0 } >= 50 }
        print("""
        FORENSIC A2: results_count=\(held1)->\(held2) observed_entries=\(observed.withLock { $0 }) \
        streamed=\(streamed.withLock { $0 }) main_growth=\(s2.mainBytes - s1.mainBytes)B
        """)

        #expect(held2 == 50)
        #expect(s1.rows == 50, "fresh reader under observation sees \(s1.rows)/50")
        #expect(s2.blobs == blobs, "fresh reader under observation sees \(s2.blobs)/\(blobs) blobs")
        #expect(observed.withLock { $0 } >= 50, "the observation itself must be live")

        // An external PASSIVE checkpoint tells us whether held observation
        // machinery pins the reader mark (checkpointed < log = pinned).
        let cp = externalCheckpoint(url, mode: "PASSIVE")
        print("FORENSIC A2 pin-check: passive busy=\(cp.busy) log=\(cp.log) checkpointed=\(cp.ckpt)")
    }

    /// A3 — THE INVISIBILITY SIGNATURE. One transaction BEGUN on the shared
    /// write connection and never committed (any wedged code path produces
    /// this state; sync.cpp:2830+ shows in-transaction work JOINING it and
    /// riding forever). Measures exactly who sees the epoch:
    /// in-process reads (lattice.hpp:3940 routes them through the write
    /// connection) vs fresh external connections vs VACUUM INTO backups vs a
    /// main-only restart view — then proves COMMIT flips all of them.
    @Test func openTransactionEpochInvisibilitySignature() async throws {
        let dir = try forensicTempDir("a3")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "channel.sqlite")
        try seedBaseline(url, rows: 25)

        let lattice = try Lattice(for: [SimpleSyncObject.self, WalEpochBlob.self],
                                  configuration: SyncRelayApplyPolicy.configuration(fileURL: url, storeConfiguration: nil))
        let s0 = probeChannel(url, label: "A3 boot state (25 baseline)")

        lattice.beginTransaction()
        var committedOutcome = "held-open"
        defer {
            if committedOutcome == "held-open" { lattice.rollbackTransaction() }
        }
        for i in 25..<125 { try lattice.add(SimpleSyncObject(value: i, floatValue: Float(i))) }

        let inProcess = lattice.objects(SimpleSyncObject.self).count
        let sLive = probeChannel(url, label: "A3 100 writes inside open txn")
        let vacuumLive = vacuumIntoRows(url)
        let mainOnlyLive = mainOnlyRows(url)
        print("""
        FORENSIC A3 wedged: in_process=\(inProcess) fresh=\(sLive.rows) ro=\(sLive.roRows) \
        vacuum_into=\(vacuumLive) main_only=\(mainOnlyLive) wal_growth=\(sLive.walBytes - s0.walBytes)B
        """)

        // The field signature: the process serves the epoch, nothing outside
        // can see it.
        #expect(inProcess == 125, "in-process reads must see the wedged epoch (read-your-writes routing)")
        #expect(sLive.rows == 25, "fresh reader sees \(sLive.rows) — expected the 25-row boot state")
        #expect(sLive.roRows == 25)
        #expect(vacuumLive == 25, "VACUUM INTO captured \(vacuumLive) rows — backups are the stale view")

        // COMMIT is the visibility event: everything flips at once.
        lattice.commitTransaction()
        committedOutcome = "committed"
        let sAfter = probeChannel(url, label: "A3 after COMMIT")
        #expect(sAfter.rows == 125, "commit must make the epoch visible to fresh readers (saw \(sAfter.rows))")
    }

    /// A4 — file-identity drift: an external actor unlinks -wal/-shm under the
    /// live writer (backup scripts, cleanup, restore tooling). The writer
    /// keeps committing into the UNLINKED wal without an error; fresh readers
    /// open the PATH and are pinned at the last checkpointed main state.
    /// This produces evidence-(1)'s exact shape with REAL commits.
    @Test func walUnlinkUnderLiveWriterPinsFreshReaders() async throws {
        let dir = try forensicTempDir("a4")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "channel.sqlite")
        try seedBaseline(url, rows: 25)

        let lattice = try Lattice(for: [SimpleSyncObject.self, WalEpochBlob.self],
                                  configuration: SyncRelayApplyPolicy.configuration(fileURL: url, storeConfiguration: nil))
        for i in 25..<75 { try lattice.add(SimpleSyncObject(value: i, floatValue: Float(i))) }
        let sBefore = probeChannel(url, label: "A4 before unlink (75 committed)")

        try? FileManager.default.removeItem(atPath: walPath(url))
        try? FileManager.default.removeItem(atPath: shmPath(url))
        print("FORENSIC A4: unlinked -wal and -shm under the live writer")

        var writeError = "none"
        var wroteAfterUnlink = 0
        do {
            for i in 75..<125 {
                try lattice.add(SimpleSyncObject(value: i, floatValue: Float(i)))
                wroteAfterUnlink += 1
            }
        } catch { writeError = String(describing: error) }
        let inProcess = lattice.objects(SimpleSyncObject.self).count
        let sAfter = probeChannel(url, label: "A4 post-unlink (wrote \(wroteAfterUnlink) more)")
        print("""
        FORENSIC A4: write_error=\(writeError) wrote_after_unlink=\(wroteAfterUnlink) \
        in_process=\(inProcess) fresh=\(sAfter.rows) wal_on_disk=\(sAfter.walBytes)B
        """)
        #expect(sBefore.rows == 75)
        // Deterministic core of the drift class: once the -wal is unlinked,
        // fresh connections can only serve the last-checkpointed MAIN state —
        // the 50 pre-unlink live commits vanished from every external view.
        #expect(sAfter.rows == 25,
                Comment(rawValue: "fresh readers must be pinned at the checkpointed main "
                + "state after the unlink (saw \(sAfter.rows), main holds 25)"))
        // What happens to the LIVE handle is measured, not presumed — two
        // shapes both reproduce in this harness:
        //   * a write-only holder (B5's child) keeps committing errorlessly
        //     into the unlinked inode — the silent-loss shape;
        //   * this handle, whose add() runs read-side existence probes after
        //     external processes re-created the -shm, fails LOUDLY
        //     ("table ... already exists" / empty reads) — the broken-handle
        //     shape. Either way the epoch is unreachable from the path.
        print("FORENSIC A4 verdict: live_handle=\(writeError == "none" ? "kept-writing-silently" : "broke-loudly")")
    }

    // MARK: - (B) Restart semantics (kill -9 a separate writer process)

    private func spawnChild(_ url: URL, mode: String, extra: [String] = []) throws -> WriterChild {
        try #require(FileManager.default.isExecutableFile(atPath: WriterChild.binaryURL.path),
                     "WalEpochWriterChild not built at \(WriterChild.binaryURL.path)")
        return try WriterChild(dbURL: url, mode: mode, extra: extra)
    }

    private func reopenAndCount(_ url: URL, label: String) throws -> (rows: Int, blobs: Int) {
        let l = try Lattice(for: [SimpleSyncObject.self, WalEpochBlob.self],
                            configuration: SyncRelayApplyPolicy.configuration(fileURL: url, storeConfiguration: nil))
        let rows = l.objects(SimpleSyncObject.self).count
        let blobs = l.objects(WalEpochBlob.self).count
        print("FORENSIC \(label): lattice_reopen rows=\(rows) blobs=\(blobs)")
        return (rows, blobs)
    }

    /// B1 — kill -9 mid-committed-epoch (the orbital shape): every committed
    /// transaction must survive a SIGKILL + reopen, whether the first
    /// post-restart reader is a bare sqlite3 or a fresh Lattice.
    @Test func killNineMidCommittedWritesRecoversEpoch() async throws {
        let dir = try forensicTempDir("b1")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "channel.sqlite")
        try seedBaseline(url, rows: 25)

        let child = try spawnChild(url, mode: "write-forever",
                                   extra: ["--payload-bytes", "8192", "--period-us", "500"])
        defer { child.terminateIfRunning() }
        try #require(await poll(timeout: 120) { child.lastCount(prefix: "COMMITTED") >= 300 },
                     "child never reached 300 commits; stderr: \(child.stderrTail)")
        child.killNine()
        let lastCommitted = child.lastCount(prefix: "COMMITTED")

        let sDead = probeChannel(url, label: "B1 after SIGKILL (last committed=\(lastCommitted))")
        let reopened = try reopenAndCount(url, label: "B1")
        let sReopened = probeChannel(url, label: "B1 after lattice reopen+close")

        print("FORENSIC B1: committed=\(lastCommitted) sqlite3_sees=\(sDead.blobs) lattice_sees=\(reopened.blobs) wal_after=\(sReopened.walBytes)B")
        #expect(reopened.rows == 25, "baseline rows survive")
        #expect(reopened.blobs >= lastCommitted,
                Comment(rawValue: "DURABILITY LOSS: \(lastCommitted) commits acknowledged, "
                + "\(reopened.blobs) recovered after kill -9"))
        #expect(reopened.blobs <= lastCommitted + 1, "at most the in-flight commit beyond the transcript")
        #expect(sDead.blobs == reopened.blobs, "bare sqlite3 recovery and Lattice recovery agree")
    }

    /// B2 — kill -9 while IDLE (writer stopped writing, handle still open):
    /// the field's evidence-(2) file shape. Everything committed must read
    /// back.
    @Test func killNineWhileIdleRecoversEpoch() async throws {
        let dir = try forensicTempDir("b2")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "channel.sqlite")
        try seedBaseline(url, rows: 25)

        let child = try spawnChild(url, mode: "write-then-idle",
                                   extra: ["--rows", "200", "--payload-bytes", "8192"])
        defer { child.terminateIfRunning() }
        try #require(await poll(timeout: 120) { child.sawLine(prefix: "IDLE") },
                     "child never went idle; stderr: \(child.stderrTail)")

        // The idle live file: what does a fresh reader see BEFORE the kill?
        let sIdle = probeChannel(url, label: "B2 idle live file (200 committed)")
        child.killNine()
        let reopened = try reopenAndCount(url, label: "B2")

        #expect(sIdle.blobs == 200, "idle live file serves all commits to fresh readers (saw \(sIdle.blobs))")
        #expect(reopened.rows == 25)
        #expect(reopened.blobs == 200,
                Comment(rawValue: "DURABILITY LOSS: 200 idle-committed rows, \(reopened.blobs) after kill"))
    }

    /// B3 — kill -9, then the -shm is deleted before anything reopens the
    /// file (tmpfiles cleaners, cross-mount restores). Recovery must rebuild
    /// the wal-index from the -wal alone.
    @Test func killNineThenShmDeleteStillRecovers() async throws {
        let dir = try forensicTempDir("b3")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "channel.sqlite")
        try seedBaseline(url, rows: 25)

        let child = try spawnChild(url, mode: "write-forever",
                                   extra: ["--payload-bytes", "8192", "--period-us", "500"])
        defer { child.terminateIfRunning() }
        try #require(await poll(timeout: 120) { child.lastCount(prefix: "COMMITTED") >= 200 })
        child.killNine()
        let lastCommitted = child.lastCount(prefix: "COMMITTED")

        try? FileManager.default.removeItem(atPath: shmPath(url))
        print("FORENSIC B3: deleted -shm after SIGKILL (last committed=\(lastCommitted))")
        let sDead = probeChannel(url, label: "B3 no-shm recovery via sqlite3")
        let reopened = try reopenAndCount(url, label: "B3")

        #expect(reopened.blobs >= lastCommitted,
                Comment(rawValue: "shm deletion turned recovery lossy: \(lastCommitted) committed, "
                + "\(reopened.blobs) recovered"))
        #expect(sDead.blobs >= lastCommitted)
    }

    /// B4 — THE JOYJET SHAPE. kill -9 while the epoch sits in one open,
    /// never-committed transaction (the A3 wedge, held by a real process).
    /// Prediction: fresh readers see only the boot state while the child
    /// lives; after the kill the epoch does not exist anywhere — main
    /// untouched, recovery finds no commit record.
    @Test func killNineMidOpenTransactionDiscardsEpoch() async throws {
        let dir = try forensicTempDir("b4")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "channel.sqlite")
        try seedBaseline(url, rows: 25)

        let child = try spawnChild(url, mode: "open-txn-writes",
                                   extra: ["--rows", "400", "--payload-bytes", "8192"])
        defer { child.terminateIfRunning() }
        try #require(await poll(timeout: 120) { child.sawLine(prefix: "EPOCH-OPEN") },
                     "child never reported the open epoch; stderr: \(child.stderrTail)")
        let epochWrites = child.lastCount(prefix: "UNCOMMITTED")

        // Cross-process confirmation of the A3 signature under a REAL
        // separate writer process.
        let sLive = probeChannel(url, label: "B4 live wedged child (\(epochWrites) uncommitted writes)")
        let mainOnlyLive = mainOnlyRows(url)
        print("FORENSIC B4 live: fresh_blobs=\(sLive.blobs) main_only_rows=\(mainOnlyLive) wal=\(sLive.walBytes)B (cache spill if >0 growth)")

        child.killNine()
        let sDead = probeChannel(url, label: "B4 after SIGKILL")
        let reopened = try reopenAndCount(url, label: "B4")
        let sFinal = probeChannel(url, label: "B4 after lattice reopen+close")

        #expect(sLive.blobs == 0, "the wedged epoch must be invisible to fresh readers while live (saw \(sLive.blobs))")
        #expect(reopened.rows == 25, "boot state survives")
        #expect(reopened.blobs == 0,
                Comment(rawValue: "the never-committed epoch (\(epochWrites) writes) must be "
                + "DISCARDED on restart — recovered \(reopened.blobs)"))
        print("FORENSIC B4: epoch_writes=\(epochWrites) discarded=\(reopened.blobs == 0) wal_final=\(sFinal.walBytes)B main_final=\(sDead.mainBytes)B")
    }

    /// B5 — kill -9 after an external actor unlinked the -wal under the live
    /// writer (the A4 drift, then a restart). The writer committed happily
    /// into the unlinked inode; the kill frees it. Reopen serves only the
    /// last checkpointed main — evidence-(3)'s "main untouched, wal reset,
    /// epoch gone".
    @Test func killNineAfterWalUnlinkLosesCommittedEpoch() async throws {
        let dir = try forensicTempDir("b5")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "channel.sqlite")
        try seedBaseline(url, rows: 25)

        let child = try spawnChild(url, mode: "write-forever",
                                   extra: ["--payload-bytes", "8192", "--period-us", "500"])
        defer { child.terminateIfRunning() }
        try #require(await poll(timeout: 120) { child.lastCount(prefix: "COMMITTED") >= 100 })

        try? FileManager.default.removeItem(atPath: walPath(url))
        try? FileManager.default.removeItem(atPath: shmPath(url))
        let unlinkMark = child.lastCount(prefix: "COMMITTED")
        print("FORENSIC B5: unlinked -wal/-shm at commit #\(unlinkMark); child keeps writing")

        try #require(await poll(timeout: 120) { child.lastCount(prefix: "COMMITTED") >= unlinkMark + 100 },
                     "child stopped committing after the unlink; stderr: \(child.stderrTail)")
        let sLive = probeChannel(url, label: "B5 live writer on unlinked wal")
        child.killNine()
        let lastCommitted = child.lastCount(prefix: "COMMITTED")

        let sDead = probeChannel(url, label: "B5 after SIGKILL")
        let reopened = try reopenAndCount(url, label: "B5")
        print("""
        FORENSIC B5: committed=\(lastCommitted) recovered_blobs=\(reopened.blobs) \
        lost=\(lastCommitted - reopened.blobs) main=\(sDead.mainBytes)B
        """)
        // The child COMMITTED lastCommitted transactions and got OK for every
        // one; how many survive is the measurement (expected: only what was
        // checkpointed into main before the unlink — a real durability hole).
        #expect(reopened.rows == 25)
        #expect(sLive.blobs < lastCommitted,
                "fresh readers must already be blind to post-unlink commits while the writer lives")
    }

    // MARK: - (C) The external checkpoint lever (interim ops procedure)

    /// C — while a live writer holds a multi-MB un-checkpointed WAL (the
    /// healthy variant of the field state), run PASSIVE and TRUNCATE
    /// checkpoints from a fresh external sqlite3. Decides the ops verdict:
    /// integrate / no-op / misbehave — plus the same lever against the A3
    /// wedge state.
    @Test func externalCheckpointLeverOnLiveWriter() async throws {
        let dir = try forensicTempDir("c")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "channel.sqlite")

        let lattice = try Lattice(for: [SimpleSyncObject.self, WalEpochBlob.self],
                                  configuration: SyncRelayApplyPolicy.configuration(fileURL: url, storeConfiguration: nil))
        for i in 0..<50 { try lattice.add(SimpleSyncObject(value: i, floatValue: Float(i))) }
        let blobs = try growWal(lattice, url: url, targetBytes: 4 << 20, startSeq: 0)
        let sBefore = probeChannel(url, label: "C before lever (\(blobs) blobs)")
        let mainOnlyBefore = mainOnlyRows(url)

        // PASSIVE from outside, writer live.
        let passive = externalCheckpoint(url, mode: "PASSIVE")
        let sPassive = probeChannel(url, label: "C after external PASSIVE")
        let mainOnlyPassive = mainOnlyRows(url)
        print("FORENSIC C: main_only_rows \(mainOnlyBefore) -> \(mainOnlyPassive) (passive integrated=\(mainOnlyPassive > mainOnlyBefore))")

        // Writer must be unharmed and still visible.
        for i in 50..<70 { try lattice.add(SimpleSyncObject(value: i, floatValue: Float(i))) }
        let sAfterWrites = probeChannel(url, label: "C writer continues after PASSIVE")

        // TRUNCATE from outside, writer live but between transactions.
        let truncate = externalCheckpoint(url, mode: "TRUNCATE")
        let sTruncate = probeChannel(url, label: "C after external TRUNCATE")

        // Writer continues again.
        for i in 70..<90 { try lattice.add(SimpleSyncObject(value: i, floatValue: Float(i))) }
        let sEnd = probeChannel(url, label: "C writer continues after TRUNCATE")

        #expect(passive.busy == 0, "external PASSIVE must not report busy against an idle-between-commits writer")
        #expect(passive.ckpt > 0, "external PASSIVE checkpointed \(passive.ckpt) frames — expected it to integrate the backlog")
        #expect(sPassive.mainBytes > sBefore.mainBytes, "main must advance after external PASSIVE")
        #expect(mainOnlyPassive > mainOnlyBefore, "the durable-in-main view must include integrated frames")
        #expect(sAfterWrites.rows == 70, "writer commits remain externally visible after the lever")
        #expect(sTruncate.walBytes <= 4096, "TRUNCATE should rewind the wal (size \(sTruncate.walBytes)B)")
        #expect(sEnd.rows == 90, "writer unharmed after TRUNCATE (fresh sees \(sEnd.rows)/90)")
        print("FORENSIC C verdict: passive=\(passive.busy == 0 && passive.ckpt > 0 ? "INTEGRATES" : "raw=\(passive.raw)") truncate_busy=\(truncate.busy)")

        // The lever against the WEDGE state: only committed frames can
        // integrate; the open transaction's tail must not, and nothing may
        // corrupt the writer.
        lattice.beginTransaction()
        for i in 90..<140 { try lattice.add(SimpleSyncObject(value: i, floatValue: Float(i))) }
        let passiveWedge = externalCheckpoint(url, mode: "PASSIVE")
        let truncateWedge = externalCheckpoint(url, mode: "TRUNCATE")
        lattice.commitTransaction()
        let sCommitted = probeChannel(url, label: "C wedge committed after levers")
        print("FORENSIC C wedge: passive=(\(passiveWedge.busy),\(passiveWedge.log),\(passiveWedge.ckpt)) truncate=(\(truncateWedge.busy),\(truncateWedge.log),\(truncateWedge.ckpt))")
        #expect(sCommitted.rows == 140, "the wedged epoch commits intact after external levers ran mid-wedge")
    }

    // MARK: - (D) The in-process Swift-side lever

    /// D — `Lattice.checkpointBounded` called ON the relay's own live handle
    /// (the candidate 1.7.2 fix: periodic checkpoints from the relay).
    /// Measures: frames integrated, wal truncation, external visibility of
    /// main, behavior under a held external reader (busy fallback), and
    /// behavior while wedged.
    @Test func checkpointBoundedOnRelayHandleInProcess() async throws {
        let dir = try forensicTempDir("d")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "channel.sqlite")

        let lattice = try Lattice(for: [SimpleSyncObject.self, WalEpochBlob.self],
                                  configuration: SyncRelayApplyPolicy.configuration(fileURL: url, storeConfiguration: nil))
        for i in 0..<50 { try lattice.add(SimpleSyncObject(value: i, floatValue: Float(i))) }
        let blobs = try growWal(lattice, url: url, targetBytes: 4 << 20, startSeq: 0)
        let sBefore = probeChannel(url, label: "D before checkpointBounded (\(blobs) blobs)")

        let frames1 = lattice.checkpointBounded(busyBudgetMs: 250)
        let sAfter = probeChannel(url, label: "D after checkpointBounded")
        let mainOnly = mainOnlyRows(url)
        print("FORENSIC D: frames=\(frames1) wal \(sBefore.walBytes)B -> \(sAfter.walBytes)B main_only_rows=\(mainOnly)")

        // Return-value quirk (measured): a fully-successful TRUNCATE reports
        // (busy=0, log=0, checkpointed=0) — the pragma answers AFTER the
        // rewind — so checkpointBounded returns 0 on its BEST outcome and
        // only reports a positive frame count on the PASSIVE fallback.
        // Callers of the periodic-checkpoint fix must not treat 0 as failure;
        // -1 is the only "nothing could run" signal.
        #expect(frames1 >= 0, "checkpointBounded on the live relay handle returned \(frames1)")
        #expect(sAfter.walBytes < sBefore.walBytes, "wal must rewind after a successful TRUNCATE checkpoint")
        #expect(sAfter.mainBytes > sBefore.mainBytes, "main must advance")
        #expect(mainOnly == 50, "all rows durable in main after the in-process lever")

        // Under a held external READ transaction (the starvation scenario):
        // TRUNCATE must fail fast and fall back to PASSIVE per the bridge
        // (lattice.hpp bridge:912-926), not stall the writer.
        let more = try growWal(lattice, url: url, targetBytes: 2 << 20, startSeq: blobs)
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        holder.arguments = [url.path]
        let holderIn = Pipe()
        holder.standardInput = holderIn
        holder.standardOutput = FileHandle.nullDevice
        holder.standardError = FileHandle.nullDevice
        try holder.run()
        holderIn.fileHandleForWriting.write(Data("BEGIN; SELECT count(*) FROM WalEpochBlob;\n".utf8))
        try await Task.sleep(nanoseconds: 400_000_000)

        let t0 = DispatchTime.now()
        let frames2 = lattice.checkpointBounded(busyBudgetMs: 250)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds &- t0.uptimeNanoseconds) / 1e6
        let sHeld = probeChannel(url, label: "D checkpointBounded under held external reader (+\(more) blobs)")
        print("FORENSIC D held-reader: frames=\(frames2) elapsed_ms=\(String(format: "%.0f", elapsedMs)) wal=\(sHeld.walBytes)B")
        #expect(elapsedMs < 5_000, "bounded checkpoint must not park behind a held reader")

        holderIn.fileHandleForWriting.write(Data("COMMIT;\n.quit\n".utf8))
        try? holderIn.fileHandleForWriting.close()
        _ = await poll(timeout: 5) { !holder.isRunning }  // bounded (see killNine note)
        if holder.isRunning { kill(holder.processIdentifier, SIGKILL) }

        // After the reader releases, the next bounded call truncates.
        let frames3 = lattice.checkpointBounded(busyBudgetMs: 250)
        let sReleased = probeChannel(url, label: "D checkpointBounded after reader release")
        print("FORENSIC D: post-release frames=\(frames3) wal=\(sReleased.walBytes)B")
        #expect(sReleased.walBytes <= 4096, "wal must rewind once the held reader is gone (size \(sReleased.walBytes)B)")

        // While wedged: the same connection holds the open transaction, so
        // the lever cannot run — measure what it returns (must not throw,
        // must not commit or corrupt the wedge).
        lattice.beginTransaction()
        for i in 50..<80 { try lattice.add(SimpleSyncObject(value: i, floatValue: Float(i))) }
        let framesWedged = lattice.checkpointBounded(busyBudgetMs: 250)
        let inTxnAfter = lattice.objects(SimpleSyncObject.self).count
        lattice.rollbackTransaction()
        let sWedge = probeChannel(url, label: "D checkpointBounded while wedged (rolled back)")
        print("FORENSIC D wedged: frames=\(framesWedged) in_txn_rows=\(inTxnAfter) post_rollback_fresh=\(sWedge.rows)")
        #expect(inTxnAfter == 80, "the lever must not disturb the open transaction")
        #expect(sWedge.rows == 50, "rollback still discards the wedge after the lever ran")
    }
}
