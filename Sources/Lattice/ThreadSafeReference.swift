import Foundation

public protocol SendableReference<NonSendable>: Sendable {
    associatedtype NonSendable

    func resolve(on lattice: Lattice) -> NonSendable?
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
        self._resolve = { reference.resolve(on: $0) }
    }

    public func resolve(on lattice: Lattice) -> NonSendable? {
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
    
    public func resolve(on lattice: Lattice) -> NonSendable? {
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
        let optKeys: [Int64?] = keys.map { $0 }
        let fetched = lattice.objects(T.self).where { $0.primaryKey.in(optKeys) }.snapshot()
        let byKey: [Int64: T] = Dictionary(uniqueKeysWithValues: fetched.compactMap { obj in
            obj.primaryKey.map { ($0, obj) }
        })
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

    public func resolve(on lattice: Lattice) -> R? {
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
        return .init { lattice in
            TableResults(lattice, whereStatement: whereStatement, sortStatement: sortComparator)
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

public struct LatticeThreadSafeReference: Sendable {
    private let modelTypes: [Model.Type]
    private let configuration: Lattice.Configuration
    
    init(modelTypes: [Model.Type], configuration: Lattice.Configuration) {
        self.modelTypes = modelTypes
        self.configuration = configuration
    }
    
    public func resolve(isolation: isolated (any Actor)? = #isolation) -> Lattice? {
        // Don't resurrect a deleted database. If the backing file was removed
        // (e.g. by `Lattice.delete` during a logout wipe), an in-flight observe
        // trampoline that re-resolves must bail rather than reopen — reopening
        // would recreate an empty `.sqlite` on disk and fire a spurious empty
        // snapshot. For in-memory configs there is no file to check.
        if !configuration.isStoredInMemoryOnly,
           !FileManager.default.fileExists(atPath: configuration.fileURL.path(percentEncoded: false)) {
            return nil
        }
        return try? Lattice(for: self.modelTypes, configuration: configuration)
    }
}

extension Lattice {
    public var sendableReference: LatticeThreadSafeReference {
        .init(modelTypes: self.modelTypes, configuration: self.configuration)
    }
}
