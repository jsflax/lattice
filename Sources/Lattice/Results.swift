import Foundation
import SQLite3
import Combine
import LatticeSwiftCppBridge

public final class Results<Element>: Sequence where Element: Model {
    private let _lattice: Lattice
    internal let whereStatement: Query<Bool>?
    internal let sortStatement: SortDescriptor<Element>?

    // Helper to build query parameters - always fetches fresh from DB (live results)
    private func queryObjects(limit: Int64? = nil, offset: Int64? = nil) -> [Element] {
        let tableName = std.string(Element.entityName)
        let whereClause: lattice.OptionalString = if let whereStatement {
            lattice.string_to_optional(std.string(whereStatement.predicate))
        } else {
            .init()
        }
        let orderBy: lattice.OptionalString = if let sortStatement, let keyPath = sortStatement.keyPath {
            lattice.string_to_optional(std.string("\(_name(for: keyPath)) \(sortStatement.order == .forward ? "ASC" : "DESC")"))
        } else {
            .init()
        }
        let limitOpt: lattice.OptionalInt64 = if let limit { lattice.int64_to_optional(limit) } else { .init() }
        let offsetOpt: lattice.OptionalInt64 = if let offset { lattice.int64_to_optional(offset) } else { .init() }

        let cxxResults = _lattice.cxxLattice.objects(tableName, whereClause, orderBy, limitOpt, offsetOpt)

        var objects: [Element] = []
        objects.reserveCapacity(cxxResults.size())

        for i in 0..<cxxResults.size() {
            var cxxObject = cxxResults[i]
            let object = Element(dynamicObject: CxxDynamicObjectRef.wrap(CxxDynamicObject(cxxObject).make_shared()))
            objects.append(object)
        }

        return objects
    }

    public final class Cursor: IteratorProtocol {
        private let results: Results<Element>
        private let batchSize: Int64 = 100
        private var batch: [Element] = []
        private var batchStart: Int64 = 0
        private var indexInBatch: Int = 0

        package init(_ results: Results<Element>) {
            self.results = results
        }

        public func next() -> Element? {
            // Fetch in batches to avoid O(n²) OFFSET penalty
            if indexInBatch >= batch.count {
                batch = results.queryObjects(limit: batchSize, offset: batchStart)
                batchStart += Int64(batch.count)
                indexInBatch = 0
            }
            guard indexInBatch < batch.count else { return nil }
            defer { indexInBatch += 1 }
            return batch[indexInBatch]
        }
    }

    public func makeIterator() -> Cursor {
        Cursor(self)
    }

    public typealias SubSequence = Slice

    public class Slice: RandomAccessCollection, Sequence {
        public var startIndex: Int
        public var endIndex: Int
        private let results: Results<Element>
        public typealias Index = Int

        fileprivate init(results: Results<Element>, startIndex: Int, endIndex: Int) {
            self.startIndex = startIndex
            self.endIndex = endIndex
            self.results = results
        }

        public subscript(bounds: Range<Int>) -> SubSequence {
            .init(results: results, startIndex: bounds.lowerBound, endIndex: bounds.upperBound)
        }

