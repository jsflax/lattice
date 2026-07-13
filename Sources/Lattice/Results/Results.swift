import Foundation
#if canImport(os)
import os
#endif
#if canImport(Combine)
import Combine
#endif
import LatticeSwiftCppBridge
#if canImport(MapKit)
import MapKit
#endif

public protocol Results<Element>: Sequence, RandomAccessCollection where SubSequence == Slice<Element> {
    associatedtype Element
    associatedtype QueryType: _Query<Element>
    associatedtype UnderlyingElement

    func `where`(_ query: (QueryType) -> Query<Bool>) -> Self
    /// Sort by a `Foundation.SortDescriptor`. Requires iOS 17 because
    /// `SortDescriptor.keyPath` — the only way to recover the sort column — is
    /// iOS 17+. On older deployment targets use `sortedBy(_:order:)` with a key
    /// path, which carries the column directly.
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    func sortedBy(_ sortDescriptor: SortDescriptor<Element>) -> Self
    /// Sort by a key path. Available on all deployment targets.
    func sortedBy<V>(_ keyPath: KeyPath<Element, V>, order: SortOrder) -> Self
    func group<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> Self
    func distinct<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> Self
    func observe(_ observer: @escaping (CollectionChange) -> Void) -> AnyCancellable
    func snapshot(limit: Int64?, offset: Int64?) -> [Element]

    var sendableReference: ResultsThreadSafeReference<Self> { get }

    /// Find the k nearest neighbors to a query vector.
    /// Returns objects sorted by distance (closest first).
    ///
    /// When called on filtered results (via `.where()`), only objects matching
    /// the filter are considered for the search.
    ///
    /// Example:
    /// ```swift
    /// // Search all documents
    /// let similar = lattice.objects(Document.self)
    ///     .nearest(to: queryEmbedding, on: \.embedding, limit: 10)
    ///
    /// // Search only in a specific category
    /// let filtered = lattice.objects(Document.self)
    ///     .where { $0.category == "science" }
    ///     .nearest(to: queryEmbedding, on: \.embedding, limit: 10)
    /// ```
    func nearest<V: VectorElement>(
        to queryVector: Vector<V>,
        on keyPath: KeyPath<UnderlyingElement, Vector<V>>,
        limit k: Int,
        distance metric: DistanceMetric
    ) -> any NearestResults<UnderlyingElement>

    /// Filter results to objects within a geographic bounding box.
    /// Uses R*Tree spatial index for efficient queries.
    /// Returns Self for chaining.
    func withinBounds<G: GeoboundsProperty>(
        _ keyPath: KeyPath<Element, G>,
        minLat: Double, maxLat: Double,
        minLon: Double, maxLon: Double
    ) -> Self

    /// Find objects nearest to a geographic point within a radius.
    /// Uses R*Tree spatial index for efficient queries.
    /// Returns a chainable Results type where Element is NearestMatch.
    func nearest<G: GeoboundsProperty>(
        to location: (latitude: Double, longitude: Double),
        on keyPath: KeyPath<UnderlyingElement, G>,
        maxDistance: Double,
        unit: DistanceUnit,
        limit: Int,
        sortedByDistance: Bool
    ) -> any NearestResults<UnderlyingElement>

    // MARK: Item A additive API (§1.7)

    /// Force the next access to advance the generation and drop caches.
    /// Default: no-op for conformers that serve statement-fresh reads.
    func refresh()

    /// Non-trapping indexed access: the element at `index`, or nil instead
    /// of the tolerant ladder's fabricate-something rungs (§1.2 rung (d)).
    func element(at index: Int) -> Element?

    /// Not public API — the tolerant ladder's last resort (§1.2 rung (d)): a
    /// freshly hydrated invalidated placeholder instance (column defaults,
    /// `isInvalidated`-style semantics). Every in-repo conformer provides
    /// one; the default is nil for conformers whose Element carries no
    /// constructible default.
    func _ladderPlaceholder() -> Element?
}

@dynamicMemberLookup
public protocol NearestMatch<Element> {
    associatedtype Element
    
