import Foundation

// MARK: - @Detached: Sendable value mirror of a @Model
//
// `@Detached` (on a `@Model` class) generates a nested `Model.Detached` struct —
// a `Sendable & Codable` value copy of the object's data — plus a
// `model.detached(maxDepth:)` method that materializes the object graph to a
// bounded depth. Unlike `snapshot()` (an array of *live* objects) or
// `ThreadSafeReference` (a re-fetch token), a `Detached` value carries no live
// C++ handle and can cross isolation boundaries on its own.
//
// The macro never classifies "link vs scalar" at expansion time. Instead it
// emits, per stored property `p: T`, a field of type `T.DetachedRepr` and the
// uniform population `m.p._detached(remainingDepth:visited:)`. All scalar /
// optional / array / list / link behaviour lives in the `Detachable`
// conformances below, resolved by the compiler — mirroring how the rest of the
// ORM dispatches through `property.type.getField(...)`.
//
// Scope (v1): scalars, value arrays, embedded/enum/custom value types that opt
// into `DetachableLeaf`, built-in value types (UUID/Date/Data/Vector/geo),
// forward to-one concrete links (`Dog?`) and forward to-many `List<Dog>`.
// Out of scope (skipped with a diagnostic): backlinks (`@Relation`/`TableResults`),
// virtual/existential links (`(any Proto)?`, `VirtualList<any Proto>`).
//
// NOTE: every model reachable as a link from a `@Detached` model must itself be
// `@Detached`, otherwise its link field's `DetachedRepr` won't resolve.

// MARK: - Identity key for cycle detection

/// Identity used to cut cycles during traversal. Managed objects have a stable
/// `globalId`/`primaryKey`; unmanaged objects fall back to the backend-ref
/// identity (best-effort — for fully unmanaged cyclic graphs `maxDepth` is the
/// real backstop, since each link read hydrates a fresh wrapper).
public enum DetachKey: Hashable, Sendable {
    case global(UUID)
    case key(Int64)
    case ref(ObjectIdentifier)
}

// MARK: - Detachable

public protocol Detachable {
    /// This type as a stored field in a `Detached` struct.
    associatedtype DetachedRepr: Sendable & Codable
    /// This type as an *optional* stored field. Defaults to `Optional<DetachedRepr>`;
    /// models override it to a single `DetachedRef` (which already encodes absence),
    /// so `Dog?` collapses to one box instead of a double optional.
    /// `ExpressibleByNilLiteral` lets the absent path `return nil` generically.
    associatedtype DetachedOptionalRepr: Sendable & Codable & ExpressibleByNilLiteral = Optional<DetachedRepr>

    func _detached(remainingDepth: Int, visited: inout Set<DetachKey>) -> DetachedRepr
    func _detachedOptional(remainingDepth: Int, visited: inout Set<DetachKey>) -> DetachedOptionalRepr
}

public extension Detachable where DetachedOptionalRepr == Optional<DetachedRepr> {
    func _detachedOptional(remainingDepth: Int, visited: inout Set<DetachKey>) -> DetachedOptionalRepr {
        .some(_detached(remainingDepth: remainingDepth, visited: &visited))
    }
}

/// Opt-in conformance for a value type (embedded model, enum, custom scalar)
/// that should appear verbatim in a `Detached` struct. The type must be
/// `Sendable & Codable`. Usage: `extension MyEmbedded: DetachableLeaf {}`.
public protocol DetachableLeaf: Detachable, Sendable, Codable where DetachedRepr == Self {}
public extension DetachableLeaf {
    func _detached(remainingDepth: Int, visited: inout Set<DetachKey>) -> Self { self }
}

// MARK: - DetachedRef (the indirection that makes recursive value types legal)

/// A detached to-one link. `.none` means the link was absent **or** cut by the
/// depth/cycle boundary (per the "drop to nil" choice — the two are
/// intentionally indistinguishable). `indirect` keeps the enum finite-size so a
/// `Detached` struct may transitively contain itself.
@dynamicMemberLookup
public enum DetachedRef<D: Sendable & Codable>: Sendable, Codable, ExpressibleByNilLiteral {
    case none
    indirect case some(D)

    public init(nilLiteral: ()) { self = .none }

    /// The expanded value, or nil when absent/cut.
    public var value: D? { if case .some(let d) = self { return d } else { return nil } }

