import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public protocol SendableReference<NonSendable>: Sendable {
    associatedtype NonSendable

    func resolve(isolation: isolated (any Actor)?, on lattice: Lattice) -> NonSendable?
}

/// Concrete type-eraser for `SendableReference`. Replaces `any
/// SendableReference<T>` (a parameterized existential — an iOS-16 runtime
/// floor) at the few sites that need a heterogeneous/erased reference (e.g.
/// `Lattice.changeStream`'s `[…]` element). `SendableReference` has a single
/// requirement, so the eraser is just a captured `@Sendable (Lattice) -> T?`
/// closure.
public struct AnySendableReference<NonSendable>: SendableReference {
    private let _resolve: @Sendable (Lattice) -> NonSendable?

    public init<R: SendableReference>(_ reference: R) where R.NonSendable == NonSendable {
        self._resolve = { reference.resolve(isolation: nil, on: $0) }
    }

    public func resolve(isolation: isolated (any Actor)? = #isolation,
                        on lattice: Lattice) -> NonSendable? {
        _resolve(lattice)
    }
}

public protocol LatticeIsolated {
}

public struct ModelThreadSafeReference<NonSendable: Model>: SendableReference, Equatable {
    fileprivate let key: Int64?
    public init(_ model: NonSendable) {
        self.key = model.primaryKey
    }
    /// A reference from a primary key alone — no row is loaded to make it.
    /// `changeStream` builds its `AuditLog` references this way: hydrating the
    /// row just to read its key back read the whole audit payload per change.
    public init(primaryKey: Int64) {
        self.key = primaryKey
    }
    
    public func resolve(isolation: isolated (any Actor)? = #isolation,
                        on lattice: Lattice) -> NonSendable? {
        if let key {
            return lattice.object(NonSendable.self, primaryKey: key)
        }
        return nil
    }
//    public func resolve(isolation: isolated (any Actor)? = #isolation,
//                        on lattice: Lattice) async -> T? {
//        if let key {
//            let object = T()
//            object._assign(lattice: lattice)
//            object.primaryKey = key
//            await lattice.dbPtr.insertModelObserver(
//                tableName: T.entityName,
//                primaryKey: key,
//                object.weakCapture(isolation: #isolation))
//            return object
//        }
//        return nil
//    }
    
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key == rhs.key
    }
}

extension Model {
    public var sendableReference: ModelThreadSafeReference<Self> {
        .init(self)
    }
}

extension Collection {
    /// Batch-resolve references in a single `SELECT ... WHERE id IN (...)` query.
    /// Input order is preserved; missing rows are skipped.
    public func resolve<T: Model>(on lattice: Lattice) -> [T]
    where Element == ModelThreadSafeReference<T> {
        let keys = self.compactMap(\.key)
        guard !keys.isEmpty else { return [] }
        // Chunked (C2): `.in(collection)` renders every element as a literal
        // in the SQL text, so an unbounded reference collection produced an
        // unbounded statement (multi-MB text for tens of thousands of keys —
        // pure parse cost and memory; SQLite handles flat IN lists
        // iteratively, so this is a perf bound, not a stack one).
        let chunkSize = 500
        var byKey: [Int64: T] = [:]
        byKey.reserveCapacity(keys.count)
        var start = keys.startIndex
        while start < keys.endIndex {
            let end = keys.index(start, offsetBy: chunkSize, limitedBy: keys.endIndex) ?? keys.endIndex
            let optKeys: [Int64?] = keys[start..<end].map { $0 }
            let fetched = lattice.objects(T.self).where { $0.primaryKey.in(optKeys) }.snapshot()
            for obj in fetched {
                if let pk = obj.primaryKey { byKey[pk] = obj }
            }
            start = end
        }
        return self.compactMap { $0.key.flatMap { byKey[$0] } }
    }
}

// A thread-safe reference to a `Results` query. iOS-15 note: this used to store
// an `any AnyResultsThreadSafeReference<R>` (a parameterized existential — an
// iOS-16 runtime floor) and reach it through `as!` casts to that constrained
// existential (also iOS-16). It now stores a plain `@Sendable (Lattice) -> R?`
// resolve closure: a concrete type-eraser that back-deploys to iOS 15 and drops
// every `as!` cast. Each `sendableReference` accessor captures its query state
// into the closure and rebuilds the concrete `Results` on `resolve`.
public struct ResultsThreadSafeReference<R: Results>: SendableReference {
    private let _resolve: @Sendable (Lattice) -> R?

    fileprivate init(_ resolve: @escaping @Sendable (Lattice) -> R?) {
        self._resolve = resolve
    }

    public func resolve(isolation: isolated (any Actor)? = #isolation,
                        on lattice: Lattice) -> R? {
        _resolve(lattice)
    }
}

extension TableResults {
    public var sendableReference: ResultsThreadSafeReference<TableResults<Element>> {
        let whereStatement = self.whereStatement
        // Capture the sort as an existential to avoid a direct SortDescriptor type
        // metadata reference at link time (swift-foundation bug: AllowedComparison
        // metadata not exported on Linux release builds).
        let sortComparator: (any SortComparator)? = self.sortStatement
        let boundsConstraint = self.boundsConstraint
        let groupByColumn = self.groupByColumn
        let distinctByColumn = self.distinctByColumn
        let fetchLimit = self._fetchLimit
        return .init { lattice in
            // Rebuild the query on the receiving handle without carrying live
            // instances, generation state, or the source handle's isolation.
            let results = TableResults<Element>(
                lattice, whereStatement: whereStatement, sortStatement: sortComparator,
                boundsConstraint: boundsConstraint, groupByColumn: groupByColumn,
                distinctByColumn: distinctByColumn)
            results._fetchLimit = fetchLimit
            return results
        }
    }
}

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
extension _VirtualResults {
    public var sendableReference: ResultsThreadSafeReference<_VirtualResults<repeat each M, Element>> {
        let whereStatement = self.whereStatement
        let sortComparator: (any SortComparator)? = self.sortStatement
        return .init { lattice in
            Self(lattice, whereStatement: whereStatement, sortStatement: sortComparator)
        }
    }
}

