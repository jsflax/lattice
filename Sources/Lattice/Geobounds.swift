import Foundation
import LatticeSwiftCppBridge

public protocol GeoboundsProperty: LatticeSchemaProperty {
    static func _trace<V>(keyPath: KeyPath<Self, V>) -> String
}

// MARK: - GeoBoundsLinkListRef (wraps C++ geo_bounds_list_ref)

public struct GeoBoundsLinkListRef<T>: @unchecked Sendable, LinkListRef {
    var _ref: lattice.geo_bounds_list_ref
    private let _fromRef: (lattice.geo_bounds_ref) -> T
    private let _toRef: (T) -> lattice.geo_bounds_ref

    init(_ref: lattice.geo_bounds_list_ref,
         fromRef: @escaping (lattice.geo_bounds_ref) -> T,
         toRef: @escaping (T) -> lattice.geo_bounds_ref) {
        self._ref = _ref
        self._fromRef = fromRef
        self._toRef = toRef
    }

    public static func new() -> Self {
        fatalError("Use _makeLinkList instead")
    }

    public func get(at position: Int) -> T {
        _fromRef(_ref[position].objectRef!)
    }

    public mutating func set(at position: Int, _ element: T) {
        var proxy = _ref[position]
        proxy.assign(_toRef(element))
    }

    public func count() -> Int { _ref.size() }

    public mutating func append(_ element: T) {
        _ref.pushBack(_toRef(element))
    }

    public func remove(at position: Int) { _ref.erase(position) }

    public func removeAll() { _ref.clear() }

    public func indexOf(_ element: T) -> Int? {
        let opt = _ref.findIndex(_toRef(element))
        return opt.hasValue ? Int(opt.pointee) : nil
    }

    public func indicesWhere(_ query: String) -> [Int] {
        let results = _ref.findWhere(std.string(query))
        return (0..<results.count).map { Int(results[$0]) }
    }
}

/// Unit for geographic distance measurements
public enum DistanceUnit: Sendable {
    case meters
    case kilometers
    case miles
    case feet

    /// Conversion factor from this unit to meters
    public var toMeters: Double {
        switch self {
        case .meters: return 1.0
        case .kilometers: return 1000.0
        case .miles: return 1609.344
        case .feet: return 0.3048
        }
    }

    /// Convert a value in meters to this unit
    public func fromMeters(_ meters: Double) -> Double {
        meters / toMeters
    }
}

extension Optional: GeoboundsProperty where Wrapped: GeoboundsProperty {
//    public typealias Ref = lattice.geo_bounds_list_ref
//    
//    public var asRefType: lattice.geo_bounds_ref {
//        if let self = self {
//            return self.asRefType
//        } else {
//            return std.nullopt_t.init() as! lattice.geo_bounds_ref
//        }
//    }
//    
//    public init(_ bounds: lattice.geo_bounds_ref) {
//        Wrapped.init(bounds as! Wrapped.Ref.RefType)
//    }
    public static func _trace<V>(keyPath: KeyPath<Optional<Wrapped>, V>) -> String {
        Wrapped._trace(keyPath: keyPath as! KeyPath<Wrapped, V>)
    }
}

#if canImport(MapKit)
import MapKit

extension MKCoordinateRegion: CxxManaged, GeoboundsProperty, LinkListable {
    public static var anyPropertyKind: AnyProperty.Kind {
        .int
    }

    public static var defaultValue: Self {
        .init()
    }

    public static func _makeLinkList(from storage: inout ModelStorage, named name: String) -> GeoBoundsLinkListRef<MKCoordinateRegion> {
        GeoBoundsLinkListRef(
            _ref: storage._ref.getGeoBoundsList(named: std.string(name)),
            fromRef: { MKCoordinateRegion($0) },
            toRef: { $0.asRefType }
        )
    }

    public var asRefType: lattice.geo_bounds_ref {
        let bbox = boundingBox
        return .init(.init(bbox.minLat, bbox.maxLat, bbox.minLon, bbox.maxLon))
    }

