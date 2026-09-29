import Foundation
import RecoveryProcessSupport
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private final class RecoveryProcessBundleAnchor: NSObject {}

/// Exactly two dedicated children per C case. `queue` is the only waiter,
/// signaler and control-FD owner; no Process, waitpid(-1), PID lookup or group
/// manipulation. A fixture must await cleanup even when its scenario throws.
final class RecoveryProcessOwner: @unchecked Sendable {
    struct Retirement: Sendable {
        let killedByOwnedSIGKILL: Bool
        let exitedZero: Bool
        let reaped: Bool
        let instanceID: String
        let spawnOrdinal: Int
        fileprivate let token: UUID
        fileprivate init(killedByOwnedSIGKILL: Bool, exitedZero: Bool, instanceID: String, spawnOrdinal: Int, token: UUID) {
            self.killedByOwnedSIGKILL = killedByOwnedSIGKILL; self.exitedZero = exitedZero; reaped = true
            self.instanceID = instanceID; self.spawnOrdinal = spawnOrdinal; self.token = token
        }
    }
    struct ReapedContext: Sendable {
        let file, root: URL
        let configuration: RecoveryProcessConfiguration
        let configurationSHA256, instanceID: String
        let spawnOrdinal: Int
        fileprivate init(root: URL, configuration: RecoveryProcessConfiguration, configurationSHA256: String,
                         instanceID: String, spawnOrdinal: Int) {
            self.root = root; self.configuration = configuration; self.configurationSHA256 = configurationSHA256
            self.instanceID = instanceID; self.spawnOrdinal = spawnOrdinal
            file = root.appendingPathComponent(configuration.storeDirectory).appendingPathComponent("store.sqlite")
        }
    }
    struct Cleanup: Sendable {
        let allSpawnedReaped: Bool
        let descriptorsClosed: Bool
        let successfulCase: Bool
        let spawnCount: Int
    }
    private struct Disposition: Equatable { let handler: UInt; let flags: Int32 }
    private enum Pending {
        case hello(CheckedContinuation<RecoveryProcessHello, Error>)
        case reply(RecoveryProcessCommand, CheckedContinuation<RecoveryProcessReply, Error>)
        case reap(Bool, CheckedContinuation<Retirement, Error>)
    }
    let configuration: RecoveryProcessConfiguration
    let configurationSHA256: String
    let executableSHA256: String
    private let directory: URL, executable: URL, savedConfiguration: Data
    private var directoryFD: Int32
    private let executableIdentity: stat, rootIdentity: stat, savedDisposition: Disposition
    private let queue = DispatchQueue(label: "lattice.recovery.child-owner")
    private var timer: DispatchSourceTimer?, pending: Pending?
    private var cleanupWaiter: CheckedContinuation<Cleanup, Never>?
    private var cleanupResult: Cleanup?
    private var pid: pid_t = 0, control: Int32 = -1, ownedUnreaped = false, custodyLost = false
    private var spawnCount = 0, commandCount = 0, transcript = 0, reapedCount = 0
    private var firstPID: pid_t = 0, firstInstance: String?, currentHello: RecoveryProcessHello?
    private var state = RecoveryProcessCommandState(), lastOperation: RecoveryProcessOperation?
    private var output = Data(), outputOffset = 0, input = RecoveryProcessFramer()
    private var status: Int32?, requestedKill = false, killAttempted = false, killSucceeded = false, closeAcknowledged = false
    private var retirementToken: UUID?
    private var failed = false, closing = false, reapDeadline: UInt64?
    private var descriptorCloseFailed = false

