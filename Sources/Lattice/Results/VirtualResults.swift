import Foundation
import LatticeSwiftCppBridge

extension Lattice {
    public func objects<V>(_ virtualModel: V.Type) -> any VirtualResults<V> {
        self.schema!._generateVirtualResults(virtualModel, on: self)
    }
}

public protocol VirtualResults<Element> : Results where UnderlyingElement == Element {
    associatedtype Models
    func _addType<M: Model>(_ type: M.Type) -> any VirtualResults<Element>
}

public struct _VirtualResults<each M: Model, Element>: VirtualResults {
    public typealias UnderlyingElement = Element
    public typealias Models = (repeat each M)

    private var _lattice: Lattice
    internal let whereStatement: Query<Bool>?
    internal let sortStatement: SortDescriptor<Element>?
    internal let boundsConstraint: BoundsConstraint?
    internal let groupByColumn: String?

    public func _addType<Q: Model>(_ type: Q.Type) -> any VirtualResults<Element> {
        _VirtualResults<repeat each M, Q, Element>.init(self._lattice)
    }

    package func merge<each V: Model>(other virtualResults: _VirtualResults<repeat each V, Element>) -> _VirtualResults<repeat each M, repeat each V, Element> {
        return .init(self._lattice)
    }

    package init(types: repeat (each M).Type, proto: Element.Type, lattice: Lattice) {
        self._lattice = lattice
        whereStatement = nil
        sortStatement = nil
        boundsConstraint = nil
        groupByColumn = nil
    }
    private var firstType: any Model.Type {
        for t in repeat (each M).self {
            return t
        }
        fatalError()
    }
    
    private var tableNames: [String] {
        var tableNames: [String] = []
        for type in repeat (each M).self {
            tableNames.append(type.entityName)
        }
        return tableNames
    }
    