    public init(_ bounds: lattice.geo_bounds_ref) {
        let bounds = bounds.shared().pointee
        let center = CLLocationCoordinate2D(latitude: bounds.center_lat(), longitude: bounds.center_lon())
        let span = MKCoordinateSpan(latitudeDelta: bounds.lat_span(), longitudeDelta: bounds.lon_span())
        self.init(center: center, span: span)
    }

    public static func getField(from storage: inout ModelStorage, named name: String) -> MKCoordinateRegion {
        let bounds = storage._ref.getGeoBounds(named: std.string(name))
        let center = CLLocationCoordinate2D(latitude: bounds.center_lat(), longitude: bounds.center_lon())
        let span = MKCoordinateSpan(latitudeDelta: bounds.lat_span(), longitudeDelta: bounds.lon_span())
        return .init(center: center, span: span)
    }

    public static func setField(on storage: inout ModelStorage,
                                named name: String,
                                _ value: MKCoordinateRegion) {
        let bbox: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) =
        (minLat: value.center.latitude - value.span.latitudeDelta / 2,
         maxLat: value.center.latitude + value.span.latitudeDelta / 2,
         minLon: value.center.longitude - value.span.longitudeDelta / 2,
         maxLon: value.center.longitude + value.span.longitudeDelta / 2)
        storage._ref.setGeoBounds(named: std.string(name), minLat: bbox.minLat, maxLat: bbox.maxLat, minLon: bbox.minLon, maxLon: bbox.maxLon)
    }
    
    public var boundingBox: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        (minLat: center.latitude - span.latitudeDelta / 2,
         maxLat: center.latitude + span.latitudeDelta / 2,
         minLon: center.longitude - span.longitudeDelta / 2,
         maxLon: center.longitude + span.longitudeDelta / 2)
    }
    
    public static func _trace<V>(keyPath: KeyPath<MKCoordinateRegion, V>) -> String {
        switch keyPath {
        case \.center: return "center"
        case \.span: return "span"
        default: preconditionFailure()
        }
    }
}

public struct CLLocationCoordinate2DCompat: EmbeddedModel {
    public let latitude: Double = 0
    public let longitude: Double = 0
    
    public init() {}
}

extension CLLocationCoordinate2D: CxxManaged, GeoboundsProperty, LinkListable {
    public static func _makeLinkList(from storage: inout ModelStorage, named name: String) -> GeoBoundsLinkListRef<CLLocationCoordinate2D> {
        GeoBoundsLinkListRef(
            _ref: storage._ref.getGeoBoundsList(named: std.string(name)),
            fromRef: { CLLocationCoordinate2D($0) },
            toRef: { $0.asRefType }
        )
    }

    public var asRefType: lattice.geo_bounds_ref {
        .init(.init(latitude, latitude, longitude, longitude))
    }

    public init(_ refType: lattice.geo_bounds_ref) {
        let bounds = refType.shared().pointee
        self.init(latitude: bounds.center_lat(), longitude: bounds.center_lon())
    }

    public static var anyPropertyKind: AnyProperty.Kind {
        .int
    }
    
    public static var defaultValue: Self {
        kCLLocationCoordinate2DInvalid
    }
    
    public static func _trace<V>(keyPath: KeyPath<Self, V>) -> String {
        switch keyPath {
        case \.latitude: return "minLat"
        case \.longitude: return "minLon"
        default: preconditionFailure()
        }
    }
    
    public static func getField(from storage: inout ModelStorage, named name: String) -> CLLocationCoordinate2D {
        let bounds = storage._ref.getGeoBounds(named: std.string(name))
        return CLLocationCoordinate2D(latitude: bounds.center_lat(), longitude: bounds.center_lon())
    }

    public static func setField(on storage: inout ModelStorage,
                                named name: String, _ value: CLLocationCoordinate2D) {
        storage._ref.setGeoBounds(named: std.string(name), minLat: value.latitude,
                            maxLat: value.latitude, minLon: value.longitude,
                            maxLon: value.longitude)
    }
}

#endif
