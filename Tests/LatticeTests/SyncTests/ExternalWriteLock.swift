import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One fixture-owned sqlite3 child. Foundation never owns or reaps this child.
/// Only `queue` reads/writes/closes its descriptors, waits for it, or signals it.
final class ExternalWriteLock: @unchecked Sendable {
    struct Timing: Sendable, Equatable {
        var heldObservedNS: UInt64?
        var releaseRequestedNS: UInt64?
        var releaseObservedNS: UInt64?
        var processExitObservedNS: UInt64?
        var stdoutEOFObservedNS: UInt64?
        var exitStatus: Int32?
        var exitedNormally = false

        func confirmsHeld(at time: UInt64) -> Bool {
            guard let heldObservedNS, heldObservedNS <= time else { return false }
            return releaseRequestedNS.map { time < $0 } ?? true
        }
    }

    struct SignalAttempt: Sendable, Equatable {
        let signal: Int32
        let atNS: UInt64
        let error: Int32?
    }

    struct ReleaseResult: Sendable, Equatable {
        let releaseID: UUID
        let childPID: Int32
        let spawnObservedNS: UInt64
        let timing: Timing
        let success: Bool
        let cleanupComplete: Bool
        let childReaped: Bool
        let rawWaitStatus: Int32?
        let stdoutEOF: Bool
        let releaseWritesCompleted: Int
        let signals: [SignalAttempt]
        let failures: [String]
    }

    private struct Snapshot {
        var timing = Timing()
        var ownedUnreaped = false
        var failed = false
    }

    private struct SetupError: Error, CustomStringConvertible {
        let operation: String
        let code: Int32
        var description: String { "ExternalWriteLock \(operation): errno/code \(code)" }
    }

    private struct ChildDisposition: Equatable {
        let handler: UInt
        let flags: Int32
    }

    private static let acquireScript = ".bail on\nBEGIN IMMEDIATE;\nSELECT 'LOCKHELD';\n"
    private static let releaseScript = "COMMIT;\nSELECT 'LOCKRELEASED';\n.quit\n"
    private let queue = DispatchQueue(label: "LatticeTests.ExternalWriteLock")
    private let snapshot = LockedBox(Snapshot())
    private var timer: DispatchSourceTimer?
    private var child: pid_t = 0
    private var spawnObservedNS: UInt64 = 0
    private var signalAuthority = false
    private var spawnDisposition: ChildDisposition?
    private var childReaped = false
    private var waitStatus: Int32?
    private var controlFD: Int32 = -1
    private var stdoutFD: Int32 = -1
    private var closeFailed = false
    private var output = [UInt8]()
    private var outputLine = [UInt8]()
    private var stdoutEOF = false
    private var pendingInput = [UInt8]()
    private var inputOffset = 0
    private var releaseID: UUID?
    private var normalEnd: UInt64 = 0
    private var termEnd: UInt64 = 0
    private var finalEnd: UInt64 = 0
    private var termAttempted = false
    private var killAttempted = false
    private var releaseWritesCompleted = 0
    private var signals = [SignalAttempt]()
    private var failures = [String]()
    private var result: ReleaseResult?
    private var waiters = [CheckedContinuation<ReleaseResult, Never>]()

    var timingSnapshot: Timing { snapshot.withLock { $0.timing } }
    // A recent owned-child observation, just as the old Process.isRunning check
    // was a snapshot. Completion requires the actual wait status, never this flag.
    var isRunning: Bool { snapshot.withLock { $0.ownedUnreaped } }

