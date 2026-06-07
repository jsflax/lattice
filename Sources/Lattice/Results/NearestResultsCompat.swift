import Foundation
#if canImport(Combine)
import Combine
#endif
import LatticeSwiftCppBridge

// iOS 15 (pre-variadic-generics) equivalent of `_VirtualNearestResults<each M, T>`.
// The model types are carried as a runtime array; the two `for type in
// repeat (each M).self` loops (count + execution) become `for type in modelTypes`.
// Everything else — the C++ constraint-vector building — is byte-for-byte the
// gated pack type's logic. Bodies still call `cxxLattice` (iOS 16.4); Phase 2
// boxes that behind the backend protocol, at which point this compiles at iOS 15.
package struct _VirtualNearestResultsCompat<T>: NearestResults {
    public typealias Element = _NearestMatch<T>
    public typealias QueryType = Query<_NearestMatch<T>>
    public typealias NearestMatchType = _NearestMatch<T>
    public typealias UnderlyingElement = T

    private let _lattice: Lattice
    let modelTypes: [any Model.Type]
    internal let whereStatement: Query<Bool>?
    internal let sortStatement: RawNearestSortDescriptor?
    internal let boundsConstraint: BoundsConstraint?
    internal let proximity: ProximityType
    internal let groupByColumn: String?
    internal let distinctByColumn: String?

    init(lattice: Lattice,
         modelTypes: [any Model.Type],
         whereStatement: Query<Bool>? = nil,
         sortStatement: RawNearestSortDescriptor? = nil,
         boundsConstraint: BoundsConstraint? = nil,
         proximity: ProximityType,
         groupByColumn: String? = nil,
         distinctByColumn: String? = nil) {
        self._lattice = lattice
        self.modelTypes = modelTypes
        self.whereStatement = whereStatement
        self.sortStatement = sortStatement
        self.boundsConstraint = boundsConstraint
        self.proximity = proximity
        self.groupByColumn = groupByColumn
        self.distinctByColumn = distinctByColumn
    }

    private var firstType: any Model.Type {
        guard let t = modelTypes.first else { preconditionFailure("virtual nearest with no model types") }
        return t
    }

    // MARK: - Chainable Methods

    public func `where`(_ predicate: (Query<Element>) -> Query<Bool>) -> Self {
        let newWhere = predicate(Query())
        let combined: Query<Bool>? = if let existing = whereStatement {
            existing && newWhere
        } else {
            newWhere
        }
        return Self(lattice: _lattice, modelTypes: modelTypes, whereStatement: combined, sortStatement: sortStatement, boundsConstraint: boundsConstraint, proximity: proximity, groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
    }

    public func group<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> Self {
        let object = firstType.init(isolation: #isolation)
        let match = _NearestMatch(object: object as! T, distance: 0)
        _ = match[keyPath: keyPath]
        guard let columnName = object._lastKeyPathUsed else {
            preconditionFailure("Could not resolve keyPath to column name")
        }
        return Self(lattice: _lattice, modelTypes: modelTypes, whereStatement: whereStatement, sortStatement: sortStatement, boundsConstraint: boundsConstraint, proximity: proximity, groupByColumn: columnName, distinctByColumn: distinctByColumn)
    }

    public func distinct<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> Self {
        let object = firstType.init(isolation: #isolation)
        let match = _NearestMatch(object: object as! T, distance: 0)
        _ = match[keyPath: keyPath]
        guard let columnName = object._lastKeyPathUsed else {
            preconditionFailure("Could not resolve keyPath to column name")
        }
        return Self(lattice: _lattice, modelTypes: modelTypes, whereStatement: whereStatement, sortStatement: sortStatement, boundsConstraint: boundsConstraint, proximity: proximity, groupByColumn: groupByColumn, distinctByColumn: columnName)
    }

    // MARK: - Results Protocol Conformance

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    public func sortedBy(_ sortDescriptor: SortDescriptor<Element>) -> Self {
        _sorted(by: sortDescriptor.keyPath!, order: sortDescriptor.order)
    }

    public func sortedBy<V>(_ keyPath: KeyPath<Element, V>, order: SortOrder = .forward) -> Self {
        _sorted(by: keyPath, order: order)
    }

    private func _sorted(by keyPath: PartialKeyPath<Element>, order: SortOrder) -> Self {
        let object = firstType.init(isolation: #isolation) as! T
        let match = _NearestMatch(object: object as! T, distance: 0)
        _ = match[keyPath: keyPath]
        guard let column = (object as! any Model)._lastKeyPathUsed else {
            preconditionFailure()
        }
        return Self(lattice: _lattice, modelTypes: modelTypes, whereStatement: whereStatement, sortStatement: .init(descriptor: .keyPath(column), order: order), boundsConstraint: boundsConstraint, proximity: proximity, groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
    }

    public func sortedBy(_ sortDescriptor: NearestSortDescriptor<Element>) -> Self {
        switch sortDescriptor {
        case .geoDistance(let sortOrder):
            return Self(lattice: _lattice, modelTypes: modelTypes, whereStatement: whereStatement, sortStatement: .init(descriptor: .geoDistance, order: sortOrder), boundsConstraint: boundsConstraint, proximity: proximity, groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
        case .vectorDistance(let sortOrder):
            return Self(lattice: _lattice, modelTypes: modelTypes, whereStatement: whereStatement, sortStatement: .init(descriptor: .vectorDistance, order: sortOrder), boundsConstraint: boundsConstraint, proximity: proximity, groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
        case .textRank(let sortOrder):
            return Self(lattice: _lattice, modelTypes: modelTypes, whereStatement: whereStatement, sortStatement: .init(descriptor: .textRank, order: sortOrder), boundsConstraint: boundsConstraint, proximity: proximity, groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
        }
    }

    public func observe(_ observer: @escaping (CollectionChange) -> Void) -> AnyCancellable {
        var cancellables: [AnyCancellable] = []
        for type in modelTypes {
            cancellables.append(_lattice.observe(type, where: self.whereStatement) { change in
                observer(change)
            })
        }
        return AnyCancellable {
            cancellables.forEach { $0.cancel() }
        }
    }

    public var startIndex: Int { 0 }
    public var count: Int { endIndex }

    private func flattenProximity(_ p: ProximityType) -> (vectors: [VectorConstraint], geos: [GeoNearestConstraint], texts: [TextConstraint]) {
        switch p {
        case .vector(let v): return ([v], [], [])
        case .geo(let g): return ([], [g], [])
        case .text(let t): return ([], [], [t])
        case .conjunction(let left, let right):
            let (lv, lg, lt) = flattenProximity(left)
            let (rv, rg, rt) = flattenProximity(right)
            return (lv + rv, lg + rg, lt + rt)
        }
    }

    /// Builds the C++ constraint vectors shared by `endIndex` and `snapshot`.
    private func buildConstraints() -> (bounds: lattice.BoundsConstraintVector, vectors: lattice.VectorConstraintVector, geos: lattice.GeoConstraintVector, texts: lattice.TextConstraintVector, whereClause: lattice.OptionalString, sort: lattice.sort_descriptor, flatVectors: [VectorConstraint], flatGeos: [GeoNearestConstraint], flatTexts: [TextConstraint]) {
        let (vectors, geos, texts) = flattenProximity(proximity)

        var cxxBounds = lattice.BoundsConstraintVector()
        if let bounds = boundsConstraint {
            var bc = lattice.bounds_constraint()
            bc.column = std.string(bounds.propertyName)
            bc.min_lat = bounds.minLat
            bc.max_lat = bounds.maxLat
            bc.min_lon = bounds.minLon
            bc.max_lon = bounds.maxLon
            cxxBounds.push_back(bc)
        }

        var cxxVectors = lattice.VectorConstraintVector()
        for vc in vectors {
            var cxxVc = lattice.vector_constraint()
            cxxVc.column = std.string(vc.propertyName)
            var byteVec = lattice.ByteVector()
            for byte in vc.queryVector { byteVec.push_back(byte) }
            cxxVc.query_vector = byteVec
            cxxVc.k = Int32(vc.k)
            cxxVc.metric = vc.metric.rawValue
            cxxVectors.push_back(cxxVc)
        }

        var cxxGeos = lattice.GeoConstraintVector()
        for gc in geos {
            var cxxGc = lattice.geo_constraint()
            cxxGc.column = std.string(gc.propertyName)
            cxxGc.center_lat = gc.centerLat
            cxxGc.center_lon = gc.centerLon
            cxxGc.radius_meters = gc.radiusMeters
            cxxGeos.push_back(cxxGc)
        }

        var cxxTexts = lattice.TextConstraintVector()
        for tc in texts {
            var cxxTc = lattice.text_constraint()
            cxxTc.column = std.string(tc.propertyName)
            cxxTc.search_text = std.string(tc.searchText)
            cxxTc.limit = Int32(tc.limit)
            cxxTexts.push_back(cxxTc)
        }

        let whereClause: lattice.OptionalString = if let whereStatement {
            lattice.string_to_optional(std.string(whereStatement.predicate))
        } else { .init() }

        var cxxSort = lattice.sort_descriptor()
        if let sort = sortStatement {
            switch sort.descriptor {
            case .keyPath(let propName):
                cxxSort.type = .property
                cxxSort.column = std.string(propName)
            case .geoDistance:
                cxxSort.type = .geo_distance
                cxxSort.column = std.string(geos.first?.propertyName ?? "")
            case .vectorDistance:
                cxxSort.type = .vector_distance
                cxxSort.column = std.string(vectors.first?.propertyName ?? "")
            case .textRank:
                cxxSort.type = .text_rank
                cxxSort.column = std.string(texts.first?.propertyName ?? "")
            }
            cxxSort.ascending = (sort.order == .forward)
        }

        return (cxxBounds, cxxVectors, cxxGeos, cxxTexts, whereClause, cxxSort, vectors, geos, texts)
    }

    public var endIndex: Int {
        let c = buildConstraints()
        let vectorLimit = c.flatVectors.map(\.k).min() ?? Int.max
        let geoLimit = c.flatGeos.map(\.limit).min() ?? Int.max
        let textLimit = c.flatTexts.map(\.limit).min() ?? Int.max
        let maxLimit = Swift.min(vectorLimit, Swift.min(geoLimit, textLimit))

        let groupByOpt: lattice.OptionalString = if let groupByColumn {
            lattice.string_to_optional(std.string(groupByColumn))
        } else { .init() }
        let distinctByOpt: lattice.OptionalString = if let distinctByColumn {
            lattice.string_to_optional(std.string(distinctByColumn))
        } else { .init() }

        var total = 0
        for type in modelTypes {
            total += Int(_lattice.cxxLattice.combinedNearestQueryCount(
                table: std.string(type.entityName), bounds: c.bounds,
                vectors: c.vectors, geos: c.geos, texts: c.texts,
                where: c.whereClause, sort: c.sort, limit: Int64(maxLimit),
                groupBy: groupByOpt, distinctBy: distinctByOpt))
        }
        return Swift.min(total, maxLimit)
    }

    public func index(after i: Int) -> Int {
        i + 1
    }

    public func snapshot(limit: Int64? = nil, offset: Int64? = nil) -> [_NearestMatch<T>] {
        let c = buildConstraints()

        let vectorLimit = c.flatVectors.map(\.k).min() ?? Int.max
        let geoLimit = c.flatGeos.map(\.limit).min() ?? Int.max
        let textLimit = c.flatTexts.map(\.limit).min() ?? Int.max
        let constraintLimit = Swift.min(vectorLimit, Swift.min(geoLimit, textLimit))

        let effectiveOffset = offset.map { Int($0) } ?? 0
        let effectiveLimit = limit.map { Int($0) } ?? constraintLimit
        let fetchLimit = Int64(Swift.min(effectiveOffset + effectiveLimit, constraintLimit))

        let geoUnits: [String: DistanceUnit] = Dictionary(
            c.flatGeos.map { ($0.propertyName, $0.unit) },
            uniquingKeysWith: { first, _ in first }
        )

        let groupByOpt: lattice.OptionalString = if let groupByColumn {
            lattice.string_to_optional(std.string(groupByColumn))
        } else { .init() }
        let distinctByOpt: lattice.OptionalString = if let distinctByColumn {
            lattice.string_to_optional(std.string(distinctByColumn))
        } else { .init() }

        var allResults: [_NearestMatch<T>] = []

        for type in modelTypes {
            let tableName = std.string(type.entityName)
            let cxxResults = _lattice.cxxLattice.combinedNearestQuery(
                table: tableName, bounds: c.bounds, vectors: c.vectors,
                geos: c.geos, texts: c.texts, where: c.whereClause,
                sort: c.sort, limit: fetchLimit, groupBy: groupByOpt, distinctBy: distinctByOpt)

            for i in 0..<Int(cxxResults.size()) {
                let result = cxxResults[i]
                let managedObj = result.object
                var distances: [String: Double] = [:]
                for j in 0..<result.distances.size() {
                    let entry = result.distances[j]
                    let columnName = String(entry.column)
                    let distanceValue = entry.distance
                    if let unit = geoUnits[columnName] {
                        distances[columnName] = unit.fromMeters(distanceValue)
                    } else {
                        distances[columnName] = distanceValue
                    }
                }
                let swiftObj = type.init(dynamicObject: CxxDynamicObjectRef.wrap(CxxDynamicObject(managedObj).make_shared()))
                allResults.append(_NearestMatch(object: swiftObj as! T, distances: distances))
            }
        }

        allResults.sort { $0.distance < $1.distance }

        let startIdx = effectiveOffset
        let endIdx = Swift.min(allResults.count, effectiveOffset + effectiveLimit)
        guard startIdx < allResults.count else { return [] }
        return Array(allResults[startIdx..<endIdx])
    }

    // MARK: - Results Protocol: nearest/withinBounds chaining (hybrid search)

    public func withinBounds<G: GeoboundsProperty>(
        _ keyPath: KeyPath<_NearestMatch<T>, G>,
        minLat: Double, maxLat: Double,
        minLon: Double, maxLon: Double
    ) -> Self {
        let object = firstType.init(isolation: #isolation)
        let match = _NearestMatch(object: object as! T, distance: 0)
        _ = match[keyPath: keyPath]
        guard let keyPath = object._lastKeyPathUsed else {
            preconditionFailure()
        }
        let constraint = BoundsConstraint(keyPath: keyPath, minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon)
        return Self(lattice: _lattice, modelTypes: modelTypes, whereStatement: whereStatement, sortStatement: sortStatement, boundsConstraint: constraint, proximity: self.proximity, groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
    }

    public func nearest<V: VectorElement>(
        to queryVector: Vector<V>,
        on keyPath: KeyPath<UnderlyingElement, Vector<V>>,
        limit k: Int,
        distance metric: DistanceMetric
    ) -> any NearestResults<UnderlyingElement> {
        let object = firstType.init(isolation: #isolation) as! T
        _ = object[keyPath: keyPath]
        guard let keyPath = (object as! any Model)._lastKeyPathUsed else {
            preconditionFailure()
        }
        let constraint = VectorConstraint(keyPath: keyPath, queryVector: queryVector, k: k, metric: metric)
        return Self(lattice: _lattice, modelTypes: modelTypes, whereStatement: whereStatement, sortStatement: sortStatement, boundsConstraint: self.boundsConstraint,
                    proximity: .conjunction(self.proximity, .vector(constraint)), groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
    }

    public func nearest<G: GeoboundsProperty>(
        to location: (latitude: Double, longitude: Double),
        on keyPath: KeyPath<UnderlyingElement, G>,
        maxDistance: Double,
        unit: DistanceUnit,
        limit: Int,
        sortedByDistance: Bool
    ) -> any NearestResults<T> {
        let object = firstType.init(isolation: #isolation) as! T
        _ = object[keyPath: keyPath]
        guard let keyPath = (object as! any Model)._lastKeyPathUsed else {
            preconditionFailure()
        }
        let constraint = GeoNearestConstraint(
            keyPath: keyPath,
            center: (lat: location.latitude, lon: location.longitude),
            maxDistance: maxDistance,
            unit: unit,
            limit: limit,
            sortByDistance: sortedByDistance
        )
        return Self(lattice: _lattice, modelTypes: modelTypes, whereStatement: whereStatement, sortStatement: sortStatement, boundsConstraint: boundsConstraint,
                    proximity: .conjunction(proximity, .geo(constraint)), groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
    }

    public func matching(
        _ searchText: String,
        on keyPath: KeyPath<UnderlyingElement, String>,
        limit: Int = 100
    ) -> any NearestResults<T> {
        matching(.raw(searchText), on: keyPath, limit: limit)
    }

    public func matching(
        _ query: TextQuery,
        on keyPath: KeyPath<UnderlyingElement, String>,
        limit: Int = 100
    ) -> any NearestResults<T> {
        let object = firstType.init(isolation: #isolation)
        guard let virtualObj = object as? T else {
            preconditionFailure()
        }
        _ = virtualObj[keyPath: keyPath]
        guard let propertyName = object._lastKeyPathUsed else {
            preconditionFailure()
        }
        let constraint = TextConstraint(propertyName: propertyName, query: query, limit: limit)
        return Self(lattice: _lattice, modelTypes: modelTypes, whereStatement: whereStatement, sortStatement: sortStatement, boundsConstraint: boundsConstraint,
                    proximity: .conjunction(self.proximity, .text(constraint)), groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
    }
}
