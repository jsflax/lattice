import Foundation
import SQLite3
import Combine
import LatticeSwiftCppBridge
#if canImport(MapKit)
import MapKit
#endif

public protocol Results<Element>: Sequence, RandomAccessCollection where SubSequence == Slice<Element> {
    associatedtype Element
    associatedtype QueryType: _Query<Element>
    associatedtype UnderlyingElement

    func `where`(_ query: (QueryType) -> Query<Bool>) -> Self
    func sortedBy(_ sortDescriptor: SortDescriptor<Element>) -> Self
    func group<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> Self
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
    private let results: any Results<Element>
    private let batchSize: Int64 = 100
    private var batch: [Element] = []
    private var batchStart: Int64 = 0
    private var indexInBatch: Int = 0

    package init(_ results: some Results<Element>) {
        self.results = results
    }

    public func next() -> Element? {
        // Fetch in batches to avoid O(n²) OFFSET penalty
        if indexInBatch >= batch.count {
            batch = results.snapshot(limit: batchSize, offset: batchStart)
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
    private let results: any Results<Element>
    public typealias Index = Int

    fileprivate init(results: some Results<Element>, startIndex: Int, endIndex: Int) {
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.results = results
    }

    public subscript(bounds: Range<Int>) -> Self {
        .init(results: results, startIndex: bounds.lowerBound, endIndex: bounds.upperBound)
    }

    public subscript(position: Int) -> Element {
        get {
            // Fetch single element at position (live)
            let objects = results.snapshot(limit: 1, offset: Int64(position))
            guard let obj = objects.first else {
                fatalError("Index out of bounds: \(position)")
            }
            return obj
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

        fileprivate init(results: some Results<Element>, start: Int, end: Int) {
            let count = end - start
            if count > 0 {
                self.elements = results.snapshot(limit: Int64(count), offset: Int64(start))
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
        Iterator(results: results, start: startIndex, end: endIndex)
    }
}

extension Results {
    public func snapshot() -> [Element] {
        snapshot(limit: nil, offset: nil)
    }

    public func makeIterator() -> Cursor<Element> {
        Cursor(self)
    }
    
    public subscript(index: Int) -> Element {
        // Live fetch - always queries DB
        let objects = snapshot(limit: 1, offset: Int64(index))
        guard let obj = objects.first else {
            fatalError("Index out of bounds: \(index)")
        }
        return obj
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
    case delete(Int64)
}

@propertyWrapper public struct Relation<EnclosingType: Model, Element: Model> {
    public typealias Value = Results<Element>
    
    public static subscript(
        _enclosingInstance instance: EnclosingType,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<EnclosingType, any Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<EnclosingType, Self>
    ) -> any Value {
        get {
            guard let lattice = instance.lattice, let primaryKey = instance.primaryKey else {
                fatalError("Cannot use @Relation on an instance that is not yet inserted into the database")
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
