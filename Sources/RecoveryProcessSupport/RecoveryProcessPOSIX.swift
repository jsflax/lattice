import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// C fixture-only descriptor custody. Never opens a database or changes trust.
public enum RecoveryProcessPOSIX {
    public static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    public static func check(_ deadline: UInt64) throws { guard now() < deadline else { throw RecoveryProcessFailure.deadline } }
    public static func configureSocket(_ fd: Int32) throws {
        let descriptor = fcntl(fd, F_GETFD), flags = fcntl(fd, F_GETFL)
        guard descriptor >= 0, flags >= 0, fcntl(fd, F_SETFD, descriptor | FD_CLOEXEC) == 0,
              fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw RecoveryProcessFailure.io }
        #if canImport(Darwin)
        var one: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0 else { throw RecoveryProcessFailure.io }
        #endif
    }
    public static func sendBytes(_ fd: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        return send(fd, bytes, count, MSG_DONTWAIT)
        #else
        return send(fd, bytes, count, Int32(MSG_DONTWAIT | MSG_NOSIGNAL))
        #endif
    }
    public static func receiveBytes(_ fd: Int32, _ bytes: UnsafeMutableRawPointer, _ count: Int) -> Int {
        recv(fd, bytes, count, Int32(MSG_DONTWAIT))
    }
    // Pure environment spelling check only; the descriptor walk below remains
    // the actual no-follow custody check. Hosted wrappers use explicit HOME.
    static func hostedDirectoryPath(_ url: URL, home: String?) throws -> String {
        let path = url.path
        guard let home, url.isFileURL, url.standardizedFileURL.path == path,
              home.hasPrefix("/"), path.hasPrefix("/"), !home.contains("\0"), !path.contains("\0"),
              home.utf8.count <= 4096, path.utf8.count <= 4096 else { throw RecoveryProcessFailure.configuration }
        func canonical(_ value: String) -> Bool {
            let parts = value.split(separator: "/", omittingEmptySubsequences: false)
            return parts.count > 1 && parts.first == "" &&
                parts.dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
        }
        guard canonical(home), canonical(path), path.hasPrefix(home + "/localdev/")
        else { throw RecoveryProcessFailure.configuration }
        return path
    }
    public static func directory(_ url: URL, privateCase: Bool) throws -> Int32 {
        let path = try hostedDirectoryPath(url, home: ProcessInfo.processInfo.environment["HOME"])
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw RecoveryProcessFailure.io }
        do {
            for part in path.split(separator: "/") {
                guard part != ".", part != ".." else { throw RecoveryProcessFailure.configuration }
                let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw RecoveryProcessFailure.io }
                guard close(fd) == 0 else { _ = close(next); fd = -1; throw RecoveryProcessFailure.io }; fd = next
            }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == geteuid(),
                  !privateCase || info.st_mode & 0o777 == 0o700 else { throw RecoveryProcessFailure.configuration }
            return fd
        } catch { if fd >= 0 { _ = close(fd) }; throw error }
    }
    public static func readConfiguration(directory fd: Int32) throws -> Data {
        var file = openat(fd, "configuration.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw RecoveryProcessFailure.io }
        do {
            var before = stat()
            guard fstat(file, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  before.st_uid == geteuid(), before.st_nlink == 1, before.st_mode & 0o777 == 0o600,
                  before.st_size > 0, before.st_size <= RecoveryProcessCodec.maximumMessage else { throw RecoveryProcessFailure.configuration }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(file, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw RecoveryProcessFailure.io }
                if count == 0 { break }
                guard count <= RecoveryProcessCodec.maximumMessage - data.count else { throw RecoveryProcessFailure.bounds }
                data.append(contentsOf: buffer.prefix(count))
            }
            var after = stat()
            guard fstat(file, &after) == 0, sameFile(before, after), data.count == Int(before.st_size) else { throw RecoveryProcessFailure.configuration }
            let owned = file; file = -1
            guard close(owned) == 0 else { throw RecoveryProcessFailure.io }; return data
        } catch { if file >= 0 { _ = close(file) }; throw error }
    }
    public static func writeConfiguration(_ data: Data, directory fd: Int32) throws {
        guard !data.isEmpty, data.count <= RecoveryProcessCodec.maximumMessage else { throw RecoveryProcessFailure.bounds }
        var file = openat(fd, "configuration.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard file >= 0 else { throw RecoveryProcessFailure.io }
        do {
            var offset = 0
            try data.withUnsafeBytes { raw in
                while offset < data.count {
                    let count = write(file, raw.baseAddress!.advanced(by: offset), data.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw RecoveryProcessFailure.io }; offset += count
                }
            }
            guard fsync(file) == 0 else { throw RecoveryProcessFailure.io }
            let owned = file; file = -1
            guard close(owned) == 0 else { throw RecoveryProcessFailure.io }
            guard fsync(fd) == 0 else { throw RecoveryProcessFailure.io }
        } catch { if file >= 0 { _ = close(file) }; throw error }
    }
    public static func sameFile(_ a: stat, _ b: stat) -> Bool {
        guard a.st_dev == b.st_dev, a.st_ino == b.st_ino, a.st_size == b.st_size,
              a.st_mode == b.st_mode, a.st_uid == b.st_uid, a.st_nlink == b.st_nlink else { return false }
        #if canImport(Darwin)
        return a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
            a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
        #else
        return a.st_mtim.tv_sec == b.st_mtim.tv_sec && a.st_mtim.tv_nsec == b.st_mtim.tv_nsec &&
            a.st_ctim.tv_sec == b.st_ctim.tv_sec && a.st_ctim.tv_nsec == b.st_ctim.tv_nsec
        #endif
    }
}

/// Dedicated child has one structured IO caller. Bounded polling happens on
/// this private queue, never the Lattice actor. Parent kill also retires it.
public final class RecoveryProcessChildChannel: @unchecked Sendable {
    private let fd: Int32, deadline: UInt64
    private let queue = DispatchQueue(label: "lattice.recovery.child-control")
    private var transcript = 0, messages = 0
    public init(fd: Int32, deadline: UInt64) throws {
        guard fd == 3 else { throw RecoveryProcessFailure.configuration }
        var kind: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_TYPE, &kind, &length) == 0,
              length == MemoryLayout<Int32>.size else { throw RecoveryProcessFailure.io }
        #if canImport(Darwin)
        guard kind == SOCK_STREAM else { throw RecoveryProcessFailure.io }
        #else
        guard kind == Int32(SOCK_STREAM.rawValue) else { throw RecoveryProcessFailure.io }
        #endif
        try RecoveryProcessPOSIX.configureSocket(fd); self.fd = fd; self.deadline = deadline
    }
    private func wait(_ events: Int16) throws {
        try RecoveryProcessPOSIX.check(deadline)
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        let result = poll(&descriptor, 1, 10)
        guard result >= 0 || errno == EINTR else { throw RecoveryProcessFailure.io }
        guard descriptor.revents & Int16(POLLNVAL | POLLERR) == 0 else { throw RecoveryProcessFailure.io }
    }
    private func charge(_ count: Int) throws {
        guard count <= 1_048_576 - transcript else { throw RecoveryProcessFailure.bounds }; transcript += count
    }
    public func readMessage() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in queue.async { [self] in
            do {
                guard messages < 16 else { throw RecoveryProcessFailure.bounds }; messages += 1
                var frame = RecoveryProcessFramer(), bytes = [UInt8](repeating: 0, count: 4096)
                while true {
                    try RecoveryProcessPOSIX.check(deadline)
                    let count = RecoveryProcessPOSIX.receiveBytes(fd, &bytes, bytes.count)
                    if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { try wait(Int16(POLLIN)); continue }
                    guard count > 0 else { throw RecoveryProcessFailure.io }
                    try charge(count); try frame.append(Data(bytes.prefix(count)))
                    if let payload = frame.take() { continuation.resume(returning: payload); return }
                }
            } catch { continuation.resume(throwing: error) }
        } }
    }
    public func sendMessage(_ payload: Data) async throws {
        let frame = try RecoveryProcessCodec.frame(payload)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in queue.async { [self] in
            do {
                try charge(frame.count); var offset = 0
                try frame.withUnsafeBytes { raw in
                    while offset < frame.count {
                        try RecoveryProcessPOSIX.check(deadline)
                        let count = RecoveryProcessPOSIX.sendBytes(fd, raw.baseAddress!.advanced(by: offset), frame.count - offset)
                        if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { try wait(Int16(POLLOUT)); continue }
                        guard count > 0 else { throw RecoveryProcessFailure.io }; offset += count
                    }
                }
                continuation.resume()
            } catch { continuation.resume(throwing: error) }
        } }
    }
    public func finish() async -> Bool {
        await withCheckedContinuation { continuation in queue.async { [self] in continuation.resume(returning: close(fd) == 0) } }
    }
}