    // Helper to build query parameters - always fetches fresh from DB (live results)
    public func snapshot(limit: Int64? = nil, offset: Int64? = nil) -> [Element] {
        var objects: [Element] = []
        
        let whereClause: lattice.OptionalString = if let whereStatement {
            lattice.string_to_optional(std.string(whereStatement.predicate))
        } else {
            .init()
        }
        let orderBy: lattice.OptionalString = if let sortStatement, let keyPath = sortStatement.keyPath {
            {
                let inst = firstType.init(isolation: #isolation)
                guard let virtualInst = inst as? Element else {
                    preconditionFailure()
                }
                _ = virtualInst[keyPath: keyPath]
                let keyPath = inst._lastKeyPathUsed ?? "id"
                return lattice.string_to_optional(std.string("\(keyPath) \(sortStatement.order == .forward ? "ASC" : "DESC")"))
            }()
        } else {
            .init()
        }
        let limitOpt: lattice.OptionalInt64 = if let limit { lattice.int64_to_optional(limit) } else { .init() }
        let offsetOpt: lattice.OptionalInt64 = if let offset { lattice.int64_to_optional(offset) } else { .init() }
        
        let cxxResults = _lattice.cxxLattice.union_objects(self.tableNames.reduce(into: lattice.StringVector(), { $0.push_back(std.string($1)) }), whereClause, orderBy, limitOpt, offsetOpt)
        
        for i in 0..<cxxResults.size() {
            let cxxObject = cxxResults[i]
            for type in repeat (each M).self {
                if type.entityName == String(cxxObject.instance_schema().table_name) {
                    let object = type.init(dynamicObject: CxxDynamicObjectRef.wrap(CxxDynamicObject(cxxObject).make_shared()))
                    objects.append(object as! Element)
                    break
                }
            }
        }

        return objects
    }
    
    init(_ lattice: Lattice, whereStatement: Query<Bool>? = nil, sortStatement: SortDescriptor<Element>? = nil, boundsConstraint: BoundsConstraint? = nil, groupByColumn: String? = nil) {
        self._lattice = lattice
        self.whereStatement = whereStatement
        self.sortStatement = sortStatement
        self.boundsConstraint = boundsConstraint
        self.groupByColumn = groupByColumn
    }

    init(_ lattice: Lattice, whereStatement: Predicate<Element>, sortStatement: SortDescriptor<Element>? = nil) {
        self._lattice = lattice
        self.whereStatement = whereStatement(Query())
        self.sortStatement = sortStatement
        self.boundsConstraint = nil
        self.groupByColumn = nil
    }
    
    private func constructVirtualQuery<T>(_ t: T.Type) -> some _Query<Element> where T: Model {
        _VirtualQuery<T, Element>()
    }
    
    public func `where`(_ query: (_VirtualQuery<repeat each M, Element>) -> Query<Bool>) -> Self {
        let types = (repeat (each M).self)
        for t in repeat each types {
            return Self(_lattice,
                        whereStatement: query(_VirtualQuery<repeat each M, Element>()),
                        sortStatement: sortStatement,
                        boundsConstraint: boundsConstraint,
                        groupByColumn: groupByColumn)
        }
        fatalError()
    }

    public func sortedBy(_ sortDescriptor: SortDescriptor<Element>) -> Self {
        return Self(_lattice, whereStatement: whereStatement, sortStatement: sortDescriptor, boundsConstraint: boundsConstraint, groupByColumn: groupByColumn)
    }

    public func group<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> Self {
        let inst = firstType.init(isolation: #isolation)
        guard let virtualInst = inst as? Element else {
            preconditionFailure()
        }
        _ = virtualInst[keyPath: keyPath]
        let columnName = inst._lastKeyPathUsed ?? "id"
        return Self(_lattice, whereStatement: whereStatement, sortStatement: sortStatement, boundsConstraint: boundsConstraint, groupByColumn: columnName)
    }
    
    public func observe(_ observer: @escaping (CollectionChange) -> Void) -> AnyCancellable {
        var cancellables: [AnyCancellable] = []
        for t in repeat (each M).self {
            cancellables.append(_lattice.observe(t.self, where: self.whereStatement) { change in
                observer(change)
            })
        }
        return AnyCancellable {
            cancellables.forEach { $0.cancel() }
        }
    }
    
    public var startIndex: Int { 0 }
    
    public var endIndex: Int {
        // Live count from C++
        var count = 0
        for type in repeat (each M).self {
            let tableName = std.string(type.entityName)
            let whereClause: lattice.OptionalString = if let whereStatement {
                lattice.string_to_optional(std.string(whereStatement.predicate))
            } else {
                .init()
            }
            count += Int(_lattice.cxxLattice.count(tableName, whereClause))
        }
        return count
    }

    public func index(after i: Int) -> Int {
        i + 1
    }
    
    // MARK: - Vector Search

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
    ) -> any NearestResults<Element> {
        let inst = firstType.init(isolation: #isolation)
        guard let virtualInst = inst as? Element else {
            preconditionFailure()
        }
        _ = virtualInst[keyPath: keyPath]
        let propertyName = inst._lastKeyPathUsed ?? "id"

        let constraint = VectorConstraint(keyPath: propertyName, queryVector: queryVector, k: k, metric: metric)

        return _VirtualNearestResults<repeat each M, Element>(
            lattice: _lattice,
            whereStatement: whereStatement,
            sortStatement: sortStatement.map {
                RawNearestSortDescriptor(descriptor: .keyPath(nameForKeyPath($0.keyPath!)),
                                         order: $0.order)
            },
            boundsConstraint: boundsConstraint,
            proximity: .vector(constraint),
            groupByColumn: groupByColumn
        )
    }

    func nameForKeyPath(_ keyPath: PartialKeyPath<Element>) -> String {
        let inst = firstType.init(isolation: #isolation)
        guard let virtualInst = inst as? Element else {
            preconditionFailure()
        }
        _ = virtualInst[keyPath: keyPath]
        return inst._lastKeyPathUsed ?? "id"
    }
    
    // MARK: - Spatial Query (geo_bounds)

    /// Filter results to objects within a geographic bounding box.
    /// Queries each type's R*Tree and merges results.
    public func withinBounds<G: GeoboundsProperty>(
        _ keyPath: KeyPath<Element, G>,
        minLat: Double, maxLat: Double,
        minLon: Double, maxLon: Double
    ) -> Self {
        let inst = firstType.init(isolation: #isolation)
        guard let virtualInst = inst as? Element else {
            preconditionFailure()
        }
        _ = virtualInst[keyPath: keyPath]
        let propertyName = inst._lastKeyPathUsed ?? "id"

        let constraint = BoundsConstraint(
            propertyName: propertyName,
            minLat: minLat, maxLat: maxLat,
            minLon: minLon, maxLon: maxLon
        )
        return Self(_lattice, whereStatement: whereStatement, sortStatement: sortStatement, boundsConstraint: constraint, groupByColumn: groupByColumn)
    }

    /// Find objects nearest to a geographic point.
    /// Queries each type's R*Tree and merges results.
    public func nearest<G: GeoboundsProperty>(
        to location: (latitude: Double, longitude: Double),
        on keyPath: KeyPath<Element, G>,
        maxDistance: Double,
        unit: DistanceUnit,
        limit: Int,
        sortedByDistance: Bool
    ) -> any NearestResults<Element> {
        let inst = firstType.init(isolation: #isolation)
        guard let virtualInst = inst as? Element else {
            preconditionFailure()
        }
        _ = virtualInst[keyPath: keyPath]
        let propertyName = inst._lastKeyPathUsed ?? "id"

        let constraint = GeoNearestConstraint(
            keyPath: propertyName,
            center: (lat: location.latitude, lon: location.longitude),
            maxDistance: maxDistance,
            unit: unit,
            limit: limit,
            sortByDistance: sortedByDistance
        )

        return _VirtualNearestResults<repeat each M, Element>(
            lattice: _lattice,
            whereStatement: whereStatement,
            sortStatement: sortStatement.map {
                RawNearestSortDescriptor(descriptor: .keyPath(nameForKeyPath($0.keyPath!)),
                                         order: $0.order)
            },
            boundsConstraint: boundsConstraint,
            proximity: .geo(constraint),
            groupByColumn: groupByColumn
        )
    }
}