    var object: Element { get }
    
    var distance: Double { get }
    
    func distance(for propertyName: String) -> Double?
    
    subscript<V>(dynamicMember keyPath: KeyPath<Element, V>) -> V { get }
}

/// Result from a nearest neighbor query
@dynamicMemberLookup
public struct _NearestMatch<Element> : NearestMatch {
    public let object: Element
    /// All distances keyed by property name (e.g., "location", "embedding")
    public let distances: [String: Double]

    /// Primary distance - first available distance value
    public var distance: Double {
        distances.values.first ?? 0
    }

    /// Get distance for a specific property
    public func distance(for propertyName: String) -> Double? {
        distances[propertyName]
    }

    public init(object: Element, distance: Double) {
        self.object = object
        self.distances = ["_default": distance]
    }

    public init(object: Element, distances: [String: Double]) {
        self.object = object
        self.distances = distances
    }

    /// Access properties on the underlying object directly
    public subscript<V>(dynamicMember keyPath: KeyPath<Element, V>) -> V {
        object[keyPath: keyPath]
    }
}

/// Distance metric for vector search
public enum DistanceMetric: Int32, Sendable {
    case l2 = 0      // Euclidean distance (default)
    case cosine = 1  // Cosine distance
    case l1 = 2      // Manhattan distance
}

public final class Cursor<Element>: IteratorProtocol {
    // Captures the concrete results' snapshot rather than storing
    // `any Results<Element>` (a parameterized existential — an iOS-16 runtime
    // floor). The closure pins the concrete type at construction.
    private let _snapshot: (_ limit: Int64, _ offset: Int64) -> [Element]
    private let batchSize: Int64 = 100
    private var batch: [Element] = []
    private var batchStart: Int64 = 0
    private var indexInBatch: Int = 0

    package init(_ results: some Results<Element>) {
        self._snapshot = { limit, offset in results.snapshot(limit: limit, offset: offset) }
    }

    public func next() -> Element? {
        // Fetch in batches to avoid O(n²) OFFSET penalty
        if indexInBatch >= batch.count {
            batch = _snapshot(batchSize, batchStart)
            batchStart += Int64(batch.count)
            indexInBatch = 0
        }
        guard indexInBatch < batch.count else { return nil }
        defer { indexInBatch += 1 }
        return batch[indexInBatch]
    }
}

public struct Slice<Element>: RandomAccessCollection, Sequence {
    public var startIndex: Int
    public var endIndex: Int
    // Snapshot closure, not a stored `any Results<Element>` (iOS-16 floor).
    private let _snapshot: (_ limit: Int64, _ offset: Int64) -> [Element]
    // Item A §1.4: the slice routes indexed access through the parent
    // results' tolerant ladder (rungs a–c via `element(at:)`, rung (d) via
    // `_ladderPlaceholder()`) — no independent trap.
    private let _element: (_ index: Int) -> Element?
    private let _placeholder: () -> Element?
    public typealias Index = Int

    fileprivate init(results: some Results<Element>, startIndex: Int, endIndex: Int) {
        self.startIndex = startIndex
        self.endIndex = endIndex
        self._snapshot = { limit, offset in results.snapshot(limit: limit, offset: offset) }
        self._element = { index in results.element(at: index) }
        self._placeholder = { results._ladderPlaceholder() }
    }

    private init(snapshot: @escaping (_ limit: Int64, _ offset: Int64) -> [Element],
                 element: @escaping (_ index: Int) -> Element?,
                 placeholder: @escaping () -> Element?,
                 startIndex: Int, endIndex: Int) {
        self.startIndex = startIndex
        self.endIndex = endIndex
        self._snapshot = snapshot
        self._element = element
        self._placeholder = placeholder
    }

    public subscript(bounds: Range<Int>) -> Self {
        .init(snapshot: _snapshot, element: _element, placeholder: _placeholder,
              startIndex: bounds.lowerBound, endIndex: bounds.upperBound)
    }