extension _VirtualResultsCompat {
    public var sendableReference: ResultsThreadSafeReference<_VirtualResultsCompat<Element>> {
        // iOS 15 compat: the model-type list is carried as stored data (it no
        // longer rides in the generic signature the way the pack version's does).
        let modelTypes = self.modelTypes
        let whereStatement = self.whereStatement
        let sortComparator: (any SortComparator)? = self.sortStatement
        return .init { lattice in
            Self(lattice, modelTypes: modelTypes, whereStatement: whereStatement, sortStatement: sortComparator)
        }
    }
}

extension TableNearestResults {
    public var sendableReference: ResultsThreadSafeReference<TableNearestResults<T>> {
        let whereStatement = self.whereStatement
        let sortStatement = self.sortStatement
        let boundsConstraint = self.boundsConstraint
        let proximity = self.proximity
        return .init { lattice in
            TableNearestResults(lattice: lattice, whereStatement: whereStatement, sortStatement: sortStatement, boundsConstraint: boundsConstraint, proximity: proximity)
        }
    }
}

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
extension _VirtualNearestResults {
    public var sendableReference: ResultsThreadSafeReference<_VirtualNearestResults<repeat each M, T>> {
        let whereStatement = self.whereStatement
        let sortStatement = self.sortStatement
        let boundsConstraint = self.boundsConstraint
        let proximity = self.proximity
        return .init { lattice in
            Self(lattice: lattice, whereStatement: whereStatement, sortStatement: sortStatement, boundsConstraint: boundsConstraint, proximity: proximity)
        }
    }
}

extension _VirtualNearestResultsCompat {
    public var sendableReference: ResultsThreadSafeReference<_VirtualNearestResultsCompat<T>> {
        // iOS 15 compat: carries the model-type list as stored data.
        let modelTypes = self.modelTypes
        let whereStatement = self.whereStatement
        let sortStatement = self.sortStatement
        let boundsConstraint = self.boundsConstraint
        let proximity = self.proximity
        return .init { lattice in
            Self(lattice: lattice, modelTypes: modelTypes, whereStatement: whereStatement, sortStatement: sortStatement, boundsConstraint: boundsConstraint, proximity: proximity)
        }
    }
}

// Explicit same-process custody of the real native ownership control block.
// The raw box is solely a fork-safe ARC holder: its value is never decoded or
// used as authority. Native validation is still required at every resolution.
// An inherited child intentionally quarantines its copied box rather than
// invoking a native destructor that could enter inherited locked state.
internal final class ManagedLatticeReferenceOwner: @unchecked Sendable {
    private final class Box {
        let store: Lattice
        init(_ store: Lattice) { self.store = store }
    }
    private let creator: Int32
    private let box: UnsafeMutableRawPointer
    private static func process() -> Int32 {
        #if canImport(Darwin) || canImport(Glibc)
        return getpid()
        #else
        return 0 // No supported managed issuer on this platform.
        #endif
    }
    init(_ store: Lattice) {
        creator = Self.process()
        box = Unmanaged.passRetained(Box(store)).toOpaque()
    }
    deinit {
        if creator == 0 || creator == Self.process() {
            Unmanaged<Box>.fromOpaque(box).release()
        }
    }
    func resolve(isolation: isolated (any Actor)?) -> Lattice? {
        guard creator != 0, creator == Self.process() else { return nil }
        return Unmanaged<Box>.fromOpaque(box).takeUnretainedValue().store
            .resolveRetainedManagedOwner(isolation: isolation)
    }
}

public struct LatticeThreadSafeReference: Sendable {
    private let modelTypes: [any Model.Type]
    private let configuration: Lattice.Configuration
    private let managedOwner: ManagedLatticeReferenceOwner?

    init(modelTypes: [any Model.Type], configuration: Lattice.Configuration,
         managedOwner: ManagedLatticeReferenceOwner? = nil) {
        self.modelTypes = modelTypes
        self.configuration = configuration
        self.managedOwner = managedOwner
    }
    
    public func resolve(isolation: isolated (any Actor)? = #isolation) -> Lattice? {
        if configuration.ordinaryInstallationContext != nil {
            // No ordinary-open/profile capability can be recovered from the
            // configuration when a retained actual owner is absent or closed.
            return managedOwner?.resolve(isolation: isolation)
        }
        // Don't resurrect a deleted database. If the backing file was removed
        // (e.g. by `Lattice.delete` during a logout wipe), an in-flight observe
        // trampoline that re-resolves must bail rather than reopen — reopening
        // would recreate an empty `.sqlite` on disk and fire a spurious empty
        // snapshot. For in-memory configs there is no file to check.
        guard !_backingFileIsMissing else { return nil }
        return try? Lattice(isolation: isolation, for: self.modelTypes, configuration: configuration)
    }

    /// The same best-effort deletion guard used by resolve(), without opening
    /// a database. Memory stores have no backing file to check.
    internal var _backingFileIsMissing: Bool {
        if case .file(let url) = configuration.storage {
            return !FileManager.default.fileExists(atPath: url.path)
        }
        return false
    }
}

extension Lattice {
    public var sendableReference: LatticeThreadSafeReference {
        .init(modelTypes: self.modelTypes, configuration: self.configuration,
              managedOwner: configuration.ordinaryInstallationContext == nil ? nil : ManagedLatticeReferenceOwner(self))
    }
}
