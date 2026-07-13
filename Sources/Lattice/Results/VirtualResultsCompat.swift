import Foundation
#if canImport(Combine)
import Combine
#endif
import LatticeSwiftCppBridge

// iOS 15 (pre-variadic-generics) equivalent of `_VirtualResults<each M, Element>`.
// The model types are carried as a runtime `[any Model.Type]` array instead of a
// parameter pack; every pack loop in the gated `_VirtualResults` becomes a plain
// `for type in modelTypes`, and `firstType` becomes `modelTypes.first`. The query
// bodies are otherwise identical (they already operate on each element as
// `any Model.Type` with dynamic dispatch).
//
// Queries route through the neutral `_lattice.backend` surface, which works on
// every OS (the C++ handles value-convert below the FRT floor).
public final class _VirtualResultsCompat<Element>: VirtualResults, ObservableObject, @unchecked Sendable {
    public typealias UnderlyingElement = Element
    public typealias Models = [any Model.Type]

    let modelTypes: [any Model.Type]
    private let _lattice: Lattice
    internal let whereStatement: Query<Bool>?
    internal let sortStatement: (any SortComparator)?
    internal let boundsConstraint: BoundsConstraint?
    internal let groupByColumn: String?
    internal let distinctByColumn: String?

    internal var _sortColumn: (name: String, order: SortOrder)? {
        if let ks = sortStatement as? KeyPathSort<Element> {
            return (ks.column, ks.order)
        }
        if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *),
           let sd = sortStatement as? SortDescriptor<Element>, let kp = sd.keyPath {
            return (nameForKeyPath(kp), sd.order)
        }
        return nil
    }

    #if canImport(Combine)
    public var objectWillChange: ResultsChangePublisher {
        ResultsChangePublisher { [weak self] callback in
            guard let self else { return AnyCancellable {} }
            return self.observe { change in callback(change) }
        }
    }
    #endif

    init(_ lattice: Lattice, modelTypes: [any Model.Type], whereStatement: Query<Bool>? = nil, sortStatement: (any SortComparator)? = nil, boundsConstraint: BoundsConstraint? = nil, groupByColumn: String? = nil, distinctByColumn: String? = nil) {
        self._lattice = lattice
        self.modelTypes = modelTypes
        self.whereStatement = whereStatement
        self.sortStatement = sortStatement
        self.boundsConstraint = boundsConstraint
        self.groupByColumn = groupByColumn
        self.distinctByColumn = distinctByColumn
    }

    convenience init(modelTypes: [any Model.Type], proto: Element.Type, lattice: Lattice) {
        self.init(lattice, modelTypes: modelTypes)
    }

    // NOTE: matches the pack version's contract — `_addType` RESETS query state.
    // It is only ever called from `_buildVirtualResults` on freshly-constructed
    // results, growing the type list before any refinement.
    public func _addType<Q: Model>(_ type: Q.Type) -> any VirtualResults<Element> {
        _VirtualResultsCompat<Element>(_lattice, modelTypes: modelTypes + [type])
    }

    private var firstType: any Model.Type {
        guard let t = modelTypes.first else { preconditionFailure("virtual results with no model types") }
        return t
    }

    /// Tolerant-ladder rung (d) witness (item A §1.2): an unmanaged,
    /// default-valued instance of the first conforming concrete type.
    /// Nil-safe on an empty type list (no trap).
    public func _ladderPlaceholder() -> Element? {
        modelTypes.first?.init(isolation: nil) as? Element
    }

    private var tableNames: [String] {
        modelTypes.map { $0.entityName }
    }

    func nameForKeyPath(_ keyPath: PartialKeyPath<Element>) -> String {
        let inst = firstType.init(isolation: #isolation)
        guard let virtualInst = inst as? Element else {
            preconditionFailure()
        }
        _ = virtualInst[keyPath: keyPath]
        return inst._lastKeyPathUsed ?? "id"
    }

    public func snapshot(limit: Int64? = nil, offset: Int64? = nil) -> [Element] {
        var objects: [Element] = []

        let orderBy: String? = _sortColumn.map { "\($0.name) \($0.order == .forward ? "ASC" : "DESC")" }
        let cxxResults = _lattice.backend.unionObjects(tables: self.tableNames, where: whereStatement?.predicate, orderBy: orderBy, limit: limit, offset: offset)

        for row in cxxResults {
            for type in modelTypes {
                if type.entityName == row.tableName {
                    objects.append(type.init(dynamicObject: row) as! Element)
                    break
                }
            }
        }

        return objects
    }

    public func `where`(_ query: (_VirtualQueryCompat<Element>) -> Query<Bool>) -> _VirtualResultsCompat<Element> {
        _VirtualResultsCompat(_lattice,
                              modelTypes: modelTypes,
                              whereStatement: query(_VirtualQueryCompat<Element>(modelTypes: modelTypes)),
                              sortStatement: sortStatement,
                              boundsConstraint: boundsConstraint,
                              groupByColumn: groupByColumn,
                              distinctByColumn: distinctByColumn)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    public func sortedBy(_ sortDescriptor: SortDescriptor<Element>) -> _VirtualResultsCompat<Element> {
        _VirtualResultsCompat(_lattice, modelTypes: modelTypes, whereStatement: whereStatement, sortStatement: sortDescriptor, boundsConstraint: boundsConstraint, groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
    }

    public func sortedBy<V>(_ keyPath: KeyPath<Element, V>, order: SortOrder = .forward) -> _VirtualResultsCompat<Element> {
        _VirtualResultsCompat(_lattice, modelTypes: modelTypes, whereStatement: whereStatement, sortStatement: KeyPathSort<Element>(column: nameForKeyPath(keyPath), order: order), boundsConstraint: boundsConstraint, groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
    }

    public func group<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> _VirtualResultsCompat<Element> {
        _VirtualResultsCompat(_lattice, modelTypes: modelTypes, whereStatement: whereStatement, sortStatement: sortStatement, boundsConstraint: boundsConstraint, groupByColumn: nameForKeyPath(keyPath), distinctByColumn: distinctByColumn)
    }

    public func distinct<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> _VirtualResultsCompat<Element> {
        _VirtualResultsCompat(_lattice, modelTypes: modelTypes, whereStatement: whereStatement, sortStatement: sortStatement, boundsConstraint: boundsConstraint, groupByColumn: groupByColumn, distinctByColumn: nameForKeyPath(keyPath))
    }

    public func observe(_ observer: @escaping (CollectionChange) -> Void) -> AnyCancellable {
        var cancellables: [AnyCancellable] = []
        for t in modelTypes {
            cancellables.append(_lattice.observe(t, where: self.whereStatement) { change in
                observer(change)
            })
        }
        return AnyCancellable {
            cancellables.forEach { $0.cancel() }
        }
    }

    public var startIndex: Int { 0 }
    public var count: Int { endIndex }

    public var endIndex: Int {
        var count = 0
        for type in modelTypes {
            count += Int(_lattice.backend.count(table: type.entityName, where: whereStatement?.predicate))
        }
        return count
    }

    public func index(after i: Int) -> Int {
        i + 1
    }

    public func withinBounds<G: GeoboundsProperty>(
        _ keyPath: KeyPath<Element, G>,
        minLat: Double, maxLat: Double,
        minLon: Double, maxLon: Double
    ) -> _VirtualResultsCompat<Element> {
        let propertyName = nameForKeyPath(keyPath)
        let constraint = BoundsConstraint(
            propertyName: propertyName,
            minLat: minLat, maxLat: maxLat,
            minLon: minLon, maxLon: maxLon
        )
        return _VirtualResultsCompat(_lattice, modelTypes: modelTypes, whereStatement: whereStatement, sortStatement: sortStatement, boundsConstraint: constraint, groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
    }

    // MARK: - Virtual proximity / FTS

    private func _nearestSort() -> RawNearestSortDescriptor? {
        _sortColumn.map { RawNearestSortDescriptor(descriptor: .keyPath($0.name), order: $0.order) }
    }

    public func nearest<V: VectorElement>(
        to queryVector: Vector<V>,
        on keyPath: KeyPath<Element, Vector<V>>,
        limit k: Int = 10,
        distance metric: DistanceMetric = .l2
    ) -> any NearestResults<Element> {
        let propertyName = nameForKeyPath(keyPath)
        let constraint = VectorConstraint(keyPath: propertyName, queryVector: queryVector, k: k, metric: metric)
        return _VirtualNearestResultsCompat<Element>(
            lattice: _lattice, modelTypes: modelTypes, whereStatement: whereStatement,
            sortStatement: _nearestSort(), boundsConstraint: boundsConstraint,
            proximity: .vector(constraint), groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
    }

    public func nearest<G: GeoboundsProperty>(
        to location: (latitude: Double, longitude: Double),
        on keyPath: KeyPath<Element, G>,
        maxDistance: Double,
        unit: DistanceUnit,
        limit: Int,
        sortedByDistance: Bool
    ) -> any NearestResults<Element> {
        let propertyName = nameForKeyPath(keyPath)
        let constraint = GeoNearestConstraint(
            keyPath: propertyName,
            center: (lat: location.latitude, lon: location.longitude),
            maxDistance: maxDistance, unit: unit, limit: limit, sortByDistance: sortedByDistance)
        return _VirtualNearestResultsCompat<Element>(
            lattice: _lattice, modelTypes: modelTypes, whereStatement: whereStatement,
            sortStatement: _nearestSort(), boundsConstraint: boundsConstraint,
            proximity: .geo(constraint), groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
    }

    public func matching(
        _ searchText: String,
        on keyPath: KeyPath<Element, String>,
        limit: Int = 100
    ) -> any NearestResults<Element> {
        matching(.raw(searchText), on: keyPath, limit: limit)
    }

    public func matching(
        _ query: TextQuery,
        on keyPath: KeyPath<Element, String>,
        limit: Int = 100
    ) -> any NearestResults<Element> {
        let propertyName = nameForKeyPath(keyPath)
        let constraint = TextConstraint(propertyName: propertyName, query: query, limit: limit)
        return _VirtualNearestResultsCompat<Element>(
            lattice: _lattice, modelTypes: modelTypes, whereStatement: whereStatement,
            sortStatement: _nearestSort(), boundsConstraint: boundsConstraint,
            proximity: .text(constraint), groupByColumn: groupByColumn, distinctByColumn: distinctByColumn)
    }
}
// NOTE: `sendableReference` + its thread-safe reference live in
// ThreadSafeReference.swift, where the `ResultsThreadSafeReference` initializer
// (fileprivate) is accessible.
