import Foundation
import LatticeSwiftCppBridge

extension Lattice {
    public func objects<V>(_ virtualModel: V.Type) -> any Results<V> {
        self.schema!._generateVirtualResults(virtualModel, on: self)
        
    }
}

public protocol VirtualResults<Element> : Results {
    associatedtype Models
    func addType<M: Model>(_ type: M.Type) -> any VirtualResults<Element>
}

public struct _VirtualResults<each M: Model, Element>: VirtualResults {
    public typealias Models = (repeat each M)
    
    private var _lattice: Lattice
    internal let whereStatement: Query<Bool>?
    internal let sortStatement: SortDescriptor<Element>?
    
    public func addType<Q: Model>(_ type: Q.Type) -> any VirtualResults<Element> {
        _VirtualResults<repeat each M, Q, Element>.init(self._lattice)
    }
    
    package func merge<each V: Model>(other virtualResults: _VirtualResults<repeat each V, Element>) -> _VirtualResults<repeat each M, repeat each V, Element> {
        return .init(self._lattice)
    }
    
    package init(types: repeat (each M).Type, proto: Element.Type, lattice: Lattice) {
        self._lattice = lattice
        whereStatement = nil
        sortStatement = nil
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
    
    private func constructVirtualQuery<T>(_ t: T.Type) -> some _Query<Element> where T: Model {
        _VirtualQuery<T, Element>()
    }
    
    public func `where`(_ query: (_VirtualQuery<repeat each M, Element>) -> Query<Bool>) -> Self {
        
        let types = (repeat (each M).self)
        for t in repeat each types {
            return Self(_lattice,
                        whereStatement: query(_VirtualQuery<repeat each M, Element>()),
                        sortStatement: sortStatement)
        }
        fatalError()
    }
    
    public func sortedBy(_ sortDescriptor: SortDescriptor<Element>) -> Self {
        return Self(_lattice, whereStatement: whereStatement, sortStatement: sortDescriptor)
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
    ) -> [NearestMatch<Element>] {
        let inst = firstType.init(isolation: #isolation)
        guard let virtualInst = inst as? Element else {
            preconditionFailure()
        }
        _ = virtualInst[keyPath: keyPath]
        let propertyName = inst._lastKeyPathUsed ?? "id"
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

        var results: [NearestMatch<Element>] = []
        
        for type in repeat (each M).self {
            let cxxResults = _lattice.cxxLattice.nearest_neighbors(
                std.string(type.entityName),
                std.string(propertyName),
                byteVec,
                Int32(k),
                metric.rawValue,
                whereClause
            )

            for i in 0..<cxxResults.size() {
                let pair = cxxResults[i]
                var managedObj = pair.first
                let distance = pair.second

                var swiftObj = type.init(dynamicObject: CxxDynamicObjectRef.wrap(CxxDynamicObject(managedObj).make_shared()))
                results.append(NearestMatch(object: swiftObj as! Element, distance: distance))
            }

        }
        
//        results.reserveCapacity(cxxResults.size())

        return results
    }

    // MARK: - Spatial Query (geo_bounds)

    /// Filter results to objects within a geographic bounding box.
    /// Note: VirtualResults doesn't support spatial queries across multiple types.
    /// This is a placeholder implementation that returns an empty array.
    public func withinBounds<G: GeoboundsProperty>(
        _ keyPath: KeyPath<Element, G>,
        minLat: Double, maxLat: Double,
        minLon: Double, maxLon: Double
    ) -> [Element] {
        // VirtualResults spans multiple types; geo_bounds query would need
        // to query each type's R*Tree separately. For now, return empty.
        // Users should use TableResults for spatial queries.
        return []
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
    ) -> [NearestMatch<Element>] {
        let inst = firstType.init(isolation: #isolation)
        guard let virtualInst = inst as? Element else {
            preconditionFailure()
        }
        _ = virtualInst[keyPath: keyPath]
        let propertyName = inst._lastKeyPathUsed ?? "id"
        let radiusMeters = maxDistance * unit.toMeters

        let whereClause: lattice.OptionalString = if let whereStatement {
            lattice.string_to_optional(std.string(whereStatement.predicate))
        } else {
            .init()
        }

        var results: [NearestMatch<Element>] = []

        for type in repeat (each M).self {
            let cxxResults = _lattice.cxxLattice.geoNearest(
                table: std.string(type.entityName),
                geoColumn: std.string(propertyName),
                lat: location.latitude,
                lon: location.longitude,
                radius: radiusMeters,
                limit: Int32(limit),
                sortByDistance: sortedByDistance,
                where: whereClause
            )

            for i in 0..<cxxResults.size() {
                let pair = cxxResults[i]
                var managedObj = pair.first
                let distanceMeters = pair.second

                let swiftObj = type.init(dynamicObject: CxxDynamicObjectRef.wrap(CxxDynamicObject(managedObj).make_shared()))
                let distanceInUnit = unit.fromMeters(distanceMeters)
                results.append(NearestMatch(object: swiftObj as! Element, distance: distanceInUnit))
            }
        }

        // Sort merged results by distance if requested
        if sortedByDistance {
            results.sort { $0.distance < $1.distance }
        }

        // Apply limit after merging
        if results.count > limit {
            results = Array(results.prefix(limit))
        }

        return results
    }
}
