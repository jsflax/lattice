import Foundation
import LatticeSwiftCppBridge
import CxxStdlib

// MARK: - Dynamic (schema-from-file) open + query API
//
// Realm-style dynamic access: open any `.lattice` file with NO compile-time
// `@Model` types, introspect its schema, and query it as type-erased
// `DynamicObject`s. Backed by the SAME `CxxBackend`/`swift_lattice_ref` a normal
// open uses — `createDynamic` simply reconstructs the schema from the file
// (read-only) instead of taking it from Swift types.
extension Lattice {
    /// Open a database generically — no compile-time model types. The schema is
    /// reconstructed from the file and the database is opened read-only.
    ///
    /// Query with `dynamicObjects(_:)`; introspect with `dynamicSchema`.
    ///
    /// Read-only opens are WAL-aware (`SQLITE_OPEN_READONLY`) and will see a
    /// concurrent writer's committed-but-uncheckpointed rows.
    public static func dynamic(fileURL: URL) throws -> Lattice {
        var configuration = Configuration(fileURL: fileURL)
        configuration.isReadOnly = true
        // `_optLatticeRef` normalizes the FRT-optional (16.4+) vs value-non-optional
        // (iOS 15 path) factory return — `guard let` directly on the factory result
        // only compiles on FRT platforms.
        guard let ref = _optLatticeRef(lattice.swift_lattice_ref.createDynamic(config: configuration.cxxConfiguration())) else {
            throw Lattice.Error.databaseError("Could not open \(fileURL.path) dynamically")
        }
        return Lattice(backend: CxxBackend(ref),
                       configuration: configuration,
                       modelTypes: [],
                       schema: nil,
                       isolation: nil)
    }

    /// Lazy results over a table identified by its runtime name (no compile-time
    /// `@Model`). Yields `DynamicObject`s.
    public func dynamicObjects(_ tableName: String) -> DynamicResults {
        DynamicResults(backend: backend, tableName: tableName)
    }

    /// The reconstructed schema of every user model table in the database.
    /// Empty if the backend doesn't support dynamic introspection.
    public var dynamicSchema: [ObjectSchema] {
        guard let provider = backend as? any DynamicSchemaProviding else { return [] }
        return provider.dynamicTableNames().map { table in
            ObjectSchema(name: table, properties: provider.dynamicProperties(table: table))
        }
    }
}
