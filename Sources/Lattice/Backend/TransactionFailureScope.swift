import Foundation
import CxxStdlib

/// Keep the first reported backend failure until a synchronous transaction
/// finishes. The bridge's last-error slot is cleared by the next successful
/// call, so inspecting it only at commit would miss earlier failed setters.
internal final class TransactionFailureScope {
    /// Captured immediately after open and retained with that handle. Resolving
    /// the pathname again at transaction entry could identify a replacement
    /// file instead of the database that the live connection actually opened.
    enum StoreIdentity {
        case file(device: UInt64, inode: UInt64)
        case memory(String)
        case unavailable

        static func capture(storage: Lattice.Configuration.Storage, backend: any LatticeBackend) -> Self {
            switch storage {
            case .memory(let name): return .memory(name)
            case .file:
                // The path's inode is meaningful only while Core's original
                // open connection still occupies that canonical pathname.
                // Missing identity preserves ordinary single-store operation
                // but refuses nesting, rather than guessing an alias is safe.
                guard let checker = backend as? CxxBackend else { return .unavailable }
                do {
                    // Identify the open handle, without re-resolving a configured
                    // alias. Keep SQLite's exact bytes for both currentness probes.
                    let path = try checker.mainFilePath()
                    let decodedPath = String(path)
                    // Foundation's attribute lookup needs a String. Fail closed
                    // if decoding would make it inspect a different filename.
                    guard std.string(decodedPath) == path else { return .unavailable }
                    try checker.requireMainFileUnmoved(expectedPath: path)
                    let attributes = try FileManager.default.attributesOfItem(atPath: decodedPath)
                    guard attributes[.type] as? FileAttributeType == .typeRegular,
                          let device = attributes[.systemNumber] as? NSNumber,
                          let inode = attributes[.systemFileNumber] as? NSNumber else { return .unavailable }
                    try checker.requireMainFileUnmoved(expectedPath: path)
                    return .file(device: device.uint64Value, inode: inode.uint64Value)
                } catch { return .unavailable }
            }
        }

        var isKnown: Bool {
            if case .unavailable = self { return false }
            return true
        }

        func mayAlias(_ other: Self) -> Bool {
            switch (self, other) {
            case (.unavailable, _), (_, .unavailable): return true
            case let (.file(a, b), .file(c, d)): return a == c && b == d
            case let (.memory(a), .memory(b)): return a == b
            default: return false
            }
        }
    }

    /// Attachment metadata outlives Swift facades when a managed Core object
    /// still owns the native handle. It never retains a native reference.
    final class Attachments {
        private let lock = NSLock()
        private var paths: Set<String> = []
        private var unknown = false

        var mayHaveAttachments: Bool {
            lock.lock(); defer { lock.unlock() }
            return unknown || !paths.isEmpty
        }
        func retainUnknown() {
            lock.lock(); defer { lock.unlock() }
            unknown = true
        }
        func attached(_ path: String) {
            lock.lock(); defer { lock.unlock() }
            paths.insert(path)
        }
        func detached(_ path: String) {
            lock.lock(); defer { lock.unlock() }
            paths.remove(path)
        }
    }

    /// Every facade for one live native identity shares this state. Its native
    /// owner prevents pointer reuse while the weak interner can recover it.
    final class StoreState {
        let identity: StoreIdentity
        let attachments: Attachments
        let owner: any LatticeBackend

        init(storage: Lattice.Configuration.Storage, backend: any LatticeBackend) {
            owner = backend
            identity = .capture(storage: storage, backend: backend)
            attachments = Attachments()
        }
        init(identity: StoreIdentity, backend: any LatticeBackend, attachments: Attachments) {
            self.identity = identity
            owner = backend
            self.attachments = attachments
        }
        var mayHaveAttachments: Bool { attachments.mayHaveAttachments }
        func attached(_ path: String) { attachments.attached(path) }
        func detached(_ path: String) { attachments.detached(path) }
    }

    private static let key = "Lattice.TransactionFailureScope"
    private let previous: TransactionFailureScope?
    private let identityHash: Int64
    private let storeState: StoreState
    private let allowsIndependentStores: Bool
    private(set) var firstError: String?

    static var isActive: Bool {
        Thread.current.threadDictionary[key] is TransactionFailureScope
    }

    static func isActive(identityHash: Int64) -> Bool { scope(for: identityHash) != nil }

    /// Reject re-entry before BEGIN, including another connection or pathname
    /// for the same physical file. Unknown identity refuses nested admission.
    static func canEnter(identityHash: Int64, storeState: StoreState) -> Bool {
        var current = Thread.current.threadDictionary[key] as? TransactionFailureScope
        if current != nil && storeState.mayHaveAttachments { return false }
        while let scope = current {
            if !scope.allowsIndependentStores || scope.storeState.mayHaveAttachments
                || scope.identityHash == identityHash
                || scope.storeState.identity.mayAlias(storeState.identity) { return false }
            current = scope.previous
        }
        return true
    }

    init(identityHash: Int64, storeState: StoreState, allowsIndependentStores: Bool = true) {
        let dictionary = Thread.current.threadDictionary
        previous = dictionary[Self.key] as? TransactionFailureScope
        self.identityHash = identityHash
        self.storeState = storeState
        self.allowsIndependentStores = allowsIndependentStores
        dictionary[Self.key] = self
    }

    func restore() {
        let dictionary = Thread.current.threadDictionary
        if let previous {
            dictionary[Self.key] = previous
        } else {
            dictionary.removeObject(forKey: Self.key)
        }
    }

    private static func scope(for identityHash: Int64) -> TransactionFailureScope? {
        var current = Thread.current.threadDictionary[key] as? TransactionFailureScope
        while let scope = current {
            if scope.identityHash == identityHash { return scope }
            current = scope.previous
        }
        return nil
    }

    static func record(_ message: String, identityHash: Int64?) {
        guard let identityHash, let scope = scope(for: identityHash), scope.firstError == nil else { return }
        scope.firstError = message
    }
}
