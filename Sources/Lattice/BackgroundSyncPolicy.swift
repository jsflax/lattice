import Foundation

extension Lattice.Configuration {
    /// The app's opt-in policy for requesting background sync opportunities.
    ///
    /// This is configuration data. Constructing or copying it does not register
    /// a task, open a store, or schedule work. The app declares the identifier
    /// in `BGTaskSchedulerPermittedIdentifiers` and enables Background Fetch.
    public enum BackgroundSync: Sendable, Equatable, Hashable {
        /// Request an app-refresh opportunity no earlier than this interval.
        /// iOS chooses whether and when to run it; the interval is not a timer.
        case appRefresh(identifier: String, minimumInterval: TimeInterval = 15 * 60)
    }

    /// Derived readers may share a managed native store but never become a
    /// second process-level task registration or lifecycle owner.
    internal func withoutBackgroundTaskOwnership(queryOnly: Bool = false) -> Self {
        var copy = self
        if backgroundSync != nil || backgroundSyncManaged {
            copy.syncStartup = .deferred
            copy.backgroundSyncManaged = true
            // The inherited owner uploads this file. A derived reader never
            // opens another transport or carries account credentials itself.
            copy.wssEndpoint = nil
            copy.authorizationToken = nil
            copy.ipcTargets = nil
        }
        copy.backgroundSync = nil
        return copy
    }

    internal func validateBackgroundSyncStore() throws {
        try backgroundSyncLineage?.validate()
        guard backgroundSync != nil || backgroundSyncManaged else { return }
        guard case .file = storage, ipcTargets?.isEmpty != false else {
            throw Lattice.Error.databaseError("Managed background lifecycle requires a file store without unmanaged IPC targets.")
        }
        if backgroundSync != nil {
            guard !isReadOnly, wssEndpoint != nil, authorizationToken?.isEmpty == false else {
                throw Lattice.Error.databaseError("Background sync requires a writable file store, a WSS endpoint and nonempty token.")
            }
        }
    }
}

extension Lattice {
    /// Register before app launch finishes when the store opens lazily.
    /// This declaration does not open storage or infer a model schema.
    /// Normal initialization also registers before opening its store.
    public static func registerBackgroundTasks(configuration: Configuration = defaultConfiguration) throws {
        guard let policy = configuration.backgroundSync else { return }
        try BackgroundTaskScheduler.shared.register(policy: policy)
    }
}

/// Portable validation used by the registration/open integration. Keep this
/// separate from value construction so configuration remains ordinary data.
extension Lattice.Configuration.BackgroundSync {
    internal var identifier: String {
        switch self { case let .appRefresh(identifier, _): return identifier }
    }
    internal func validate(permittedIdentifiers: Set<String>) throws {
        switch self {
        case let .appRefresh(identifier, minimumInterval):
            // Preserve the exact identifier. Trimming it here could register a
            // different task from the one declared by the app. Apple recommends
            // reverse-DNS names but does not require a custom DNS grammar here.
            guard !identifier.isEmpty,
                  !identifier.unicodeScalars.contains(where: {
                      CharacterSet.whitespacesAndNewlines.contains($0) ||
                      CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw BackgroundSyncPolicyValidationError.invalidIdentifier(identifier)
            }
            guard minimumInterval.isFinite, minimumInterval > 0 else {
                throw BackgroundSyncPolicyValidationError.invalidMinimumInterval
            }
            guard permittedIdentifiers.contains(identifier) else {
                throw BackgroundSyncPolicyValidationError.identifierNotPermitted(identifier)
            }
        }
    }
}

internal enum BackgroundSyncPolicyValidationError: Error, Equatable, Sendable, LocalizedError {
    case invalidIdentifier(String)
    case invalidMinimumInterval
    case identifierNotPermitted(String)

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier:
            return "A background sync task identifier must be nonempty and contain no whitespace or control characters."
        case .invalidMinimumInterval:
            return "The background sync minimum interval must be finite and greater than zero."
        case let .identifierNotPermitted(identifier):
            return "The background sync task identifier '\(identifier)' is missing from BGTaskSchedulerPermittedIdentifiers."
        }
    }
}