    init(path: String, acquisitionScript: String? = nil) throws {
        let acquisition = acquisitionScript ?? Self.acquireScript
        guard !path.utf8.contains(0), acquisition.utf8.count <= 256, !acquisition.utf8.contains(0) else {
            throw SetupError(operation: "fixture input bounds", code: EINVAL)
        }
        var temporaryFDs = Set<Int32>()
        defer { for fd in temporaryFDs { _ = close(fd) } }
        func check(_ code: Int32, _ operation: String) throws {
            if code != 0 { throw SetupError(operation: operation, code: code) }
        }
        func checkedFD(_ fd: Int32, _ operation: String) throws -> Int32 {
            if fd >= 0 { temporaryFDs.insert(fd) }
            guard fd >= 3 else { throw SetupError(operation: operation, code: fd < 0 ? errno : EBADF) }
            return fd
        }

        // Default SIGCHLD is necessary, not sufficient: the enclosing process
        // must also have no unrelated waitpid(-1)/wait4 reaper. We cannot make
        // arbitrary process-global reapers safe by observing a PID/disposition.
        // Never install/change a process-wide signal policy for this fixture.
        spawnDisposition = try Self.defaultChildDisposition()

        var input = [Int32](repeating: -1, count: 2)
        #if canImport(Darwin)
        let socketType = SOCK_STREAM
        #else
        let socketType = Int32(SOCK_STREAM.rawValue)
        #endif
        guard socketpair(AF_UNIX, socketType, 0, &input) == 0 else {
            throw SetupError(operation: "control socketpair", code: errno)
        }
        // Own both descriptors before validating either one.
        temporaryFDs.formUnion(input)
        let inputParent = try checkedFD(input[0], "parent control descriptor")
        let inputChild = try checkedFD(input[1], "child control descriptor")
        var stdout = [Int32](repeating: -1, count: 2)
        guard pipe(&stdout) == 0 else { throw SetupError(operation: "stdout pipe", code: errno) }
        temporaryFDs.formUnion(stdout)
        let outputParent = try checkedFD(stdout[0], "parent stdout descriptor")
        let outputChild = try checkedFD(stdout[1], "child stdout descriptor")
        let null = try checkedFD(open("/dev/null", O_WRONLY), "stderr descriptor")
        for fd in temporaryFDs {
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
                throw SetupError(operation: "close-on-exec descriptor", code: errno)
            }
        }
        for fd in [inputParent, outputParent] {
            let flags = fcntl(fd, F_GETFL, 0)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw SetupError(operation: "nonblocking parent descriptor", code: errno)
            }
        }
        #if canImport(Darwin)
        var one: Int32 = 1
        guard setsockopt(inputParent, SOL_SOCKET, SO_NOSIGPIPE, &one,
                         socklen_t(MemoryLayout.size(ofValue: one))) == 0 else {
            throw SetupError(operation: "control SO_NOSIGPIPE", code: errno)
        }
        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        try check(posix_spawn_file_actions_init(&actions), "spawn file actions")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes), "spawn attributes")
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawn_file_actions_adddup2(&actions, inputChild, STDIN_FILENO), "spawn stdin")
        try check(posix_spawn_file_actions_adddup2(&actions, outputChild, STDOUT_FILENO), "spawn stdout")
        try check(posix_spawn_file_actions_adddup2(&actions, null, STDERR_FILENO), "spawn stderr")
        var flags = Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        #if canImport(Darwin)
        flags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #else
        // glibc close-from is present on the pinned Noble CI image. Resolve the
        // extension explicitly; an unsupported host fails before launching a child.
        typealias AddCloseFrom = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
        guard let symbol = dlsym(nil, "posix_spawn_file_actions_addclosefrom_np") else {
            throw SetupError(operation: "spawn close-from unavailable", code: ENOSYS)
        }
        let addCloseFrom = unsafeBitCast(symbol, to: AddCloseFrom.self)
        try withUnsafeMutablePointer(to: &actions) {
            try check(addCloseFrom(UnsafeMutableRawPointer($0), 3), "spawn close-from")
        }
        #endif
        var defaults = sigset_t()
        var mask = sigset_t()
        sigemptyset(&defaults)
        sigemptyset(&mask)
        for signal in [SIGTERM, SIGINT, SIGPIPE] { sigaddset(&defaults, signal) }
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults), "spawn signal defaults")
        try check(posix_spawnattr_setsigmask(&attributes, &mask), "spawn signal mask")
        try check(posix_spawnattr_setflags(&attributes, flags), "spawn flags")
        var pid: pid_t = 0
        let environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }.sorted()
        guard try Self.defaultChildDisposition() == spawnDisposition else {
            throw SetupError(operation: "SIGCHLD disposition changed before spawn", code: ECHILD)
        }
        let code = try Self.withStrings(["/usr/bin/sqlite3", path]) { argv in
            try Self.withStrings(environment) { env in
                posix_spawn(&pid, "/usr/bin/sqlite3", &actions, &attributes, argv, env)
            }
        }
        try check(code, "posix_spawn sqlite3")
        // No throwing operation follows successful spawn: this owner now must
        // retain and dispose of the child, including post-spawn setup failures.
        child = pid
        spawnObservedNS = DispatchTime.now().uptimeNanoseconds
        signalAuthority = true
        controlFD = inputParent
        stdoutFD = outputParent
        temporaryFDs.remove(inputParent)
        temporaryFDs.remove(outputParent)
        for fd in temporaryFDs {
            if close(fd) != 0 { fail("close child-side descriptor: \(errno)"); closeFailed = true }
        }
        temporaryFDs.removeAll()
        pendingInput = Array(acquisition.utf8)
        snapshot.withLock { $0.ownedUnreaped = true }
        let source = DispatchSource.makeTimerSource(queue: queue)
        timer = source
        source.setEventHandler { [self] in tick() }
        source.schedule(deadline: .now(), repeating: .milliseconds(10))
        source.resume()
    }

    private static func withStrings<R>(_ values: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> R) throws -> R {
        var strings = values.map { strdup($0) }
        defer { for string in strings { free(string) } }
        guard strings.allSatisfy({ $0 != nil }) else { throw SetupError(operation: "spawn strings", code: ENOMEM) }
        strings.append(nil)
        return try strings.withUnsafeMutableBufferPointer { try body($0.baseAddress!) }
    }

    private static func defaultChildDisposition() throws -> ChildDisposition {
        var disposition = sigaction()
        guard sigaction(SIGCHLD, nil, &disposition) == 0 else {
            throw SetupError(operation: "read SIGCHLD disposition", code: errno)
        }
        // With SA_SIGINFO the union denotes a different handler signature. Reject
        // that mode before interpreting the ordinary handler representation.
        guard disposition.sa_flags & (SA_SIGINFO | SA_NOCLDWAIT) == 0 else {
            throw SetupError(operation: "SIGCHLD siginfo/automatic reaping is incompatible", code: ECHILD)
        }
        #if canImport(Darwin)
        let handler = unsafeBitCast(disposition.__sigaction_u.__sa_handler, to: UInt.self)
        #else
        let handler = unsafeBitCast(disposition.__sigaction_handler.sa_handler, to: UInt.self)
        #endif
        guard handler == unsafeBitCast(SIG_DFL, to: UInt.self) else {
            throw SetupError(operation: "custom/ignored SIGCHLD handler is incompatible", code: ECHILD)
        }
        // SIG_DFL has no user handler whose execution mask could reap a child.
        // sigset_t is opaque: unused bytes are not a stable semantic identity.
        // The handler and forbidden reaping flags above are the custody boundary.
        return ChildDisposition(handler: handler, flags: disposition.sa_flags)
    }

    private func custodyDispositionUnchanged() -> Bool {
        do {
            guard try Self.defaultChildDisposition() == spawnDisposition else {
                throw SetupError(operation: "SIGCHLD disposition changed after spawn", code: ECHILD)
            }
            return true
        } catch {
            // A foreign reaper may now have consumed this child. Do not signal or
            // later wait on a potentially reassigned numeric PID. This loses
            // custody and therefore cannot claim reap/complete cleanup.
            signalAuthority = false
            snapshot.withLock { $0.ownedUnreaped = false }
            fail("child custody disposition unavailable: \(error)")
            return false
        }
    }

    func waitUntilHeld(timeout: TimeInterval) async -> Bool {
        let end = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1e9)
        while DispatchTime.now().uptimeNanoseconds < end {
            let state = snapshot.withLock { $0 }
            if state.failed || !state.ownedUnreaped { return false }
            if state.timing.heldObservedNS != nil { return true }
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { return false }
        }
        return false
    }

    /// Caller cancellation cannot abandon child disposal or create another owner.
    func release() async -> ReleaseResult {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if let result { continuation.resume(returning: result); return }
                waiters.append(continuation)
                beginRelease()
                tick()
            }
        }
    }

    private func fail(_ reason: String) {
        if failures.count < 8 && !failures.contains(reason) { failures.append(reason) }
        snapshot.withLock { $0.failed = true }
    }

    private func beginRelease() {
        guard releaseID == nil else { return }
        releaseID = UUID()
        let now = DispatchTime.now().uptimeNanoseconds
        snapshot.withLock { $0.timing.releaseRequestedNS = now }
        normalEnd = now + 2_000_000_000
        termEnd = now + 3_000_000_000
        finalEnd = now + 4_000_000_000
        pendingInput += Self.releaseScript.utf8
    }

    private func closeOwned(_ fd: inout Int32, _ name: String) {
        guard fd >= 0 else { return }
        let owned = fd
        fd = -1 // Never retry an uncertain close against a potentially reused fd.
        if close(owned) != 0 { closeFailed = true; fail("close \(name): \(errno)") }
    }

    private func sendInput() {
        guard controlFD >= 0, inputOffset < pendingInput.count else { return }
        #if canImport(Darwin)
        let sendFlags = MSG_DONTWAIT
        #else
        let sendFlags = Int32(MSG_DONTWAIT | MSG_NOSIGNAL)
        #endif
        let sent = pendingInput.withUnsafeBytes {
            send(controlFD, $0.baseAddress!.advanced(by: inputOffset), $0.count - inputOffset, sendFlags)
        }
        if sent > 0 { inputOffset += sent }
        else if sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { return }
        else { fail("control send: \(sent < 0 ? errno : EIO)"); closeOwned(&controlFD, "control"); return }
        if releaseID != nil && inputOffset == pendingInput.count {
            releaseWritesCompleted = 1
            closeOwned(&controlFD, "control")
        }
    }

    private func drainOutput() {
        guard stdoutFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 512)
        for _ in 0..<8 {
            let count = read(stdoutFD, &buffer, 512)
            if count == 0 {
                stdoutEOF = true
                snapshot.withLock { $0.timing.stdoutEOFObservedNS = DispatchTime.now().uptimeNanoseconds }
                closeOwned(&stdoutFD, "stdout")
                return
            }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                fail("stdout read: \(errno)"); closeOwned(&stdoutFD, "stdout"); return
            }
            guard output.count + count <= 4096 else {
                fail("stdout protocol exceeded 4096 bytes"); closeOwned(&stdoutFD, "stdout"); return
            }
            output += buffer.prefix(count)
            for byte in buffer.prefix(count) {
                if byte == 10 {
                    let line = String(decoding: outputLine, as: UTF8.self)
                    let now = DispatchTime.now().uptimeNanoseconds
                    snapshot.withLock {
                        if line == "LOCKHELD", $0.timing.heldObservedNS == nil { $0.timing.heldObservedNS = now }
                        if line == "LOCKRELEASED", $0.timing.releaseObservedNS == nil { $0.timing.releaseObservedNS = now }
                    }
                    outputLine.removeAll(keepingCapacity: true)
                } else { outputLine.append(byte) }
            }
        }
    }

    private func observeExit() {
        guard signalAuthority, custodyDispositionUnchanged() else { return }
        var status: Int32 = 0
        let waited = waitpid(child, &status, WNOHANG)
        if waited == 0 { return }
        if waited < 0 {
            if errno == EINTR { return }
            let code = errno
            signalAuthority = false
            snapshot.withLock { $0.ownedUnreaped = false }
            fail("waitpid custody unavailable: \(code)") // ECHILD never licenses a signal.
            return
        }
        guard waited == child else {
            fail("waitpid returned unexpected child")
            signalAuthority = false
            snapshot.withLock { $0.ownedUnreaped = false }
            return
        }
        // Darwin and Linux encode terminal status in these documented wait bits.
        // No WUNTRACED/WCONTINUED is requested; a nonterminal status is not a reap.
        let low = status & 0x7f
        guard low != 0x7f else { fail("nonterminal wait status"); return }
        signalAuthority = false // Revoke before any continuation can run.
        childReaped = true
        waitStatus = status
        let normal = low == 0
        let code = normal ? (status >> 8) & 0xff : low
        snapshot.withLock {
            $0.ownedUnreaped = false
            $0.timing.processExitObservedNS = DispatchTime.now().uptimeNanoseconds
            $0.timing.exitedNormally = normal
            $0.timing.exitStatus = code
        }
        if releaseID == nil { fail("child exited before release admission") }
        if !normal || code != 0 { fail("child terminal status: \(status)") }
    }

    private func signalOwned(_ number: Int32) {
        observeExit()
        // Recheck immediately before escalation too. This is a fail-closed
        // observation, not immunity from an arbitrary concurrent global reaper.
        guard signalAuthority, custodyDispositionUnchanged() else { return }
        // This is the unreaped direct spawn, on its sole waiter queue. It is not
        // an observed/reconstructed PID and cannot be reused before this owner reaps.
        let now = DispatchTime.now().uptimeNanoseconds
        let rc = kill(child, number)
        let error = rc == 0 ? nil : errno
        signals.append(SignalAttempt(signal: number, atNS: now, error: error))
        fail("forced child disposal: \(number)")
        if let error { fail("child signal error: \(error)") }
    }

    private func tick() {
        if result != nil {
            // A bounded failed join never abandons an unreaped child. Retain
            // custody and observe only; no later signal or result revision.
            observeExit()
            if !signalAuthority { stopTimer() }
            return
        }
        sendInput()
        drainOutput()
        observeExit()
        if !failures.isEmpty { beginRelease() }
        guard releaseID != nil else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if now >= normalEnd {
            fail("normal release deadline exceeded")
            if !termAttempted { termAttempted = true; signalOwned(SIGTERM) }
        }
        if now >= termEnd && !killAttempted { killAttempted = true; signalOwned(SIGKILL) }
        if childReaped && stdoutEOF && controlFD < 0 {
            settle()
        } else if now >= finalEnd {
            fail("final cleanup deadline exceeded")
            closeOwned(&controlFD, "control")
            closeOwned(&stdoutFD, "stdout")
            settle()
        }
    }

    private func settle() {
        guard result == nil, let releaseID else { return }
        let timing = timingSnapshot
        if timing.heldObservedNS == nil { fail("held marker missing") }
        if timing.releaseObservedNS == nil { fail("release marker missing") }
        if let held = timing.heldObservedNS, let requested = timing.releaseRequestedNS,
           let released = timing.releaseObservedNS, !(held <= requested && requested <= released) {
            fail("protocol marker ordering invalid")
        }
        if releaseWritesCompleted != 1 { fail("release control write incomplete") }
        if !stdoutEOF { fail("stdout EOF unobserved") }
        if !childReaped { fail("child reap incomplete") }
        let cleanup = childReaped && controlFD < 0 && stdoutFD < 0 && !closeFailed
        let value = ReleaseResult(releaseID: releaseID, childPID: child, spawnObservedNS: spawnObservedNS, timing: timing,
                                  success: failures.isEmpty && cleanup && timing.exitedNormally && timing.exitStatus == 0,
                                  cleanupComplete: cleanup, childReaped: childReaped, rawWaitStatus: waitStatus,
                                  stdoutEOF: stdoutEOF, releaseWritesCompleted: releaseWritesCompleted,
                                  signals: signals, failures: failures)
        result = value
        let callers = waiters
        waiters.removeAll()
        if !signalAuthority { stopTimer() }
        for caller in callers { caller.resume(returning: value) }
    }

    private func stopTimer() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }
}
