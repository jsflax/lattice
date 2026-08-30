import Foundation
import Combine
import Lattice

// ============================================================================
// WAL-epoch forensics writer child (see WalEpochForensicsTests.swift).
//
// A separate PROCESS holding a relay-shaped Lattice handle over a channel
// file, so the harness can kill -9 it and measure what a restart recovers.
// "Relay-shaped" = the exact configuration `SyncRelayApplyPolicy.configuration`
// produces for a channel store: the library `Configuration(fileURL:)` with
// `busyTimeoutMs = 2_000` (RelayApply.swift:76,115-124). This target links
// only Lattice (no Vapor) and mirrors that shape verbatim.
//
// Models live in Models.swift (same module).
//
// Protocol on stdout (line-buffered):
//   OPENED pid=<pid>
//   COMMITTED <n>      after every committed write transaction
//   UNCOMMITTED <n>    after every write inside the held-open transaction
//   EPOCH-OPEN <n>     the open transaction now holds n writes; child idles
//   IDLE <n>           burst finished; handle stays open, process sleeps
//
// Modes:
//   write-forever    [--payload-bytes P] [--period-us U] [--observe]
//   write-then-idle  --rows N [--payload-bytes P] [--observe]
//   open-txn-writes  --rows N [--payload-bytes P] [--observe]
//       BEGINs one write transaction, performs N writes, NEVER commits —
//       the wedged-epoch shape (fresh readers pinned at pre-BEGIN state).
// ============================================================================

@MainActor
func run() throws {
    setvbuf(stdout, nil, _IOLBF, 0)  // line-buffered even when piped

    let args = CommandLine.arguments

    func opt(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    guard args.count >= 3 else {
        FileHandle.standardError.write(Data("""
        usage: WalEpochWriterChild <dbPath> <mode> [--rows N] [--payload-bytes P] \
        [--period-us U] [--observe]\n
        """.utf8))
        exit(2)
    }

    let dbPath = args[1]
    let mode = args[2]
    let rows = Int(opt("--rows") ?? "200") ?? 200
    let payloadBytes = Int(opt("--payload-bytes") ?? "0") ?? 0
    let periodUs = UInt32(opt("--period-us") ?? "2000") ?? 2000
    let holdObservation = args.contains("--observe")

    // The relay's channel-store open shape (SyncRelayApplyPolicy.configuration):
    // library configuration + the relay busy budget.
    let lattice = try Lattice(
        for: [SimpleSyncObject.self, WalEpochBlob.self],
        configuration: .init(fileURL: URL(fileURLWithPath: dbPath), busyTimeoutMs: 2_000))

    var observationToken: AnyCancellable?
    if holdObservation {
        observationToken = lattice.observe { _ in }
    }

    print("OPENED pid=\(ProcessInfo.processInfo.processIdentifier)")

    let payload = payloadBytes > 0 ? String(repeating: "x", count: payloadBytes) : ""
    var written = 0

    func writeOne(_ i: Int) throws {
        if payloadBytes > 0 {
            try lattice.add(WalEpochBlob(seq: i, payload: payload))
        } else {
            try lattice.add(SimpleSyncObject(value: i, floatValue: Float(i)))
        }
        written += 1
    }

    switch mode {
    case "write-forever":
        var i = 0
        while true {
            try writeOne(i)
            print("COMMITTED \(written)")
            i += 1
            if periodUs > 0 { usleep(periodUs) }
        }

    case "write-then-idle":
        for i in 0..<rows {
            try writeOne(i)
            print("COMMITTED \(written)")
        }
        print("IDLE \(written)")
        _ = observationToken  // keep the observation alive while idling
        while true { sleep(1) }

    case "open-txn-writes":
        lattice.beginTransaction()
        for i in 0..<rows {
            try writeOne(i)
            print("UNCOMMITTED \(written)")
        }
        print("EPOCH-OPEN \(written)")
        _ = observationToken
        while true { sleep(1) }  // never commits — killed by the harness

    default:
        FileHandle.standardError.write(Data("unknown mode: \(mode)\n".utf8))
        exit(2)
    }
}

try run()
