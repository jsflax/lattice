import Foundation
import LatticeInstallationChannel
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Synchronous callback custody only. It cannot issue an ordinary open view,
// producer, historical enrollment, retirement receipt or source capability.
private final class EngramSeedInvocation {
    let creator: pid_t
    var initializer: ((URL) throws -> Void)?
    var entered = false
    var succeeded = false

    init(creator: pid_t) { self.creator = creator }

    func invoke(_ exactPath: UnsafePointer<CChar>?) -> Int32 {
        // Refuse before traversing the captured product initializer after fork.
        guard getpid() == creator else { return 74 }
        guard !entered else { return 74 }
        entered = true
        guard let exactPath, let initializer else { return 74 }
        // Native derives this path from its retained directory. Copy only a
        // bounded UTF-8 spelling; the spelling itself grants no managed open.
        var count = 0
        while count <= 4096 && exactPath[count] != 0 { count += 1 }
        guard count > 0, count <= 4096 else { return 74 }
        let bytes = UnsafeBufferPointer(start: UnsafeRawPointer(exactPath)
            .assumingMemoryBound(to: UInt8.self), count: count)
        guard let path = String(bytes: bytes, encoding: .utf8), path.hasPrefix("/") else { return 74 }
        let url = URL(fileURLWithPath: path)
        guard url.path == path, url.lastPathComponent == "memory.sqlite" else { return 74 }
        do {
            try initializer(url)
            guard getpid() == creator else { return 74 }
            succeeded = true
            return 0
        } catch {
            // No Swift error crosses the C ABI or becomes a native success.
            return 74
        }
    }
}

private func invokeEngramSeed(_ exactPath: UnsafePointer<CChar>?,
                             _ context: UnsafeMutableRawPointer?) -> Int32 {
    guard let context else { return 74 }
    return Unmanaged<EngramSeedInvocation>.fromOpaque(context)
        .takeUnretainedValue().invoke(exactPath)
}

/// New-namespace installation entry. Invoke before logging, watchdogs, native
/// opens or workers. The product initializer creates exactly its known schema
/// at the native-supplied URL and completes checked close before returning.
/// The caller must immediately exit with this status; normal main must not run.
public enum LatticeInstallationInitializer {
    public static func receiveEngramSeed(_ initializer: @escaping (URL) throws -> Void) -> Int32 {
        let creator = getpid()
        // Establish the guarded capsule before retaining foreign Swift payload.
        let capsule = Unmanaged.passRetained(EngramSeedInvocation(creator: creator))
        capsule.takeUnretainedValue().initializer = initializer
        defer {
            // An inherited-process retain is quarantined until OS exit. This
            // is not a claim that arbitrary application fork paths are safe.
            if getpid() == creator { capsule.release() }
        }
        let status = lattice_receive_engram_seed_v1(invokeEngramSeed, capsule.toOpaque())
        guard getpid() == creator else { return 74 }
        guard status != 0 || capsule.takeUnretainedValue().succeeded else { return 74 }
        // Native preserves its original 30-second exchange deadline and
        // independently rechecks physical/name/parent facts after the callback.
        return status
    }
}
