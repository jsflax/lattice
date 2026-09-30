import Foundation
import LatticeInstallationChannel

/// Installer-only initialization of a new, controller-owned Engram namespace.
/// This does not enroll an existing store or install a managed-open context.
public enum LatticeInstallationInitializer {
    private final class Callback {
        let initialize: (URL) throws -> Void
        init(_ initialize: @escaping (URL) throws -> Void) { self.initialize = initialize }
    }

    /// Call before ordinary product startup, then exit with the returned status.
    /// The synchronous callback must create only the primary store at this exact
    /// URL. It must not start workers, sync, providers or child processes. The
    /// retained native controller separately observes the actual process exit.
    public static func receiveEngramSeed(_ initialize: @escaping (URL) throws -> Void) -> Int32 {
        let callback = Callback(initialize)
        return withExtendedLifetime(callback) {
            lattice_receive_engram_seed_v1({ path, context in
                guard let path, let context else { return 74 }
                let callback = Unmanaged<Callback>.fromOpaque(context).takeUnretainedValue()
                do {
                    try callback.initialize(URL(fileURLWithPath: String(cString: path)))
                    return 0
                } catch {
                    return 74
                }
            }, Unmanaged.passUnretained(callback).toOpaque())
        }
    }
}