    static func executableURL() throws -> URL {
        let bundle = Bundle(for: RecoveryProcessBundleAnchor.self).bundleURL
        let directory = bundle.pathExtension == "xctest" ? bundle.deletingLastPathComponent() : bundle
        let result = directory.appendingPathComponent("RecoveryProcessChild").standardizedFileURL
        guard result.lastPathComponent == "RecoveryProcessChild" else { throw RecoveryProcessFailure.configuration }
        return result
    }
    init(configuration: RecoveryProcessConfiguration, caseDirectory: URL, executable: URL) throws {
        try configuration.validate(); try configuration.validateDeadline(now: RecoveryProcessPOSIX.now())
        let environment = ProcessInfo.processInfo.environment
        guard environment["LATTICE_RECEIVER_KILL_RECOVERY_GATE"] == "1",
              let root = environment["LATTICE_CONNECTED_RECOVERY_RUN_DIR"], caseDirectory.path.hasPrefix(root + "/private/"),
              configuration.storeDirectory == "receiver-a.lattice-continuous", executable == (try Self.executableURL())
        else { throw RecoveryProcessFailure.configuration }
        self.configuration = configuration; directory = caseDirectory; self.executable = executable
        savedConfiguration = try RecoveryProcessCodec.encode(configuration)
        configurationSHA256 = try RecoveryProcessSHA256.hash(savedConfiguration)
        savedDisposition = try Self.disposition()
        let (identity, hash) = try Self.inspectExecutable(executable, deadline: configuration.deadlineNanoseconds)
        executableIdentity = identity; executableSHA256 = hash
        let fd = try RecoveryProcessPOSIX.directory(caseDirectory, privateCase: true)
        var rootInfo = stat()
        do {
            guard fstat(fd, &rootInfo) == 0 else { throw RecoveryProcessFailure.io }
            try RecoveryProcessPOSIX.writeConfiguration(savedConfiguration, directory: fd)
            guard try RecoveryProcessPOSIX.readConfiguration(directory: fd) == savedConfiguration else { throw RecoveryProcessFailure.configuration }
        } catch { _ = close(fd); throw error }
        directoryFD = fd; rootIdentity = rootInfo
    }
    deinit {
        // No running child can reach deinit: its timer retains the sole owner.
        let fd = directoryFD; if fd >= 0 { queue.async { _ = close(fd) } }
    }
    private static func inspectExecutable(_ url: URL, deadline: UInt64) throws -> (stat, String) {
        let parent = try RecoveryProcessPOSIX.directory(url.deletingLastPathComponent(), privateCase: false)
        var fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        let parentClosed = close(parent) == 0
        guard fd >= 0, parentClosed else { if fd >= 0 { _ = close(fd) }; throw RecoveryProcessFailure.io }
        do {
            var initial = stat()
            guard fstat(fd, &initial) == 0, initial.st_uid == geteuid(), initial.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  initial.st_mode & 0o111 != 0, initial.st_mode & 0o022 == 0, initial.st_nlink == 1,
                  initial.st_size > 0, initial.st_size <= 536_870_912 else { throw RecoveryProcessFailure.configuration }
            var hash = RecoveryProcessSHA256(), bytes = [UInt8](repeating: 0, count: 16_384), count = 0
            while true {
                try RecoveryProcessPOSIX.check(deadline)
                let readCount = read(fd, &bytes, bytes.count)
                if readCount < 0 && errno == EINTR { continue }
                guard readCount >= 0 else { throw RecoveryProcessFailure.io }
                if readCount == 0 { break }; count += readCount
                try hash.update(Data(bytes.prefix(readCount)))
            }
            var final = stat()
            guard fstat(fd, &final) == 0, RecoveryProcessPOSIX.sameFile(initial, final), count == Int(initial.st_size) else { throw RecoveryProcessFailure.configuration }
            let owned = fd; fd = -1; guard close(owned) == 0 else { throw RecoveryProcessFailure.io }
            return (initial, hash.finish())
        } catch { if fd >= 0 { _ = close(fd) }; throw error }
    }
    private static func disposition() throws -> Disposition {
        var value = sigaction()
        guard sigaction(SIGCHLD, nil, &value) == 0, value.sa_flags & (SA_SIGINFO | SA_NOCLDWAIT) == 0 else { throw RecoveryProcessFailure.state }
        #if canImport(Darwin)
        let handler = unsafeBitCast(value.__sigaction_u.__sa_handler, to: UInt.self)
        #else
        let handler = unsafeBitCast(value.__sigaction_handler.sa_handler, to: UInt.self)
        #endif
        guard handler == unsafeBitCast(SIG_DFL, to: UInt.self) else { throw RecoveryProcessFailure.state }
        return .init(handler: handler, flags: value.sa_flags)
    }
    private func checkCustody() -> Bool {
        guard (try? Self.disposition()) == savedDisposition else {
            ownedUnreaped = false; custodyLost = true; fail(.state); return false
        }; return true
    }
    func spawn() async throws -> RecoveryProcessHello {
        try await withCheckedThrowingContinuation { continuation in queue.async { [self] in
            var installedContinuation = false
            do {
                guard !failed, !closing, pending == nil, !ownedUnreaped, spawnCount < 2,
                      spawnCount == 0 || (reapedCount == 1 && requestedKill && killSucceeded && status.map({ $0 & 0x7f == SIGKILL }) == true)
                else { throw RecoveryProcessFailure.state }
                try RecoveryProcessPOSIX.check(configuration.deadlineNanoseconds)
                guard try Self.disposition() == savedDisposition else { throw RecoveryProcessFailure.configuration }
                try validateRootAndConfiguration()
                let (identity, hash) = try Self.inspectExecutable(executable, deadline: configuration.deadlineNanoseconds)
                guard RecoveryProcessPOSIX.sameFile(identity, executableIdentity), hash == executableSHA256 else { throw RecoveryProcessFailure.configuration }
                state = .init(); lastOperation = nil; currentHello = nil; status = nil
                requestedKill = false; killAttempted = false; killSucceeded = false; closeAcknowledged = false; reapDeadline = nil; retirementToken = nil
                input = .init(); output = Data(); outputOffset = 0
                pending = .hello(continuation); installedContinuation = true
                try spawnOwned()
            } catch {
                fail((error as? RecoveryProcessFailure) ?? .io)
                if !installedContinuation { continuation.resume(throwing: error) }
            }
        } }
    }
    func command(_ operation: RecoveryProcessOperation, expected: RecoveryProcessImage? = nil) async throws -> RecoveryProcessReply {
        try await withCheckedThrowingContinuation { continuation in queue.async { [self] in
            do {
                guard !failed, !closing, pending == nil, ownedUnreaped, currentHello != nil, commandCount < 16 else { throw RecoveryProcessFailure.state }
                try RecoveryProcessPOSIX.check(configuration.deadlineNanoseconds)
                let command = RecoveryProcessCommand(nonce: configuration.nonce, sequence: state.lastSequence + 1,
                    operation: operation, role: operation == .start ? (spawnCount == 1 ? .initial : .reopened) : nil, expected: expected)
                var next = state; try next.accept(command, nonce: configuration.nonce)
                let bytes = try RecoveryProcessCodec.frame(RecoveryProcessCodec.encode(command)); try charge(bytes.count)
                state = next; commandCount += 1; output = bytes; outputOffset = 0; pending = .reply(command, continuation)
                tick()
            } catch { fail((error as? RecoveryProcessFailure) ?? .io); continuation.resume(throwing: error) }
        } }
    }
    /// The caller must first prove the real source/Q/page cut. This method
    /// contributes only owned SIGKILL + exact waitpid proof, never a cutpoint.
    func killAtObservedCut() async throws -> Retirement {
        try await withCheckedThrowingContinuation { continuation in queue.async { [self] in
            guard !failed, pending == nil, spawnCount == 1, ownedUnreaped, lastOperation == .reconnect,
                  output.isEmpty, input.count == 0 else { continuation.resume(throwing: RecoveryProcessFailure.state); return }
            pending = .reap(true, continuation); requestedKill = true; setReapDeadline(); signalKill(); tick()
        } }
    }
    func closeAndReap() async throws -> Retirement {
        _ = try await command(.close)
        return try await withCheckedThrowingContinuation { continuation in queue.async { [self] in
            guard !failed, pending == nil, spawnCount == 2, closeAcknowledged else { continuation.resume(throwing: RecoveryProcessFailure.state); return }
            pending = .reap(false, continuation); setReapDeadline(); tick()
        } }
    }
    /// A stale/copied retirement DTO cannot authorize a read after the next
    /// spawn. The entire synchronous, bounded passive read shares spawn's queue.
    /// Returned values are observations; no source authorization is issued.
    func withReapedChild<T: Sendable>(_ retirement: Retirement,
        _ body: @escaping @Sendable (ReapedContext) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in queue.async { [self] in
            do {
                guard !failed, !closing, !ownedUnreaped, !custodyLost, pending == nil, retirement.reaped,
                      retirement.token == retirementToken, retirement.spawnOrdinal == spawnCount,
                      currentHello?.instanceID == retirement.instanceID, reapedCount == spawnCount,
                      retirement.spawnOrdinal == 1 ? retirement.killedByOwnedSIGKILL : retirement.exitedZero
                else { throw RecoveryProcessFailure.state }
                try RecoveryProcessPOSIX.check(configuration.deadlineNanoseconds); try validateRootAndConfiguration()
                let context = ReapedContext(root: directory, configuration: configuration, configurationSHA256: configurationSHA256,
                    instanceID: retirement.instanceID, spawnOrdinal: spawnCount)
                let value = try body(context)
                try RecoveryProcessPOSIX.check(configuration.deadlineNanoseconds); try validateRootAndConfiguration()
                continuation.resume(returning: value)
            } catch { failed = true; continuation.resume(throwing: error) }
        } }
    }
    private func validateRootAndConfiguration() throws {
        let fd = try RecoveryProcessPOSIX.directory(directory, privateCase: true)
        var pathInfo = stat(), retainedInfo = stat()
        let valid = fstat(fd, &pathInfo) == 0 && fstat(directoryFD, &retainedInfo) == 0 &&
            pathInfo.st_dev == rootIdentity.st_dev && pathInfo.st_ino == rootIdentity.st_ino &&
            retainedInfo.st_dev == rootIdentity.st_dev && retainedInfo.st_ino == rootIdentity.st_ino &&
            pathInfo.st_uid == rootIdentity.st_uid && pathInfo.st_mode == rootIdentity.st_mode
        let closed = close(fd) == 0
        guard valid, closed, try RecoveryProcessPOSIX.readConfiguration(directory: directoryFD) == savedConfiguration else { throw RecoveryProcessFailure.configuration }
    }
    /// Uncancellable bounded join. A failed join retains only an observe-only
    /// waiter; the outer owned test-process group is the final containment.
    func cleanup() async -> Cleanup {
        await withCheckedContinuation { continuation in queue.async { [self] in
            if let cleanupResult { continuation.resume(returning: cleanupResult); return }
            guard cleanupWaiter == nil else { failed = true; continuation.resume(returning: .init(allSpawnedReaped: false, descriptorsClosed: false, successfulCase: false, spawnCount: spawnCount)); return }
            cleanupWaiter = continuation; closing = true
            if pending != nil { fail(.state) }
            if ownedUnreaped { failed = true; setReapDeadline(); signalKill() }
            tick()
        } }
    }
    private func charge(_ count: Int) throws {
        guard count <= 1_048_576 - transcript else { throw RecoveryProcessFailure.bounds }; transcript += count
    }
    private func setReapDeadline() {
        if reapDeadline == nil { reapDeadline = min(configuration.deadlineNanoseconds, RecoveryProcessPOSIX.now() + 10_000_000_000) }
    }
    private func closeControl() {
        if control >= 0 { let fd = control; control = -1; if close(fd) != 0 { failed = true; descriptorCloseFailed = true } }
        output = Data(); input = .init()
    }
    private func fail(_ error: RecoveryProcessFailure) {
        failed = true
        if error == .io { descriptorCloseFailed = true }
        if let pending {
            self.pending = nil
            switch pending {
            case .hello(let c): c.resume(throwing: error)
            case .reply(_, let c): c.resume(throwing: error)
            case .reap(_, let c): c.resume(throwing: error)
            }
        }
        setReapDeadline()
    }
    private func signalKill() {
        observeExit()
        guard ownedUnreaped, !killAttempted, checkCustody() else { return }
        killAttempted = true
        if kill(pid, SIGKILL) == 0 { killSucceeded = true } else { fail(.io) }
    }
    private func observeExit() {
        guard ownedUnreaped, checkCustody() else { return }
        var observed: Int32 = 0
        let result = waitpid(pid, &observed, WNOHANG)
        if result == 0 || (result < 0 && errno == EINTR) { return }
        guard result == pid else { ownedUnreaped = false; custodyLost = true; fail(.io); return }
        guard observed & 0x7f != 0x7f else { fail(.state); return }
        ownedUnreaped = false // Revoke signaling before any continuation resumes.
        status = observed; reapedCount += 1
        if !requestedKill && lastOperation != .close { fail(.state) }
    }
    private func tick() {
        if cleanupResult != nil {
            observeExit(); if !ownedUnreaped { stopTimer() }; return
        }
        if failed && pending != nil { fail(.io) }
        if !failed { pump() }
        observeExit()
        if RecoveryProcessPOSIX.now() >= configuration.deadlineNanoseconds && (ownedUnreaped || pending != nil) { fail(.deadline) }
        if failed && ownedUnreaped { signalKill() }
        if let status, case .reap(let expectsKill, let continuation) = pending {
            let killed = requestedKill && killSucceeded && status & 0x7f == SIGKILL
            let zero = status & 0x7f == 0 && (status >> 8) & 0xff == 0
            pending = nil; closeControl(); stopTimer()
            if !failed, let hello = currentHello, expectsKill ? killed : (zero && closeAcknowledged) {
                let token = UUID(); retirementToken = token
                continuation.resume(returning: .init(killedByOwnedSIGKILL: killed, exitedZero: zero,
                    instanceID: hello.instanceID, spawnOrdinal: spawnCount, token: token))
            } else { failed = true; continuation.resume(throwing: RecoveryProcessFailure.state) }
        }
        if let end = reapDeadline, RecoveryProcessPOSIX.now() >= end, ownedUnreaped { fail(.deadline); closeControl() }
        if closing && (!ownedUnreaped || (reapDeadline.map { RecoveryProcessPOSIX.now() >= $0 } ?? false)) {
            closeControl()
            var directoryClosed = true
            if directoryFD >= 0 { let fd = directoryFD; directoryFD = -1; directoryClosed = close(fd) == 0 }
            if !directoryClosed { failed = true }
            let result = Cleanup(allSpawnedReaped: !custodyLost && reapedCount == spawnCount,
                descriptorsClosed: directoryClosed && control < 0 && !descriptorCloseFailed,
                successfulCase: !failed && spawnCount == 2 && reapedCount == 2 && closeAcknowledged, spawnCount: spawnCount)
            cleanupResult = result; let waiter = cleanupWaiter; cleanupWaiter = nil; waiter?.resume(returning: result)
            if !ownedUnreaped { stopTimer() }
        } else if failed && !ownedUnreaped { closeControl(); stopTimer() }
    }
    private func pump() {
        guard control >= 0 else { return }
        if outputOffset < output.count {
            let sent = output.withUnsafeBytes { RecoveryProcessPOSIX.sendBytes(control, $0.baseAddress!.advanced(by: outputOffset), output.count - outputOffset) }
            if sent > 0 { outputOffset += sent }
            else if sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { return }
            else { fail(.io); return }
            if outputOffset == output.count { output = Data(); outputOffset = 0 }
        }
        var bytes = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<17 {
            let count = RecoveryProcessPOSIX.receiveBytes(control, &bytes, bytes.count)
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            if count < 0 && errno == EINTR { continue }
            if count == 0 { if !requestedKill && !closeAcknowledged { fail(.io) }; return }
            guard count > 0 else { fail(.io); return }
            do {
                try charge(count); try input.append(Data(bytes.prefix(count)))
                if let bytes = input.take() {
                    switch pending {
                    case .hello(let continuation):
                        let hello = try RecoveryProcessCodec.decode(RecoveryProcessHello.self, from: bytes)
                        try hello.validate(nonce: configuration.nonce, hash: configurationSHA256, pid: pid)
                        guard spawnCount == 1 || (hello.instanceID != firstInstance && pid != firstPID) else { throw RecoveryProcessFailure.correlation }
                        if spawnCount == 1 { firstInstance = hello.instanceID; firstPID = pid }
                        currentHello = hello; pending = nil; continuation.resume(returning: hello)
                    case .reply(let command, let continuation):
                        guard output.isEmpty else { throw RecoveryProcessFailure.correlation }
                        let reply = try RecoveryProcessCodec.decode(RecoveryProcessReply.self, from: bytes); try reply.validate(for: command)
                        if let error = reply.failure { throw error }
                        lastOperation = command.operation; closeAcknowledged = command.operation == .close
                        pending = nil; continuation.resume(returning: reply)
                    default: throw RecoveryProcessFailure.correlation
                    }
                    return
                }
            } catch { fail((error as? RecoveryProcessFailure) ?? .syntax); return }
        }
    }
    private func stopTimer() { timer?.setEventHandler {}; timer?.cancel(); timer = nil }

    private static func strings<T>(_ values: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T) throws -> T {
        guard values.count <= 256, values.reduce(0, { $0 + $1.utf8.count + 1 }) <= 131_072,
              values.allSatisfy({ !$0.utf8.contains(0) }) else { throw RecoveryProcessFailure.bounds }
        var strings = values.map { strdup($0) }; defer { for value in strings { free(value) } }
        guard strings.allSatisfy({ $0 != nil }) else { throw RecoveryProcessFailure.io }; strings.append(nil)
        return try strings.withUnsafeMutableBufferPointer { try body($0.baseAddress!) }
    }
    private func spawnOwned() throws {
        var temporary = Set<Int32>()
        defer { for fd in temporary { if close(fd) != 0 { failed = true; descriptorCloseFailed = true } } }
        func reserve(_ original: Int32) throws -> Int32 {
            guard original >= 0 else { throw RecoveryProcessFailure.io }; temporary.insert(original)
            if original >= 4 { return original }
            let copy = fcntl(original, F_DUPFD_CLOEXEC, 4)
            guard copy >= 4 else { throw RecoveryProcessFailure.io }; temporary.insert(copy); temporary.remove(original)
            guard close(original) == 0 else { descriptorCloseFailed = true; throw RecoveryProcessFailure.io }; return copy
        }
        var pair: [Int32] = [-1, -1]
        #if canImport(Darwin)
        let socketKind = SOCK_STREAM
        #else
        let socketKind = Int32(SOCK_STREAM.rawValue)
        #endif
        guard socketpair(AF_UNIX, socketKind, 0, &pair) == 0 else { throw RecoveryProcessFailure.io }
        temporary.formUnion(pair)
        let parent = try reserve(pair[0]), child = try reserve(pair[1])
        try RecoveryProcessPOSIX.configureSocket(parent); try RecoveryProcessPOSIX.configureSocket(child)
        let input = try reserve(open("/dev/null", O_RDONLY | O_CLOEXEC))
        let ordinal = spawnCount + 1
        let output = try reserve(openat(directoryFD, "child-\(ordinal)-stdout.log", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)))
        let error = try reserve(openat(directoryFD, "child-\(ordinal)-stderr.log", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)))
        // Pre-create the private native destination, never inherit the parent's.
        let native = try reserve(openat(directoryFD, "child-\(ordinal)-native.log", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)))
        _ = native
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        #else
        var actions = posix_spawn_file_actions_t(), attributes = posix_spawnattr_t()
        #endif
        func checked(_ code: Int32) throws { guard code == 0 else { throw RecoveryProcessFailure.io } }
        try checked(posix_spawn_file_actions_init(&actions))
        var actionsLive = true, attributesLive = false
        defer {
            if actionsLive && posix_spawn_file_actions_destroy(&actions) != 0 { failed = true }
            if attributesLive && posix_spawnattr_destroy(&attributes) != 0 { failed = true }
        }
        try checked(posix_spawnattr_init(&attributes)); attributesLive = true
        for (from, to) in [(input, Int32(0)), (output, Int32(1)), (error, Int32(2)), (child, Int32(3))] {
            try checked(posix_spawn_file_actions_adddup2(&actions, from, to))
        }
        var mask = sigset_t(), defaults = sigset_t()
        try checked(sigemptyset(&mask)); try checked(sigemptyset(&defaults))
        for number in [SIGPIPE, SIGTERM, SIGINT, SIGCHLD] { try checked(sigaddset(&defaults, number)) }
        try checked(posix_spawnattr_setsigmask(&attributes, &mask)); try checked(posix_spawnattr_setsigdefault(&attributes, &defaults))
        var flags = Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        #if canImport(Darwin)
        flags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #else
        typealias CloseFrom = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
        guard let symbol = dlsym(nil, "posix_spawn_file_actions_addclosefrom_np") else { throw RecoveryProcessFailure.io }
        let closeFrom = unsafeBitCast(symbol, to: CloseFrom.self)
        try checked(withUnsafeMutablePointer(to: &actions) { closeFrom(UnsafeMutableRawPointer($0), 4) })
        #endif
        try checked(posix_spawnattr_setflags(&attributes, flags)) // No SETPGROUP: retain wrapper containment.
        var environment = ProcessInfo.processInfo.environment
        environment["LATTICE_TEST_LOG_PATH"] = directory.appendingPathComponent("child-\(ordinal)-native.log").path
        let env = environment.map { "\($0.key)=\($0.value)" }.sorted()
        var spawned: pid_t = 0
        try checked(Self.strings([executable.path, directory.path]) { argv in
            try Self.strings(env) { envp in posix_spawn(&spawned, executable.path, &actions, &attributes, argv, envp) }
        })
        // Establish ownership immediately; no throwable work may bypass it.
        pid = spawned; ownedUnreaped = true; control = parent; temporary.remove(parent); spawnCount += 1
        let source = DispatchSource.makeTimerSource(queue: queue); timer = source
        source.setEventHandler { [self] in tick() }; source.schedule(deadline: .now(), repeating: .milliseconds(10)); source.resume()
        actionsLive = false; if posix_spawn_file_actions_destroy(&actions) != 0 { fail(.io) }
        attributesLive = false; if posix_spawnattr_destroy(&attributes) != 0 { fail(.io) }
        if (try? Self.disposition()) != savedDisposition { custodyLost = true; ownedUnreaped = false; fail(.state) }
    }
}