        public subscript(position: Int) -> Element {
            get {
                // Fetch single element at position (live)
                let objects = results.queryObjects(limit: 1, offset: Int64(position))
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

            fileprivate init(results: Results<Element>, start: Int, end: Int) {
                let count = end - start
                if count > 0 {
                    self.elements = results.queryObjects(limit: Int64(count), offset: Int64(start))
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

    private var token: AnyCancellable?

    init(_ lattice: Lattice, whereStatement: Query<Bool>? = nil, sortStatement: SortDescriptor<Element>? = nil) {
        self._lattice = lattice
        self.whereStatement = whereStatement
        self.sortStatement = sortStatement
    }

    init(_ lattice: Lattice, whereStatement: Predicate<Element>, sortStatement: SortDescriptor<Element>? = nil) {
        self._lattice = lattice
        self.whereStatement = whereStatement(Query())
        self.sortStatement = sortStatement
    }
    
    public subscript(index: Int) -> Element {
        // Live fetch - always queries DB
        let objects = queryObjects(limit: 1, offset: Int64(index))
        guard let obj = objects.first else {
            fatalError("Index out of bounds: \(index)")
        }
        return obj
    }

    public subscript(bounds: Range<Int>) -> Slice {
        Slice(results: self, startIndex: bounds.lowerBound, endIndex: bounds.upperBound)
    }

    public func sortedBy(_ sortDescriptor: SortDescriptor<Element>) -> Results<Element> {
        return Results(_lattice, whereStatement: whereStatement, sortStatement: sortDescriptor)
    }

    public func `where`(_ query: @escaping LatticePredicate<Element>) -> Results<Element> {
        return Results(_lattice, whereStatement: query(Query()))
    }

    public var startIndex: Int { 0 }

    deinit {
        token?.cancel()
    }

    public var endIndex: Int {
        // Live count from C++
        let tableName = std.string(Element.entityName)
        let whereClause: lattice.OptionalString = if let whereStatement {
            lattice.string_to_optional(std.string(whereStatement.predicate))
        } else {
            .init()
        }
        return Int(_lattice.cxxLattice.count(tableName, whereClause))
    }

    public func index(after i: Int) -> Int {
        i + 1
    }

    public enum CollectionChange: Sendable {
        case insert(Int64)
        case delete(Int64)
    }

    public func observe(_ observer: @escaping (CollectionChange) -> Void) -> AnyCancellable {
        _lattice.observe(Element.self, where: self.whereStatement) { change in
            observer(change)
        }
    }

    /// Returns a frozen snapshot of the current results (not live)
    public func snapshot() -> [Element] {
        queryObjects()
    }

    // MARK: - Vector Search

    /// Result from a nearest neighbor query
    public struct NearestMatch {
        public let object: Element
        public let distance: Double
    }

    /// Distance metric for vector search
    public enum DistanceMetric: Int32 {
        case l2 = 0      // Euclidean distance (default)
        case cosine = 1  // Cosine distance
        case l1 = 2      // Manhattan distance
    }

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
    public func nearest<V: VectorElement>(
        to queryVector: Vector<V>,
        on keyPath: KeyPath<Element, Vector<V>>,
        limit k: Int = 10,
        distance metric: DistanceMetric = .l2
    ) -> [NearestMatch] {
        let propertyName = _name(for: keyPath)
        let queryData = queryVector.toData()

        var byteVec = lattice.ByteVector()
        for byte in queryData {
            byteVec.push_back(byte)
        }

        // Build the where clause if we have a filter
        // The predicate uses column names from the model table (aliased as 'm' in the JOIN)
        let whereClause: lattice.OptionalString = if let whereStatement {
            lattice.string_to_optional(std.string(whereStatement.predicate))
        } else {
            .init()
        }

        let cxxResults = _lattice.cxxLattice.nearest_neighbors(
            std.string(Element.entityName),
            std.string(propertyName),
            byteVec,
            Int32(k),
            metric.rawValue,
            whereClause
        )

        var results: [NearestMatch] = []
        results.reserveCapacity(cxxResults.size())

        for i in 0..<cxxResults.size() {
            let pair = cxxResults[i]
            var managedObj = pair.first
            let distance = pair.second

            var swiftObj = Element(dynamicObject: CxxDynamicObjectRef.wrap(CxxDynamicObject(managedObj).make_shared()))
            results.append(NearestMatch(object: swiftObj, distance: distance))
        }

        return results
    }
}

@propertyWrapper public struct Relation<EnclosingType: Model, Element: Model> {
    public typealias Value = Results<Element>
    
    public static subscript(
        _enclosingInstance instance: EnclosingType,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<EnclosingType, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<EnclosingType, Self>
    ) -> Value {
        get {
            guard let lattice = instance.lattice, let primaryKey = instance.primaryKey else {
                fatalError("Cannot use @Relation on an instance that is not yet inserted into the database")
            }
            let link = instance[keyPath: storageKeyPath].link
            
            return Results(lattice, whereStatement: {
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

extension Results: RandomAccessCollection {
}