    /// Ergonomic read-through: `ref.name` is `ref.value?.name`.
    public subscript<T>(dynamicMember keyPath: KeyPath<D, T>) -> T? {
        value.map { $0[keyPath: keyPath] }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = container.decodeNil() ? .none : .some(try container.decode(D.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .none:           try container.encodeNil()
        case .some(let value): try container.encode(value)
        }
    }
}

/// `Equatable` when the boxed value is — so a generated `Detached` (which stores `DetachedRef`s for
/// its links) can synthesize `Equatable`, letting SwiftUI diff/skip detached rows per-row.
extension DetachedRef: Equatable where D: Equatable {}

// MARK: - Leaf conformances (built-in value types)

extension Int: DetachableLeaf {}
extension Int64: DetachableLeaf {}
extension Int32: DetachableLeaf {}
extension Int16: DetachableLeaf {}
extension Int8: DetachableLeaf {}
extension UInt: DetachableLeaf {}
extension UInt64: DetachableLeaf {}
extension UInt32: DetachableLeaf {}
extension Double: DetachableLeaf {}
extension Float: DetachableLeaf {}
extension Bool: DetachableLeaf {}
extension String: DetachableLeaf {}
extension UUID: DetachableLeaf {}
extension Date: DetachableLeaf {}
extension Data: DetachableLeaf {}

// `Vector`'s `Codable` is conditional, so its `Detachable` conformance must be too.
extension Vector: Detachable where Element: Codable {
    public typealias DetachedRepr = Vector<Element>
    public func _detached(remainingDepth: Int, visited: inout Set<DetachKey>) -> Vector<Element> { self }
}

// MARK: - Optional / Array / List

extension Optional: Detachable where Wrapped: Detachable {
    // Collapse: an optional field's repr is the wrapped type's *optional* repr,
    // so `Dog?` → `DetachedRef<Dog.Detached>` (single) and `Date?` → `Date?`.
    public typealias DetachedRepr = Wrapped.DetachedOptionalRepr
    public func _detached(remainingDepth: Int, visited: inout Set<DetachKey>) -> Wrapped.DetachedOptionalRepr {
        switch self {
        case .some(let wrapped): return wrapped._detachedOptional(remainingDepth: remainingDepth, visited: &visited)
        case .none:              return nil
        }
    }
}

extension Array: Detachable where Element: Detachable {
    public typealias DetachedRepr = [Element.DetachedRepr]
    public func _detached(remainingDepth: Int, visited: inout Set<DetachKey>) -> [Element.DetachedRepr] {
        map { $0._detached(remainingDepth: remainingDepth, visited: &visited) }
    }
}

// A `Set` has no inherent order and isn't itself `Codable` for an arbitrary
// `Element`, so its detached form is an array (order-independent membership).
extension Set: Detachable where Element: Detachable {
    public typealias DetachedRepr = [Element.DetachedRepr]
    public func _detached(remainingDepth: Int, visited: inout Set<DetachKey>) -> [Element.DetachedRepr] {
        map { $0._detached(remainingDepth: remainingDepth, visited: &visited) }
    }
}

extension List: Detachable where Element: Model & Detachable {
    public typealias DetachedRepr = [Element.DetachedRepr]
    public func _detached(remainingDepth: Int, visited: inout Set<DetachKey>) -> [Element.DetachedRepr] {
        // A to-many link collapses to [] at the depth boundary (parallels a
        // to-one's .none). Individual elements that link back into the active
        // path still cut to .none within the array.
        guard remainingDepth > 0 else { return [] }
        return _detachedElements().map { $0._detached(remainingDepth: remainingDepth, visited: &visited) }
    }
}

// MARK: - Model traversal helpers (used by macro-generated code)

public extension Model {
    /// Cycle-detection key — see `DetachKey`. The macro-generated `_detached`
    /// inlines the depth/cycle gate around this (path-set: insert on enter,
    /// remove on exit, so DAG diamonds still expand while true cycles cut).
    var _detachKey: DetachKey {
        if let globalId { return .global(globalId) }
        if let primaryKey { return .key(primaryKey) }
        return .ref(ObjectIdentifier(_dynamicObject._ref))
    }
}

// MARK: - The macro

@attached(member, names: arbitrary)
@attached(extension, conformances: Detachable, names: arbitrary)
public macro Detached() = #externalMacro(module: "LatticeMacros", type: "DetachedMacro")

// MARK: - Geo leaves (bespoke Sendable+Codable mirrors; the MapKit types aren't Codable)

#if canImport(MapKit)
import MapKit

public struct GeoCoordinateDetached: Sendable, Codable, Hashable {
    public var latitude: Double
    public var longitude: Double
    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude; self.longitude = longitude
    }
}

public struct GeoRegionDetached: Sendable, Codable, Hashable {
    public var centerLatitude: Double
    public var centerLongitude: Double
    public var latitudeDelta: Double
    public var longitudeDelta: Double
    public init(centerLatitude: Double, centerLongitude: Double, latitudeDelta: Double, longitudeDelta: Double) {
        self.centerLatitude = centerLatitude; self.centerLongitude = centerLongitude
        self.latitudeDelta = latitudeDelta; self.longitudeDelta = longitudeDelta
    }
}

extension CLLocationCoordinate2D: Detachable {
    public typealias DetachedRepr = GeoCoordinateDetached
    public func _detached(remainingDepth: Int, visited: inout Set<DetachKey>) -> GeoCoordinateDetached {
        GeoCoordinateDetached(latitude: latitude, longitude: longitude)
    }
}

extension MKCoordinateRegion: Detachable {
    public typealias DetachedRepr = GeoRegionDetached
    public func _detached(remainingDepth: Int, visited: inout Set<DetachKey>) -> GeoRegionDetached {
        GeoRegionDetached(centerLatitude: center.latitude, centerLongitude: center.longitude,
                          latitudeDelta: span.latitudeDelta, longitudeDelta: span.longitudeDelta)
    }
}
#endif