    public subscript(position: Int) -> Element {
        get {
            // Tolerant ladder (§1.2): never trap. Cross-generation indices
            // are NORMAL under write bursts (SwiftUI diffs at count N and
            // realizes rows later); a stale index serves a stale/placeholder
            // element for one frame instead of aborting the process.
            if let element = _element(position) {
                return element
            }
            if let placeholder = _placeholder() {
                return placeholder
            }
            // Unreachable for every in-repo conformer (all provide
            // placeholders); reachable only for a third-party `Results`
            // conformer that opted out of `_ladderPlaceholder()`.
            preconditionFailure("Slice index \(position) out of bounds and \(Element.self) has no placeholder representation")
        }
    }

    public func index(after i: Int) -> Int {
        i + 1
    }

    public func index(before i: Int) -> Int {
        i - 1
    }

    // Efficient batch iterator - fetches entire range at once
    public struct Iterator: IteratorProtocol {
        private var elements: [Element]
        private var index: Int = 0

        fileprivate init(snapshot: (_ limit: Int64, _ offset: Int64) -> [Element], start: Int, end: Int) {
            let count = end - start
            if count > 0 {
                self.elements = snapshot(Int64(count), Int64(start))
            } else {
                self.elements = []
            }
        }

        public mutating func next() -> Element? {
            guard index < elements.count else { return nil }
            defer { index += 1 }
            return elements[index]
        }
    }

    public func makeIterator() -> Iterator {
        Iterator(snapshot: _snapshot, start: startIndex, end: endIndex)
    }
}

extension Results {
    public func snapshot() -> [Element] {
        snapshot(limit: nil, offset: nil)
    }

    public func makeIterator() -> Cursor<Element> {
        Cursor(self)
    }

    // MARK: Item A additive API defaults (§1.7)

    /// Default: statement-fresh conformers have no caches to drop.
    /// `TableResults` overrides to advance its lattice's generation.
    public func refresh() {}

    /// Default non-trapping indexed access for statement-fresh conformers:
    /// one live fetch; nil when the row is absent at read time.
    /// `TableResults` overrides with the shape-cache ladder (§1.2).
    public func element(at index: Int) -> Element? {
        guard index >= 0 else { return nil }
        return snapshot(limit: 1, offset: Int64(index)).first
    }

    /// Default: no constructible placeholder. Every in-repo conformer
    /// provides a witness (an unmanaged default-valued instance).
    public func _ladderPlaceholder() -> Element? { nil }

    public subscript(index: Int) -> Element {
        // Tolerant ladder (§1.2): never trap. Rungs (a–c) via
        // `element(at:)`; rung (d) — a freshly hydrated invalidated
        // placeholder (defaults) — instead of the old
        // `fatalError("Index out of bounds")`. A stale index under a write
        // burst renders a blank/stale row for one frame instead of aborting
        // the process.
        if let element = element(at: index) {
            return element
        }
        if let placeholder = _ladderPlaceholder() {
            return placeholder
        }
        // Unreachable for every in-repo conformer (all provide placeholders);
        // reachable only for a third-party conformer that opted out.
        preconditionFailure("Results index \(index) out of bounds and \(Element.self) has no placeholder representation")
    }

    public subscript(bounds: Range<Int>) -> Slice<Element> {
        Slice(results: self, startIndex: bounds.lowerBound, endIndex: bounds.upperBound)
    }
    
    #if canImport(MapKit)
    public func withinBounds<G: GeoboundsProperty>(
        of region: MKCoordinateRegion,
        on keyPath: KeyPath<Element, G>
    ) -> Self {
        let bbox = region.boundingBox
        return self.withinBounds(keyPath, minLat: bbox.minLat, maxLat: bbox.maxLat,
                                 minLon: bbox.minLon, maxLon: bbox.maxLon)
    }
    
    /// Find objects nearest to a geographic point (sorted by distance, limit 100)
    public func nearest<G: GeoboundsProperty>(
        to location: CLLocationCoordinate2D,
        on keyPath: KeyPath<UnderlyingElement, G>,
        maxDistance: Double,
        unit: DistanceUnit = .meters
    ) -> any NearestResults<UnderlyingElement> {
        nearest(to: (location.latitude, location.longitude),
                on: keyPath, maxDistance: maxDistance, unit: unit, limit: 100, sortedByDistance: true)
    }
    #endif

