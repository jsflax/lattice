import Foundation

// MARK: - Dynamic FTS / vector / geo search
//
// A combined-nearest query (full-text, vector ANN, geo proximity, bounding box)
// over a dynamically-opened lattice, returning type-erased `DynamicObject`s with
// their per-column distances. Backs the MCP lattice_search / lattice_nearest /
// lattice_geo tools. Lives in the Lattice module so it can reach `backend`.
extension Lattice {
    public func dynamicNearest(
        table: String,
        bounds: [BoundsConstraintParam] = [],
        vectors: [VectorConstraintParam] = [],
        geos: [GeoConstraintParam] = [],
        texts: [TextConstraintParam] = [],
        where whereClause: String? = nil,
        sort: SortDescriptorParam,
        limit: Int
    ) -> [(object: DynamicObject, distances: [DistanceEntry])] {
        let schema = (backend as? any DynamicSchemaProviding)?.dynamicProperties(table: table)
        let rows = backend.combinedNearestQuery(
            table: table, bounds: bounds, vectors: vectors, geos: geos, texts: texts,
            where: whereClause, sort: sort, limit: Int64(limit), groupBy: nil, distinctBy: nil)
        return rows.map { (DynamicObject(backend: $0.object, schema: schema), $0.distances) }
    }
}
