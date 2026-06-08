import Foundation
import LatticeSwiftCppBridge

/// The single place where "which backend implementation?" is decided for freshly
/// constructed handles built from *neutral* inputs (a model type, or nothing).
///
/// Every construction site that used to inline `if #available(iOS 16.4,*) {
/// Cxx… } else { fatalError("Phase 3") }` now calls one of these instead, so the
/// CBackend (iOS 15) path is filled in exactly ONE `else` per backend kind —
/// not hunted down across the package.
///
/// NOTE — what is intentionally NOT here:
///   * Boundary boxing inside `CxxBackend`/`CxxObjectBackend` (wrapping a C++
///     value already in hand) stays inline: those run only on the modern path
///     by construction (they take a `CxxDynamicObjectRef`/`swift_lattice_ref`,
///     which don't exist below 16.4), so there is no Cxx-vs-C decision to make.
///   * The `Lattice` db handle (`Lattice.init`): its creation is entangled with
///     Cxx schema-vector building (`lattice.swift_schema_entry`), which only
///     neutralizes in Phase 3c. It is a single site, not scattered, and is
///     marked there as the remaining db-handle seam.
enum BackendFactory {
    /// A fresh, empty default-valued object backing a model instance not yet
    /// persisted (macro-emitted `_dynamicObject`, `ModelStorage._default`).
    static func makeDefaultObject<M: Model>(for type: M.Type) -> any ObjectBackend {
        if #available(iOS 16.4, macOS 13.3, tvOS 16.4, watchOS 9.4, *) {
            return CxxObjectBackend(CxxDynamicObjectRef.wrap(_defaultCxxLatticeObject(type))!)
        } else {
            // Phase 3: return CBackendObject(c_lattice_object_create_with_schema(...))
            fatalError("iOS < 16.4 requires the C backend (Phase 3, not yet wired)")
        }
    }

    /// A fresh, empty link-list backend (`List`/`VirtualList` default value).
    static func makeEmptyObjectList() -> any ObjectListBackend {
        if #available(iOS 16.4, macOS 13.3, tvOS 16.4, watchOS 9.4, *) {
            return CxxObjectListBackend(.create())
        } else {
            // Phase 3: return CObjectListBackend(c_lattice_link_list_create())
            fatalError("iOS < 16.4 requires the C backend (Phase 3, not yet wired)")
        }
    }
}