    public func nearest<V: VectorElement>(
        to queryVector: Vector<V>,
        on keyPath: KeyPath<UnderlyingElement, Vector<V>>,
        distance metric: DistanceMetric = .l2
    ) -> any NearestResults<UnderlyingElement> {
        nearest(to: queryVector, on: keyPath, limit: 10, distance: metric)
    }

    public func nearest<V: VectorElement>(
        to queryVector: Vector<V>,
        on keyPath: KeyPath<UnderlyingElement, Vector<V>>,
        limit k: Int = 10
    ) -> any NearestResults<UnderlyingElement> {
        nearest(to: queryVector, on: keyPath, limit: k, distance: .l2)
    }

    // MARK: - Geo nearest convenience overloads

    /// Find objects nearest to a geographic point (sorted by distance, limit 100)
    public func nearest<G: GeoboundsProperty>(
        to location: (latitude: Double, longitude: Double),
        on keyPath: KeyPath<UnderlyingElement, G>,
        maxDistance: Double,
        unit: DistanceUnit = .meters
    ) -> any NearestResults<UnderlyingElement> {
        nearest(to: location, on: keyPath, maxDistance: maxDistance, unit: unit, limit: 100, sortedByDistance: true)
    }

    /// Find objects nearest to a geographic point with custom limit
    public func nearest<G: GeoboundsProperty>(
        to location: (latitude: Double, longitude: Double),
        on keyPath: KeyPath<UnderlyingElement, G>,
        maxDistance: Double,
        unit: DistanceUnit = .meters,
        limit: Int
    ) -> any NearestResults<UnderlyingElement> {
        nearest(to: location, on: keyPath, maxDistance: maxDistance, unit: unit, limit: limit, sortedByDistance: true)
    }
}

public enum CollectionChange: Sendable {
    case insert(Int64)
    case update(Int64)
    case delete(Int64)
}

#if canImport(Combine)
/// A publisher that subscribes to C++ table observers on demand.
/// Used as `objectWillChange` for Results types — observation is lazy,
/// only active while SwiftUI (or any Combine subscriber) is subscribed.
public struct ResultsChangePublisher: Publisher {
    public typealias Output = Void
    public typealias Failure = Never

    private let _subscribe: (@escaping (CollectionChange) -> Void) -> AnyCancellable

    init(subscribe: @escaping (@escaping (CollectionChange) -> Void) -> AnyCancellable) {
        self._subscribe = subscribe
    }

    public func receive<S: Subscriber>(subscriber: S) where S.Input == Void, S.Failure == Never {
        let subscription = Subscription(subscriber: subscriber, subscribe: _subscribe)
        subscriber.receive(subscription: subscription)
    }

    private final class Subscription<S: Subscriber>: Combine.Subscription where S.Input == Void, S.Failure == Never {
        private var subscriber: S?
        private var token: AnyCancellable?

        init(subscriber: S, subscribe: (@escaping (CollectionChange) -> Void) -> AnyCancellable) {
            self.subscriber = subscriber
            self.token = subscribe { [weak self] _ in
                _ = self?.subscriber?.receive(())
            }
        }

        func request(_ demand: Subscribers.Demand) {}

        func cancel() {
            token?.cancel()
            token = nil
            subscriber = nil
        }
    }
}
#endif

/// Never-trap fallback for `@Relation` access on not-yet-inserted instances:
/// one process-shared, private in-memory lattice per Element type, holding an
/// empty table for the Element so every read legitimately answers empty.
/// `.memory()` construction with a known model type is guaranteed-valid per
/// the 1.0 error policy (no file IO — the same justification as
/// `LatticeEnvironmentKey.defaultValue`); the `preconditionFailure` below is
/// therefore unreachable and exists only to satisfy the non-optional return.
enum _EmptyResultsFallback {
    private static let lock = UnfairLock<[ObjectIdentifier: Lattice]>(initialState: [:])

    static func results<M: Model>(for type: M.Type) -> TableResults<M> {
        let key = ObjectIdentifier(type)
        if let existing = lock.withLockUnchecked({ $0[key] }) {
            return TableResults(existing)
        }
        // Opening a lattice takes DB-level locks — never do it while holding
        // our registry lock (leaf-lock rule, §2.3).
        guard let fresh = try? Lattice(M.self, configuration: .init(storage: .memory())) else {
            preconditionFailure("empty in-memory fallback lattice failed to open for \(M.self)")
        }
        let lattice = lock.withLockUnchecked { state -> Lattice in
            if let existing = state[key] { return existing }
            state[key] = fresh
            return fresh
        }
        return TableResults(lattice)
    }
}

@propertyWrapper public struct Relation<EnclosingType: Model, Element: Model> {
    // Concrete `TableResults<Element>`, not the protocol `Results<Element>`. The
    // property-wrapper enclosing-instance subscript takes a
    // `ReferenceWritableKeyPath<EnclosingType, Value>` — and a KeyPath whose Value
    // is a parameterized existential (`any Results<Element>`) is an iOS-16 runtime
    // floor (only KeyPath/array/generic-arg positions trip it; a bare property of
    // that type is fine). The getter only ever builds a TableResults, so pinning
    // Value to the concrete type keeps @Relation usable on iOS 15. Declare
    // relations as `@Relation(...) var foo: TableResults<Child>`.
    public typealias Value = TableResults<Element>

    public static subscript(
        _enclosingInstance instance: EnclosingType,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<EnclosingType, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<EnclosingType, Self>
    ) -> Value {
        get {
            guard let lattice = instance.lattice, let primaryKey = instance.primaryKey else {
                // Item A never-trap policy (§1.2): accessing @Relation on an
                // instance that is not yet inserted used to fatalError. A
                // not-yet-inserted parent has no children by definition —
                // serve an EMPTY results facade over a process-shared,
                // private in-memory lattice holding only the (empty) Element
                // table, instead of aborting.
                Logger.db.warning("@Relation accessed on an instance that is not yet inserted into the database — returning empty results")
                return _EmptyResultsFallback.results(for: Element.self)
            }
            let link = instance[keyPath: storageKeyPath].link

            return TableResults(lattice, whereStatement: {
                $0[dynamicMember: link].primaryKey == primaryKey
            })
        }
        set {

        }
    }

    @available(*, unavailable,
                message: "@Relation can only be applied to models")
    public var wrappedValue: Value {
        get { fatalError() }
        set { fatalError() }
    }
    
    private let link: KeyPath<Element, EnclosingType?> & Sendable
    public init(link: KeyPath<Element, EnclosingType?> & Sendable) {
        self.link = link
    }
}

//@propertyWrapper public struct InverseRelation<EnclosingType: Model, Parent: Model> {
//    public typealias Value = Results<Parent>
//    
//    public static subscript(
//        _enclosingInstance instance: EnclosingType,
//        wrapped wrappedKeyPath: ReferenceWritableKeyPath<EnclosingType, Value>,
//        storage storageKeyPath: ReferenceWritableKeyPath<EnclosingType, Self>
//    ) -> Value {
//        get {
//            guard let lattice = instance.lattice, let primaryKey = instance.primaryKey else {
//                fatalError("Cannot use @Relation on an instance that is not yet inserted into the database")
//            }
//            let link = instance[keyPath: storageKeyPath].link
//            
//            return Results(lattice, whereStatement: {
//                $0.primaryKey.in($0[dynamicMember: link])
//            })
//        }
//        set {
//            
//        }
//    }
//    
//    @available(*, unavailable,
//                message: "@Relation can only be applied to models")
//    public var wrappedValue: Value {
//        get { fatalError() }
//        set { fatalError() }
//    }
//    
//    private let link: KeyPath<Parent, Array<EnclosingType>> & Sendable
//    public init(link: KeyPath<Parent, Array<EnclosingType>> & Sendable) {
//        self.link = link
//    }
//}
